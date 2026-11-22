defmodule BorsNG.WebhookParserPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias BorsNG.WebhookParserPlug

  @secret "plug-test-secret"
  @body ~s({"zen":"Keep it logically awesome."})

  defp webhook_conn(signature) do
    conn = conn(:post, "/webhook/github", @body)

    case signature do
      nil -> conn
      value -> put_req_header(conn, "x-hub-signature-256", value)
    end
  end

  defp sign(secret, body) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  test "accepts a valid signature and decodes the body" do
    conn = WebhookParserPlug.call(webhook_conn(sign(@secret, @body)), secret: @secret)

    refute conn.halted
    assert conn.body_params == %{"zen" => "Keep it logically awesome."}
  end

  test "rejects a signature made with another secret" do
    conn = WebhookParserPlug.call(webhook_conn(sign("other", @body)), secret: @secret)

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects a request without a signature" do
    conn = WebhookParserPlug.call(webhook_conn(nil), secret: @secret)

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects a malformed signature" do
    conn = WebhookParserPlug.call(webhook_conn("sha256=zz"), secret: @secret)

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects a sha1-only signature" do
    sha1 = "sha1=" <> Base.encode16(:crypto.mac(:hmac, :sha, @secret, @body), case: :lower)

    conn =
      conn(:post, "/webhook/github", @body)
      |> put_req_header("x-hub-signature", sha1)
      |> WebhookParserPlug.call(secret: @secret)

    assert conn.halted
    assert conn.status == 401
  end

  test "rejects every webhook when no secret is configured" do
    for secret <- [nil, ""] do
      conn = WebhookParserPlug.call(webhook_conn(sign("", @body)), secret: secret)

      assert conn.halted
      assert conn.status == 500
    end
  end

  test "reads the secret from the application config at request time" do
    conn = WebhookParserPlug.call(webhook_conn(sign("test-webhook-secret", @body)), [])

    refute conn.halted
  end

  test "ignores other paths" do
    conn = WebhookParserPlug.call(conn(:post, "/other", @body), secret: nil)

    refute conn.halted
  end
end
