defmodule DruzhokWebWeb.LlmProxy.ResponsesTest do
  use DruzhokWebWeb.ProxyCase

  @input [
    %{"role" => "developer", "content" => "be brief"},
    %{
      "role" => "user",
      "content" => [
        %{"type" => "input_text", "text" => "what is this?"},
        %{"type" => "input_image", "image_url" => "data:image/png;base64,AAAA", "detail" => "low"}
      ]
    }
  ]

  test "converts the Responses input into a chat request on the instance's vision model",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "google/gemini-2.5-flash-lite"
      assert sent["max_tokens"] == 1024
      assert sent["stream"] == false
      assert sent["usage"] == %{"include" => true}
      [system, user] = sent["messages"]
      assert system == %{"role" => "system", "content" => "be brief"}

      assert user["content"] == [
               %{"type" => "input_text", "text" => "what is this?"},
               %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA", "detail" => "low"}}
             ]

      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("a cat", usage: %{"prompt_tokens" => 300, "completion_tokens" => 4, "cost" => 0.0})))
    end)

    conn = post(conn, "/v1/responses", %{"model" => "gpt-4o", "input" => @input})

    assert %{
             "id" => "resp_proxy",
             "object" => "response",
             "status" => "completed",
             "model" => "gpt-4o",
             "output" => [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "a cat"}]}],
             "usage" => %{"input_tokens" => 300, "output_tokens" => 4}
           } = json_response(conn, 200)
  end

  test "honours max_output_tokens and a bare string input", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["max_tokens"] == 50
      assert sent["messages"] == [%{"role" => "user", "content" => "hi"}]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hey")))
    end)

    assert post(conn, "/v1/responses", %{"model" => "m", "input" => "hi", "max_output_tokens" => 50}).status == 200
  end

  test "sends a default prompt when input is empty", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["messages"] == [%{"role" => "user", "content" => "Describe this image."}]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/responses", %{"model" => "m"}).status == 200
  end

  test "keeps string-content roles and stringifies unknown input items", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      [a, b, c] = Jason.decode!(raw)["messages"]
      assert a == %{"role" => "assistant", "content" => "earlier"}
      assert b == %{"role" => "user", "content" => "plain"}
      assert c["role"] == "user" and c["content"] =~ "weird"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    input = [%{"role" => "assistant", "content" => "earlier"}, "plain", %{"type" => "weird"}]
    assert post(conn, "/v1/responses", %{"model" => "m", "input" => input}).status == 200
  end

  test "uses the instance image_model and meters as request_type image", %{bypass: bypass} do
    instance = create_instance(%{image_model: "openai/gpt-5.4-mini"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["model"] == "openai/gpt-5.4-mini"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x", usage: %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.02})))
    end)

    post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "image"
    assert log.model == "openai/gpt-5.4-mini"
    assert log.total_tokens == 12
    assert log.cost_cents == 2
  end

  test "streams the full text as a Responses SSE event sequence",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["stream"] == true
      send_sse(req, sse_stream(["a ", "cat"], usage: %{"prompt_tokens" => 7, "completion_tokens" => 2, "cost" => 0.03}))
    end)

    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi", "stream" => true})

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"

    events = conn.resp_body |> sse_payloads() |> Enum.map(&Jason.decode!/1)

    assert Enum.map(events, & &1["type"]) == [
             "response.output_item.added",
             "response.output_text.delta",
             "response.output_text.done",
             "response.output_item.done",
             "response.completed"
           ]

    assert Enum.at(events, 1)["delta"] == "a cat"
    assert Enum.at(events, 2)["text"] == "a cat"
    completed = List.last(events)["response"]
    assert completed["model"] == "google/gemini-2.5-flash-lite"
    assert completed["usage"] == %{"input_tokens" => 7, "output_tokens" => 2}

    assert [%{request_type: "image", cost_cents: 3, total_tokens: 9}] = usage_logs(instance)
  end

  test "streams an empty text when the upstream is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi", "stream" => true})
    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "passes a non-JSON upstream error body through unchanged", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 500, "boom") end)
    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"})
    assert conn.status == 500
    assert conn.resp_body == "boom"
  end

  test "relays a JSON upstream error with its status", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 429, ~s({"error":{"message":"slow"}}))
    end)

    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"})
    assert json_response(conn, 429)["error"]["message"] == "slow"
    assert usage_logs(instance) == []
  end

  test "502 when unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"})
    assert json_response(conn, 502)["error"]["message"] == "Provider unavailable"
  end

end
