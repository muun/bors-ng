defmodule BorsNG.Worker.BranchDeleterTest do
  use BorsNG.Worker.TestCase

  alias BorsNG.Worker.BranchDeleter
  alias BorsNG.GitHub
  alias BorsNG.GitHub.Pr
  alias BorsNG.Database.Installation
  alias BorsNG.Database.Project
  alias BorsNG.Database.Patch
  alias BorsNG.Database.Repo

  setup do
    inst =
      %Installation{installation_xref: 91}
      |> Repo.insert!()

    proj =
      %Project{
        installation_id: inst.id,
        repo_xref: 14,
        staging_branch: "staging"
      }
      |> Repo.insert!()

    %{proj: proj, inst: inst}
  end

  test "deletes by patch", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: true
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master"]
  end

  test "deletes by patch when squashing and merging", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "[Merged by Bors] - Test",
            body: "Total Mess",
            state: :closed,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              use_squash_merge = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              use_squash_merge = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master"]
  end

  test "don't delete patch if closed by other reason", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Total Mess",
            state: :closed,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              use_squash_merge = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              use_squash_merge = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master", "update"]
  end

  test "reschedules fetch if pr is not merged", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    assert_receive {:retry_delete, _patch, 1}

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master", "update"]
  end

  test "doesnt delete anything if toml arg not set", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = false
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = false
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master", "update"]
  end

  test "deletes by patch updating dependant PR base branch", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo", "update2" => "bar"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: true
          },
          2 => %Pr{
            number: 2,
            title: "Depends on Test",
            body: "Mess",
            state: :open,
            base_ref: "update",
            head_sha: "00000002",
            head_ref: "update2",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              update_base_for_deletes = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    branches =
      installation
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master", "update2"]

    dependant_pr_base_ref =
      installation
      |> Map.get(:pulls)
      |> Map.get(2)
      |> Map.get(:base_ref)

    assert dependant_pr_base_ref == "master"
  end

  test "deletes by patch without updating dependant PR base branch", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo", "update2" => "bar"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: true
          },
          2 => %Pr{
            number: 2,
            title: "Depends on Test",
            body: "Mess",
            state: :open,
            base_ref: "update",
            head_sha: "00000002",
            head_ref: "update2",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    branches =
      installation
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master", "update2"]

    dependant_pr_base_ref =
      installation
      |> Map.get(:pulls)
      |> Map.get(2)
      |> Map.get(:base_ref)

    assert dependant_pr_base_ref == "update"
  end

  test "deletes by patch when a stacked dependant PR cannot be retargeted", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo", "update2" => "bar"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        stacked_pulls: [2],
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: true
          },
          2 => %Pr{
            number: 2,
            title: "Depends on Test",
            body: "Mess",
            state: :open,
            base_ref: "update",
            head_sha: "00000002",
            head_ref: "update2",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              update_base_for_deletes = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    assert {:noreply, :ok} = BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    branches =
      installation
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master", "update2"]

    dependant = installation |> Map.get(:pulls) |> Map.get(2)

    assert dependant.base_ref == "master"
    assert dependant.state == :open
  end

  test "deletes on a retried delete message", %{proj: proj} do
    GitHub.ServerMock.put_state(%{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: true
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
            """
          }
        }
      }
    })

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    assert {:noreply, :ok} = BranchDeleter.handle_info({:retry_delete, patch, 1}, :ok)

    branches =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})
      |> Map.get(:branches)
      |> Map.keys()

    assert branches == ["master"]
  end

  test "retargets a dependant PR before deleting its base branch", %{proj: proj} do
    GitHub.ServerMock.put_state(chained_state())

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    assert installation |> Map.get(:branches) |> Map.keys() == ["master", "update2"]

    dependant = installation |> Map.get(:pulls) |> Map.get(2)

    assert dependant.base_ref == "master"
    assert dependant.state == :open
  end

  test "refuses to delete or retarget when the branch is protected", %{proj: proj} do
    GitHub.ServerMock.put_state(
      chained_state()
      |> put_in([{{:installation, 91}, 14}, :protected_branches], ["update"])
    )

    patch =
      %Patch{
        project_id: proj.id,
        pr_xref: 1,
        commit: "foo",
        into_branch: "master"
      }
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    assert installation |> Map.get(:branches) |> Map.keys() == ["master", "update", "update2"]

    dependant = installation |> Map.get(:pulls) |> Map.get(2)

    assert dependant.base_ref == "update"
    assert dependant.state == :open
  end

  test "refuses to delete or retarget the repository default branch", %{proj: proj} do
    GitHub.ServerMock.put_state(
      chained_state()
      |> put_in([{{:installation, 91}, 14}, :default_branch], "update")
    )

    patch =
      %Patch{project_id: proj.id, pr_xref: 1, commit: "foo", into_branch: "master"}
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    assert installation |> Map.get(:branches) |> Map.keys() == ["master", "update", "update2"]

    dependant = installation |> Map.get(:pulls) |> Map.get(2)

    assert dependant.base_ref == "update"
    assert dependant.state == :open
  end

  test "keeps the branch when a dependant PR cannot be retargeted", %{proj: proj} do
    GitHub.ServerMock.put_state(
      chained_state()
      |> put_in([{{:installation, 91}, 14}, :unretargetable_pulls], [2])
    )

    patch =
      %Patch{project_id: proj.id, pr_xref: 1, commit: "foo", into_branch: "master"}
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    assert installation |> Map.get(:branches) |> Map.keys() == ["master", "update", "update2"]

    dependant = installation |> Map.get(:pulls) |> Map.get(2)

    assert dependant.base_ref == "update"
    assert dependant.state == :open
  end

  test "restores already retargeted dependants when a later one fails", %{proj: proj} do
    state =
      chained_state()
      |> put_in([{{:installation, 91}, 14}, :unretargetable_pulls], [3])
      |> put_in([{{:installation, 91}, 14}, :branches, "update3"], "baz")
      |> put_in(
        [{{:installation, 91}, 14}, :pulls, 3],
        %Pr{
          number: 3,
          title: "Also depends on Test",
          body: "Mess",
          state: :open,
          base_ref: "update",
          head_sha: "00000003",
          head_ref: "update3",
          base_repo_id: 14,
          head_repo_id: 14,
          merged: false
        }
      )

    GitHub.ServerMock.put_state(state)

    patch =
      %Patch{project_id: proj.id, pr_xref: 1, commit: "foo", into_branch: "master"}
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    assert "update" in (installation |> Map.get(:branches) |> Map.keys())

    pulls = Map.get(installation, :pulls)

    assert Map.get(pulls, 2).base_ref == "update"
    assert Map.get(pulls, 2).state == :open
    assert Map.get(pulls, 3).base_ref == "update"
    assert Map.get(pulls, 3).state == :open
  end

  test "restores dependant bases when the delete fails after retargeting", %{proj: proj} do
    GitHub.ServerMock.put_state(
      chained_state()
      |> put_in([{{:installation, 91}, 14}, :undeletable_branches], ["update"])
    )

    patch =
      %Patch{project_id: proj.id, pr_xref: 1, commit: "foo", into_branch: "master"}
      |> Repo.insert!()

    BranchDeleter.handle_cast({:delete, patch, 0}, :ok)

    installation =
      GitHub.ServerMock.get_state()
      |> Map.get({{:installation, 91}, 14})

    assert installation |> Map.get(:branches) |> Map.keys() == ["master", "update", "update2"]

    dependant = installation |> Map.get(:pulls) |> Map.get(2)

    assert dependant.base_ref == "update"
    assert dependant.state == :open
  end

  defp chained_state do
    %{
      {{:installation, 91}, 14} => %{
        branches: %{"master" => "ini", "update" => "foo", "update2" => "bar"},
        commits: %{},
        comments: %{1 => []},
        statuses: %{},
        pulls: %{
          1 => %Pr{
            number: 1,
            title: "Test",
            body: "Mess",
            state: :open,
            base_ref: "master",
            head_sha: "00000001",
            head_ref: "update",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: true
          },
          2 => %Pr{
            number: 2,
            title: "Depends on Test",
            body: "Mess",
            state: :open,
            base_ref: "update",
            head_sha: "00000002",
            head_ref: "update2",
            base_repo_id: 14,
            head_repo_id: 14,
            merged: false
          }
        },
        files: %{
          "master" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              update_base_for_deletes = true
            """
          },
          "update" => %{
            ".github/bors.toml" => ~s"""
              status = [ "ci" ]
              delete_merged_branches = true
              update_base_for_deletes = true
            """
          }
        }
      }
    }
  end
end
