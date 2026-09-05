defmodule DruzhokWebWeb.LlmProxy.Ruoc.ChatSyncTest do
  use DruzhokWebWeb.RuocProxyCase

  @body %{"model" => "ruoc-flash", "messages" => [%{"role" => "user", "content" => "ping"}]}

  test "forwards with the bot's ruoc key and relays body, status and request id",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert sent["model"] == "ruoc-flash"
      assert sent["messages"] == @body["messages"]
      # Nothing OpenRouter-specific is injected.
      refute Map.has_key?(sent, "usage")
      refute Map.has_key?(sent, "max_tokens")
      gateway_reply(req, 200, chat_completion("pong", model: "ruoc-flash"), "req_1")
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) == "pong"
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_1"]
  end

  test "meters tokens and previews with provider ruoc and no cost",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      gateway_reply(req, 200, chat_completion("pong", usage: %{"prompt_tokens" => 12, "completion_tokens" => 3}))
    end)

    post(conn, "/v1/chat/completions", @body)

    assert [log] = usage_logs(instance)
    assert log.provider == "ruoc"
    assert log.model == "ruoc-flash"
    assert log.prompt_tokens == 12
    assert log.completion_tokens == 3
    assert log.cost_cents == 0
    assert log.prompt_preview == "ping"
    assert log.response_preview == "pong"
    assert Jason.decode!(log.request_body)["messages"] == @body["messages"]
  end

  test "a bot without a ruoc key is refused with 503 before any upstream call", %{bypass: bypass} do
    legacy = create_instance(%{ruoc_api_key: nil})
    Bypass.stub(bypass, "POST", "/v1/chat/completions", fn req -> gateway_reply(req, 200, chat_completion("no")) end)

    conn = post(authed(build_conn(), legacy), "/v1/chat/completions", @body)
    assert %{"error" => %{"type" => "api_error", "message" => "bot not migrated" <> _}} = json_response(conn, 503)
  end

  test "an empty balance becomes a plain reply in the bot's language, not an error",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      gateway_error(req, 402, "insufficient_quota", "account balance is too low for this request")
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    body = json_response(conn, 200)
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "💳 Баланс бота исчерпан. Пополни счёт, чтобы продолжить."
    assert get_in(body, ["choices", Access.at(0), "finish_reason"]) == "stop"
    assert body["model"] == "ruoc-flash"
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_abc"]
    assert usage_logs(instance) == []
  end

  test "the balance notice is English for a non-Russian bot", %{bypass: bypass} do
    english = create_instance(%{model: "ruoc-flash", ruoc_account_id: "acct-2", ruoc_api_key: "ruoc_en", language: "en"})
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_error(req, 402, "insufficient_quota", "no") end)

    conn = post(authed(build_conn(), english), "/v1/chat/completions", @body)
    assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) =~ "balance is used up"
  end

  for {status, type} <- [{429, "rate_limit_error"}, {404, "invalid_request_error"}] do
    test "relays a #{status} #{type} with the gateway's envelope", %{conn: conn, bypass: bypass, instance: instance} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        gateway_error(req, unquote(status), unquote(type), "nope")
      end)

      conn = post(conn, "/v1/chat/completions", @body)

      assert json_response(conn, unquote(status)) == %{"error" => %{"type" => unquote(type), "message" => "nope"}}
      assert get_resp_header(conn, "x-ruoc-request-id") == ["req_abc"]
      assert usage_logs(instance) == []
    end
  end

  test "502 api_error when the gateway is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/chat/completions", @body)
    assert %{"error" => %{"type" => "api_error"}} = json_response(conn, 502)
  end

  test "strips images for a model without the attachment capability", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      [msg] = Jason.decode!(raw)["messages"]
      assert msg["content"] == "look"
      gateway_reply(req, 200, chat_completion("ok"))
    end)

    body = %{
      "model" => "ruoc-standard",
      "messages" => [%{"role" => "user", "content" => [%{"type" => "text", "text" => "look"}, %{"type" => "image_url", "image_url" => %{"url" => "data:x"}}]}]
    }

    assert post(conn, "/v1/chat/completions", body).status == 200
  end

  test "keeps images for a vision model", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      [msg] = Jason.decode!(raw)["messages"]
      assert [%{"type" => "text"}, %{"type" => "image_url"}] = msg["content"]
      gateway_reply(req, 200, chat_completion("ok"))
    end)

    body = %{
      "model" => "ruoc-flash",
      "messages" => [%{"role" => "user", "content" => [%{"type" => "text", "text" => "look"}, %{"type" => "image_url", "image_url" => %{"url" => "data:x"}}]}]
    }

    assert post(conn, "/v1/chat/completions", body).status == 200
  end
end
