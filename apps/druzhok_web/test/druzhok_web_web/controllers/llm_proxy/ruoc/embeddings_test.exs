defmodule DruzhokWebWeb.LlmProxy.Ruoc.EmbeddingsTest do
  use DruzhokWebWeb.RuocProxyCase

  @body %{"model" => "ruoc-embed", "input" => ["query: кошка", "passage: кот"]}
  @reply %{
    "object" => "list",
    "model" => "ruoc-embed",
    "data" => [
      %{"object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2]},
      %{"object" => "embedding", "index" => 1, "embedding" => [0.3, 0.4]}
    ],
    "usage" => %{"prompt_tokens" => 9, "total_tokens" => 9}
  }

  test "forwards model and input with the bot's key and relays the answer", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert Jason.decode!(raw) == @body
      gateway_reply(req, 200, @reply, "req_emb")
    end)

    conn = post(conn, "/v1/embeddings", Map.put(@body, "encoding_format", "float"))
    assert json_response(conn, 200) == @reply
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_emb"]
  end

  test "a single string input is forwarded as is", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["input"] == "one"
      gateway_reply(req, 200, @reply)
    end)

    assert post(conn, "/v1/embeddings", %{"model" => "ruoc-embed", "input" => "one"}).status == 200
  end

  test "meters as embedding with the token count, no cost", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> gateway_reply(req, 200, @reply) end)
    post(conn, "/v1/embeddings", @body)

    assert [log] = usage_logs(instance)
    assert log.request_type == "embedding"
    assert log.provider == "ruoc"
    assert log.model == "ruoc-embed"
    assert log.prompt_tokens == 9 and log.completion_tokens == 0 and log.total_tokens == 9
    assert log.cost_cents == 0
    assert log.prompt_preview == "query: кошка"
  end

  test "a bad input is refused before the gateway", %{conn: conn} do
    for body <- [%{"model" => "ruoc-embed"}, %{"input" => [1]}, %{"input" => []}] do
      conn = post(conn, "/v1/embeddings", body)
      assert json_response(conn, 400)["error"]["type"] == "invalid_request_error"
    end
  end

  test "over-limit input is refused before the gateway", %{conn: conn} do
    conn1 = post(conn, "/v1/embeddings", %{"input" => List.duplicate("x", 65)})
    assert json_response(conn1, 413)["error"]["message"] =~ "64"

    conn2 = post(conn, "/v1/embeddings", %{"input" => [String.duplicate("я", 8_001)]})
    assert json_response(conn2, 413)["error"]["message"] =~ "8000"
  end

  test "an empty balance relays the 402 unchanged", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      gateway_error(req, 402, "insufficient_quota", "account balance is too low to embed this batch")
    end)

    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 402)["error"]["type"] == "insufficient_quota"
    assert usage_logs(instance) == []
  end

  test "other refusals keep status and message", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> gateway_error(req, 413, "invalid_request_error", "too many texts") end)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 413)["error"]["message"] == "too many texts"
  end

  test "an unreachable gateway is a 502", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 502)["error"]["message"] == "embeddings provider unavailable"
  end
end
