defmodule BorsNG.Worker.BranchDeleter do
  @moduledoc """
  BranchDeleter controls merged branches removal
  if delete_merged_branches is true in bors.toml file.

  By default we wait for pull request "closed" event with pr merged flag set.
  Also since event arrival is not guaranteed we poll every 5 minutes and
  if pr is merged we delete pr head branch.
  """

  use GenServer
  require Logger
  alias BorsNG.Worker.Batcher
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Project
  alias BorsNG.Database.Repo
  alias BorsNG.GitHub

  # 1 minute between tries
  @retry_delay 60 * 1000

  # keep trying for one hour
  @retries 60

  # Public API

  def start_link do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  def delete(%Patch{} = patch) do
    GenServer.cast(__MODULE__, {:delete, patch, 0})
  end

  # Server callbacks

  def init(:ok) do
    {:ok, :ok}
  end

  def handle_cast({:delete, patch, attempt}, state) do
    patch = Repo.preload(patch, :project)
    conn = Project.installation_connection(patch.project.repo_xref, Repo)

    case GitHub.get_pr(conn, patch.pr_xref) do
      {:ok, %{merged: true} = pr} ->
        delete_branch(conn, pr)

      {:ok, %{state: :closed} = pr} ->
        delete_branch(conn, pr)

      {:ok, %{state: :open}} when attempt < @retries ->
        Process.send_after(
          self(),
          {:retry_delete, patch, attempt + 1},
          attempt_delay(attempt)
        )

      _ ->
        nil
    end

    {:noreply, state}
  end

  def handle_info({:retry_delete, patch, attempt}, state) do
    handle_cast({:delete, patch, attempt}, state)
  end

  defp delete_branch(conn, pr) do
    pr_in_same_repo =
      pr.head_repo_id > 0 &&
        pr.head_repo_id == pr.base_repo_id

    toml_result = Batcher.GetBorsToml.get(conn, pr.head_ref)

    {delete_merged_branches, update_base_for_deletes} =
      case toml_result do
        {:ok, toml} -> {toml.delete_merged_branches, toml.update_base_for_deletes}
        _ -> {false, false}
      end

    pr_closed = pr.state == :closed

    pr_squash_merged = String.starts_with?(pr.title, "[Merged by Bors] - ")

    if pr_in_same_repo && delete_merged_branches do
      delete =
        cond do
          pr.merged ->
            true

          pr_closed && pr_squash_merged ->
            true

          true ->
            nil
        end

      if delete && deletable?(conn, pr.head_ref) do
        # GitHub closes open PRs based on a branch as soon as it is deleted, so
        # dependents are retargeted first. If any of them could not be moved off
        # the branch, it is left in place rather than closing their PRs.
        case retarget_dependents(conn, pr, update_base_for_deletes) do
          {:ok, retargeted} ->
            case GitHub.delete_branch(conn, pr.head_ref) do
              :ok ->
                :ok

              error ->
                Logger.warn([
                  "BranchDeleter: could not delete ",
                  pr.head_ref,
                  ": ",
                  inspect(error)
                ])

                restore_bases(conn, retargeted)
            end

          {:abort, retargeted} ->
            Logger.warn([
              "BranchDeleter: keeping ",
              pr.head_ref,
              ", its dependent PRs could not be retargeted"
            ])

            restore_bases(conn, retargeted)
        end
      end
    end
  end

  defp deletable?(conn, branch) do
    with {:ok, default_branch} <- GitHub.get_repo_default_branch(conn),
         {:ok, protected} <- GitHub.get_branch_protected(conn, branch) do
      cond do
        branch == default_branch ->
          Logger.warn(["BranchDeleter: refusing to touch default branch ", branch])
          false

        protected ->
          Logger.warn(["BranchDeleter: refusing to touch protected branch ", branch])
          false

        true ->
          true
      end
    else
      error ->
        Logger.warn([
          "BranchDeleter: could not confirm ",
          branch,
          " is deletable, skipping: ",
          inspect(error)
        ])

        false
    end
  end

  defp retarget_dependents(_conn, _pr, false), do: {:ok, []}

  defp retarget_dependents(conn, pr, true) do
    case GitHub.get_open_prs_with_base(conn, pr.head_ref) do
      {:ok, dependents} ->
        Enum.reduce_while(dependents, {:ok, []}, fn dependent, {:ok, retargeted} ->
          case retarget(conn, dependent, pr.base_ref) do
            :ok -> {:cont, {:ok, [dependent | retargeted]}}
            :error -> {:halt, {:abort, retargeted}}
          end
        end)

      error ->
        Logger.warn([
          "BranchDeleter: could not list PRs based on ",
          pr.head_ref,
          ": ",
          inspect(error)
        ])

        {:abort, []}
    end
  end

  defp retarget(conn, pr, base_ref) do
    case GitHub.update_pr_base(conn, %{pr | base_ref: base_ref}) do
      {:ok, _} ->
        :ok

      error ->
        Logger.warn([
          "BranchDeleter: could not retarget PR ",
          to_string(pr.number),
          " onto ",
          base_ref,
          ": ",
          inspect(error)
        ])

        :error
    end
  end

  defp restore_bases(conn, dependents) do
    Enum.each(dependents, fn dependent ->
      case GitHub.update_pr_base(conn, dependent) do
        {:ok, _} ->
          :ok

        error ->
          Logger.warn([
            "BranchDeleter: could not restore base of PR ",
            to_string(dependent.number),
            ": ",
            inspect(error)
          ])
      end
    end)
  end

  defp attempt_delay(attempt) do
    @retry_delay * attempt
  end
end
