defmodule BorsNG.WebhookParserPlug do
  @moduledoc """
  Parse the GitHub webhook payload (as JSON) and verify the HMAC-SHA256 signature.

  The secret is read on every request, not at compile time, so a release built
  without GITHUB_WEBHOOK_SECRET still verifies signatures. Without a secret,
  every webhook is rejected.
  """

  import Plug.Conn
  require Logger

  def init(options) do
    options
  end

  def call(conn, options) do
    if conn.path_info == ["webhook", "github"] do
      run(conn, secret(options))
    else
      conn
    end
  end

  defp secret(options) do
    Keyword.get_lazy(options, :secret, fn ->
      Confex.get_env(:bors, __MODULE__, [])[:webhook_secret]
    end)
  end

  defp run(conn, secret) when secret in [nil, ""] do
    Logger.error("Rejecting GitHub webhook: no webhook secret is configured")
    reject(conn, 500, "Webhook secret not configured")
  end

  defp run(conn, secret) do
    {:ok, body, conn} = read_body(conn)

    expected = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)

    case get_req_header(conn, "x-hub-signature-256") do
      [signature] ->
        if Plug.Crypto.secure_compare(signature, expected) do
          %Plug.Conn{conn | body_params: Jason.decode!(body)}
        else
          reject(conn, 401, "Invalid signature")
        end

      _ ->
        reject(conn, 401, "Invalid signature")
    end
  end

  defp reject(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
    |> halt()
  end
end
