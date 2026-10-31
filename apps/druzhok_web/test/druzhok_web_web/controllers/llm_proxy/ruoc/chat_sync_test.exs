defmodule DruzhokWebWeb.LlmProxy.Ruoc.ChatSyncTest do
  use DruzhokWebWeb.RuocProxyCase

  @body %{"model" => "ruoc-flash", "messages" => [%{"role" => "user", "content" => "ping"}]}
  # A gateway turn: hermes's agent prompt and its tools.
  @turn %{
    "model" => "ruoc-flash",
    "messages" => [%{"role" => "system", "content" => "Тебя зовут Вася."}, %{"role" => "user", "content" => "ping"}],
    "tools" => [%{"type" => "function", "function" => %{"name" => "memory"}}]
  }

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
    # The full request is not kept: it made up most of the database.
    assert %{rows: [[nil]]} = Druzhok.Repo.query!("SELECT request_body FROM usage_logs WHERE id = ?", [log.id])
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

    conn = post(conn, "/v1/chat/completions", @turn)

    body = json_response(conn, 200)
    assert get_in(body, ["choices", Access.at(0), "message", "content"]) == "Лимит тарифа на сейчас исчерпан. Когда он обновится и как сменить тариф — в «Кабинете»."
    assert get_in(body, ["choices", Access.at(0), "finish_reason"]) == "stop"
    assert body["model"] == "ruoc-flash"
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_abc"]
    assert usage_logs(instance) == []
  end

  test "the balance notice is English for a non-Russian bot", %{bypass: bypass} do
    english = create_instance(%{model: "ruoc-flash", ruoc_account_id: "acct-2", ruoc_api_key: "ruoc_en", language: "en"})
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_error(req, 402, "insufficient_quota", "no") end)

    conn = post(authed(build_conn(), english), "/v1/chat/completions", @turn)
    assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) =~ "plan's limit is used up"
  end

  describe "a 402 on hermes's auxiliary calls" do
    for {label, body} <- [
          {"the compressor's single user message", %{"messages" => [%{"role" => "user", "content" => "summarise"}]}},
          {"a session title",
           %{"messages" => [%{"role" => "system", "content" => "You name chat sessions. Given the user's opening message…"}, %{"role" => "user", "content" => "привет"}]}},
          {"a memory query rewrite",
           %{"messages" => [%{"role" => "system", "content" => "You rewrite a user's latest message into one concise English question for memory retrieval.\n…"}, %{"role" => "user", "content" => "x"}]}}
        ] do
      test "stays a 402: #{label}", %{conn: conn, bypass: bypass} do
        Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_error(req, 402, "insufficient_quota", "no") end)

        conn = post(conn, "/v1/chat/completions", Map.put(unquote(Macro.escape(body)), "model", "ruoc-flash"))
        assert json_response(conn, 402)["error"]["type"] == "insufficient_quota"
      end
    end

    for {label, body} <- [
          {"a gateway turn with tools", @turn},
          {"a zero-toolset cron run (agent prompt, no tools)", Map.delete(@turn, "tools")},
          {"an unknown system prompt, no tools",
           %{"messages" => [%{"role" => "system", "content" => "Something new"}, %{"role" => "user", "content" => "x"}]}}
        ] do
      test "gets the notice: #{label}", %{conn: conn, bypass: bypass} do
        Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_error(req, 402, "insufficient_quota", "no") end)

        conn = post(conn, "/v1/chat/completions", Map.put(unquote(Macro.escape(body)), "model", "ruoc-flash"))
        assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) =~ "Лимит тарифа"
      end
    end
  end

  describe "a spent window (429 usage_limit_reached)" do
    setup do
      watch_cabinet()
    end

    test "becomes the notice and tells the owner", %{conn: conn, bypass: bypass, instance: instance} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", &usage_limit/1)

      conn = post(conn, "/v1/chat/completions", @turn)

      assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) ==
               DruzhokWebWeb.LlmProxy.BalanceNotice.text(instance)

      assert get_resp_header(conn, "x-ruoc-request-id") == ["req_abc"]
      assert usage_logs(instance) == []
      assert_owner_told(instance)
    end

    test "an auxiliary call keeps the real 429 and still tells the owner", %{conn: conn, bypass: bypass, instance: instance} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", &usage_limit/1)

      conn = post(conn, "/v1/chat/completions", @body)

      assert %{"type" => "usage_limit_reached", "resets_at" => "2026-11-01T10:00:00Z"} = json_response(conn, 429)["error"]
      assert_owner_told(instance)
    end

    test "an ordinary 429 is relayed and the owner is not told", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_error(req, 429, "rate_limit_error", "nope") end)

      conn = post(conn, "/v1/chat/completions", @turn)

      assert json_response(conn, 429) == %{"error" => %{"type" => "rate_limit_error", "message" => "nope"}}
      refute_owner_told()
    end

    test "a 429 whose body is not JSON is relayed", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_reply(req, 429, "busy") end)

      conn = post(conn, "/v1/chat/completions", @turn)

      assert conn.status == 429
      assert conn.resp_body == "busy"
      refute_owner_told()
    end
  end

  test "a 402 still tells the owner", %{conn: conn, bypass: bypass, instance: instance} do
    watch_cabinet()
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> gateway_error(req, 402, "insufficient_quota", "no") end)

    assert json_response(post(conn, "/v1/chat/completions", @turn), 200)
    assert_owner_told(instance)
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
