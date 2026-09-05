defmodule DruzhokWebWeb.LlmProxy.TtsTest do
  use DruzhokWebWeb.ProxyCase

  @body %{"model" => "gpt-4o-mini-tts", "voice" => "alloy", "input" => "Привет, как дела?"}

  setup do
    Druzhok.Settings.set("openai_api_key", "sk-test-openai")
    :ok
  end

  test "forwards the body to OpenAI with the OpenAI key and returns the audio bytes",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw) == @body
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer sk-test-openai"]

      req
      |> Plug.Conn.put_resp_content_type("audio/mpeg")
      |> Plug.Conn.resp(200, <<0xFF, 0xFB, 0x90, 0x00>>)
    end)

    conn = post(conn, "/v1/audio/speech", @body)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"
    assert conn.resp_body == <<0xFF, 0xFB, 0x90, 0x00>>
  end

  test "meters characters as prompt_tokens at 0.00006 cents each",
       %{conn: conn, bypass: bypass, instance: instance} do
    long = String.duplicate("а", 50_000)

    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      Plug.Conn.resp(req, 200, "mp3")
    end)

    post(conn, "/v1/audio/speech", Map.put(@body, "input", long))

    assert [log] = usage_logs(instance)
    assert log.request_type == "tts"
    assert log.provider == "openai"
    assert log.model == "gpt-4o-mini-tts"
    assert log.prompt_tokens == 50_000
    assert log.total_tokens == 50_000
    assert log.cost_cents == 3
    assert log.prompt_preview == String.slice(long, 0, 500)
  end

  test "503 when no OpenAI key is configured", %{conn: conn} do
    Druzhok.Settings.set("openai_api_key", "")
    conn = post(conn, "/v1/audio/speech", @body)
    assert json_response(conn, 503)["error"]["message"] == "Text-to-speech not configured"
  end

  test "relays upstream errors", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      Plug.Conn.resp(req, 401, ~s({"error":{"message":"bad key"}}))
    end)

    conn = post(conn, "/v1/audio/speech", @body)
    assert json_response(conn, 401)["error"]["message"] == "bad key"
  end

  test "502 when OpenAI is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/audio/speech", @body)
    assert json_response(conn, 502)["error"]["message"] == "TTS provider unavailable"
  end

end
