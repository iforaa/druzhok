defmodule DruzhokWebWeb.LlmProxy.ChatSyncTest do
  use DruzhokWebWeb.ProxyCase

  @body %{
    "model" => "z-ai/glm-5.3-flash",
    "messages" => [%{"role" => "user", "content" => "ping"}]
  }

  test "forwards to OpenRouter with the server key and returns the body verbatim",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      assert sent["model"] == "z-ai/glm-5.3-flash"
      assert sent["messages"] == @body["messages"]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("pong")))
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert conn.status == 200
    assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) == "pong"
  end

  test "passes OpenRouter attribution headers through", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      assert Plug.Conn.get_req_header(req, "http-referer") == ["https://druzhok.example"]
      assert Plug.Conn.get_req_header(req, "x-openrouter-title") == ["Druzhok"]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    conn =
      conn
      |> put_req_header("http-referer", "https://druzhok.example")
      |> put_req_header("x-openrouter-title", "Druzhok")
      |> post("/v1/chat/completions", @body)

    assert conn.status == 200
  end

  test "injects max_tokens=4096 and usage.include when the client sent neither",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["max_tokens"] == 4096
      assert sent["usage"] == %{"include" => true}
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/chat/completions", @body).status == 200
  end

  test "keeps the client's own max_tokens", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["max_tokens"] == 77
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/chat/completions", Map.put(@body, "max_tokens", 77)).status == 200
  end

  test "disables reasoning for xiaomi/mimo models unless the client set it",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["reasoning"] == %{"enabled" => false}
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/chat/completions", Map.put(@body, "model", "xiaomi/mimo-v2.5-pro")).status == 200
  end

  test "logs usage with OpenRouter's reported cost and deducts the budget",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      body = chat_completion("pong", usage: %{"prompt_tokens" => 120, "completion_tokens" => 30, "cost" => 0.0451})
      Plug.Conn.resp(req, 200, Jason.encode!(body))
    end)

    post(conn, "/v1/chat/completions", @body)

    assert [log] = usage_logs(instance)
    assert log.prompt_tokens == 120
    assert log.completion_tokens == 30
    assert log.total_tokens == 150
    assert log.cost_cents == 5
    assert log.request_type == "chat"
    assert log.provider == "openrouter"
    assert log.model == "z-ai/glm-5.3-flash"
    assert log.prompt_preview == "ping"
    assert log.response_preview == "pong"
    assert Jason.decode!(log.request_body)["messages"] == @body["messages"]
    assert spent_today(instance) == 5
  end

  test "prompt preview takes the text parts of a multimodal last message",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    body = %{
      "model" => "z-ai/glm-5.3-flash",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "what"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}},
            %{"type" => "text", "text" => "is this"}
          ]
        }
      ]
    }

    post(conn, "/v1/chat/completions", body)
    assert [%{prompt_preview: "what is this"}] = usage_logs(instance)
  end

  test "falls back to the catalog price when usage.cost is absent",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      # glm-5.3-flash: 8 cents/M in, 25 cents/M out → 1M in = 8 cents
      body = chat_completion("x", usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})
      Plug.Conn.resp(req, 200, Jason.encode!(body))
    end)

    post(conn, "/v1/chat/completions", @body)
    assert [%{cost_cents: 8}] = usage_logs(instance)
  end

  test "does not log when the upstream reports zero tokens",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x", usage: %{"prompt_tokens" => 0, "completion_tokens" => 0})))
    end)

    post(conn, "/v1/chat/completions", @body)
    assert usage_logs(instance) == []
  end

  test "relays an upstream error status and body unchanged", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 429, Jason.encode!(%{"error" => %{"message" => "slow down"}}))
    end)

    conn = post(conn, "/v1/chat/completions", @body)
    assert conn.status == 429
    assert json_response(conn, 429)["error"]["message"] == "slow down"
  end

  test "answers 502 when the upstream is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)

    conn = post(conn, "/v1/chat/completions", @body)
    assert json_response(conn, 502) == %{"error" => %{"message" => "Provider unavailable", "type" => "server_error"}}
  end

  test "refuses with 429 budget_exceeded before touching the upstream when today's spend hit the limit",
       %{bypass: _bypass} do
    instance = create_instance(%{daily_budget_cents: 50})
    Druzhok.Budget.deduct(instance.id, 50)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    # No Bypass expectation: any upstream call would fail the test with "unexpected request".

    conn = post(conn, "/v1/chat/completions", @body)
    resp = json_response(conn, 429)
    assert resp["error"]["type"] == "budget_exceeded"
    assert resp["error"]["message"] =~ "0.50"
  end

  test "budget resets lazily on a new day", %{conn: conn, bypass: bypass, instance: instance} do
    limited = create_instance(%{daily_budget_cents: 10})
    Druzhok.Budget.deduct(limited.id, 10)

    # Move yesterday's spend back a day; the next check must zero it.
    budget = Druzhok.Repo.get_by!(Druzhok.Budget, instance_id: limited.id)
    budget |> Druzhok.Budget.changeset(%{reset_at: Date.add(Date.utc_today(), -1)}) |> Druzhok.Repo.update!()

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    conn = conn |> authed(limited) |> post("/v1/chat/completions", @body)
    assert conn.status == 200
    assert spent_today(limited) == 2
    assert spent_today(instance) == 0
  end

  test "rejects an unknown tenant key with 401" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer dk-nobody-xxxx")
      |> post("/v1/chat/completions", @body)

    assert json_response(conn, 401)["error"]["type"] == "authentication_error"
  end

  test "rejects a missing Authorization header with 401" do
    conn = post(Phoenix.ConnTest.build_conn(), "/v1/chat/completions", @body)
    assert json_response(conn, 401)["error"]["message"] == "Missing Authorization header"
  end

  test "strips image parts for a model on the non-vision list", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      [msg] = Jason.decode!(raw)["messages"]
      assert msg["content"] == "look"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    body = %{
      "model" => "deepseek/deepseek-v3.2",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "look"},
            %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}}
          ]
        }
      ]
    }

    assert post(conn, "/v1/chat/completions", body).status == 200
  end
end
