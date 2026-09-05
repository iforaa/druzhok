defmodule DruzhokWebWeb.LlmProxy.ChatStreamTest do
  use DruzhokWebWeb.ProxyCase

  @body %{
    "model" => "z-ai/glm-5.3-flash",
    "stream" => true,
    "messages" => [%{"role" => "user", "content" => "ping"}]
  }

  test "relays SSE chunks verbatim as text/event-stream", %{conn: conn, bypass: bypass} do
    lines = sse_stream(["po", "ng"])

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["stream"] == true
      send_sse(req, lines)
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
    assert conn.resp_body == Enum.join(lines)
  end

  test "captures the trailing usage chunk and meters it",
       %{conn: conn, bypass: bypass, instance: instance} do
    usage = %{"prompt_tokens" => 40, "completion_tokens" => 8, "cost" => 0.031}

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      send_sse(req, sse_stream(["a", "b"], usage: usage))
    end)

    post(conn, "/v1/chat/completions", @body)

    assert [log] = usage_logs(instance)
    assert log.prompt_tokens == 40
    assert log.completion_tokens == 8
    assert log.cost_cents == 3
    assert log.response_preview == nil
    assert log.prompt_preview == "ping"
    assert spent_today(instance) == 3
  end

  test "logs nothing when the stream carries no usage chunk",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      send_sse(req, sse_stream(["a"], usage: nil))
    end)

    post(conn, "/v1/chat/completions", @body)
    assert usage_logs(instance) == []
  end

  test "relays a non-200 upstream body inside the 200 event stream", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 429, ~s({"error":{"message":"slow down"}}))
    end)

    conn = post(conn, "/v1/chat/completions", @body)
    # The chunked 200 is committed before the upstream status is known.
    assert conn.status == 200
    assert conn.resp_body == ~s({"error":{"message":"slow down"}})
  end

  test "returns 200 with an empty body when the upstream is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/chat/completions", @body)
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "429 budget_exceeded before opening the stream" do
    instance = create_instance(%{daily_budget_cents: 5})
    Druzhok.Budget.deduct(instance.id, 5)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    conn = post(conn, "/v1/chat/completions", @body)
    assert json_response(conn, 429)["error"]["type"] == "budget_exceeded"
  end

  describe "mimo-v2-pro fake stream" do
    @mimo Map.put(@body, "model", "xiaomi/mimo-v2-pro")

    test "asks the upstream for a non-streaming reply and synthesizes SSE",
         %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        sent = Jason.decode!(raw)
        assert sent["stream"] == false
        refute Map.has_key?(sent, "stream_options")
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hello", model: "xiaomi/mimo-v2-pro")))
      end)

      conn = post(conn, "/v1/chat/completions", @mimo)

      assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
      payloads = sse_payloads(conn.resp_body)
      assert List.last(payloads) == "[DONE]"
      [first, second] = Enum.map(Enum.drop(payloads, -1), &Jason.decode!/1)
      assert first["id"] == "gen-test-1"
      assert first["model"] == "xiaomi/mimo-v2-pro"
      assert get_in(first, ["choices", Access.at(0), "delta"]) == %{"role" => "assistant", "content" => "hello"}
      assert get_in(second, ["choices", Access.at(0), "finish_reason"]) == "stop"
    end

    test "meters the synthesized stream with the response text as preview",
         %{conn: conn, bypass: bypass, instance: instance} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hello", usage: %{"prompt_tokens" => 9, "completion_tokens" => 1, "cost" => 0.02})))
      end)

      post(conn, "/v1/chat/completions", @mimo)

      assert [log] = usage_logs(instance)
      assert log.model == "xiaomi/mimo-v2-pro"
      assert log.response_preview == "hello"
      assert log.cost_cents == 2
    end

    test "emits a usage chunk only when stream_options.include_usage was requested",
         %{conn: conn, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hi", usage: %{"prompt_tokens" => 3, "completion_tokens" => 2, "cost" => 0.0})))
      end)

      usage_chunk = fn conn ->
        conn.resp_body
        |> sse_payloads()
        |> Enum.reject(&(&1 == "[DONE]"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&Map.has_key?(&1, "usage"))
      end

      with_usage = post(conn, "/v1/chat/completions", Map.put(@mimo, "stream_options", %{"include_usage" => true}))
      assert usage_chunk.(with_usage)["usage"] == %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}

      without = post(conn, "/v1/chat/completions", @mimo)
      assert usage_chunk.(without) == nil
    end

    test "synthesizes a tool_calls delta when the reply is a tool call", %{conn: conn, bypass: bypass} do
      calls = [%{"id" => "c1", "type" => "function", "function" => %{"name" => "f", "arguments" => "{}"}}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(nil, tool_calls: calls)))
      end)

      conn = post(conn, "/v1/chat/completions", @mimo)
      [first | _] = conn.resp_body |> sse_payloads() |> Enum.reject(&(&1 == "[DONE]")) |> Enum.map(&Jason.decode!/1)
      assert get_in(first, ["choices", Access.at(0), "delta", "tool_calls"]) == calls
    end

    test "relays an upstream error inside the SSE stream", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 500, ~s({"error":"boom"}))
      end)

      conn = post(conn, "/v1/chat/completions", @mimo)
      assert conn.status == 200
      assert sse_payloads(conn.resp_body) == [~s({"error":"boom"}), "[DONE]"]
    end

    test "reports an unreachable upstream inside the SSE stream", %{conn: conn, bypass: bypass} do
      Bypass.down(bypass)
      conn = post(conn, "/v1/chat/completions", @mimo)
      assert sse_payloads(conn.resp_body) == [~s({"error":"upstream failed"}), "[DONE]"]
    end
  end
end
