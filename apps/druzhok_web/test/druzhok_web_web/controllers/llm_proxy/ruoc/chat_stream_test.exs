defmodule DruzhokWebWeb.LlmProxy.Ruoc.ChatStreamTest do
  use DruzhokWebWeb.RuocProxyCase

  @body %{"model" => "ruoc-flash", "stream" => true, "messages" => [%{"role" => "user", "content" => "ping"}]}

  defp send_gateway_sse(req, lines) do
    req
    |> Plug.Conn.put_resp_header("x-ruoc-request-id", "req_s1")
    |> send_sse(lines)
  end

  test "relays SSE verbatim with the request id and meters the usage chunk",
       %{conn: conn, bypass: bypass, instance: instance} do
    lines = sse_stream(["po", "ng"], usage: %{"prompt_tokens" => 7, "completion_tokens" => 2}, model: "ruoc-flash")

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert Jason.decode!(raw)["stream"] == true
      send_gateway_sse(req, lines)
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_s1"]
    assert conn.resp_body == Enum.join(lines)

    assert [log] = usage_logs(instance)
    assert {log.prompt_tokens, log.completion_tokens, log.cost_cents, log.provider} == {7, 2, 0, "ruoc"}
    assert log.prompt_preview == "ping"
  end

  test "a stream without a usage chunk still logs the request with zero tokens",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      send_gateway_sse(req, sse_stream(["x"], usage: nil))
    end)

    assert post(conn, "/v1/chat/completions", @body).status == 200
    assert [%{prompt_tokens: 0, completion_tokens: 0}] = usage_logs(instance)
  end

  test "a gateway refusal on a streaming request arrives as that status, not an empty stream",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      gateway_error(req, 402, "insufficient_quota", "account balance is too low for this request")
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert json_response(conn, 402) == %{"error" => %{"type" => "insufficient_quota", "message" => "account balance is too low for this request"}}
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_abc"]
    assert usage_logs(instance) == []
  end

  test "502 when the gateway is down", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    assert %{"error" => %{"type" => "api_error"}} = json_response(post(conn, "/v1/chat/completions", @body), 502)
  end
end
