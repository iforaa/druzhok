defmodule DruzhokWebWeb.LlmProxy.EmbeddingsTest do
  use DruzhokWebWeb.ProxyCase

  @body %{"model" => "openai/text-embedding-3-small", "input" => ["a", "b"]}
  @upstream %{
    "object" => "list",
    "data" => [%{"embedding" => [0.1, 0.2], "index" => 0}, %{"embedding" => [0.3, 0.4], "index" => 1}],
    "usage" => %{"prompt_tokens" => 6, "total_tokens" => 6}
  }

  test "forwards to /embeddings and returns the body verbatim", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw) == @body
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      Plug.Conn.resp(req, 200, Jason.encode!(@upstream))
    end)

    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 200) == @upstream
  end

  test "logs usage as request_type embedding with zero cost", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> Plug.Conn.resp(req, 200, Jason.encode!(@upstream)) end)
    post(conn, "/v1/embeddings", @body)

    assert [log] = usage_logs(instance)
    assert log.request_type == "embedding"
    assert log.model == "openai/text-embedding-3-small"
    assert log.provider == "openrouter"
    assert log.prompt_tokens == 6
    assert log.completion_tokens == 0
    assert log.total_tokens == 6
    assert log.cost_cents == 0
  end

  test "skips logging when usage is missing or zero", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect(bypass, "POST", "/v1/embeddings", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(Map.put(@upstream, "usage", %{"total_tokens" => 0})))
    end)

    post(conn, "/v1/embeddings", @body)
    assert usage_logs(instance) == []
  end

  test "relays non-200 without logging", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> Plug.Conn.resp(req, 400, ~s({"error":"bad"})) end)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 400) == %{"error" => "bad"}
    assert usage_logs(instance) == []
  end

  test "502 when unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 502)["error"]["message"] == "Embeddings provider unavailable"
  end
end
