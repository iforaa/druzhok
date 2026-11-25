defmodule DruzhokWebWeb.LlmProxy.TtsTest do
  use DruzhokWebWeb.ProxyCase

  @body %{"model" => "gpt-4o-mini-tts", "voice" => "alloy", "input" => "Привет, как дела?"}

  setup do
    Druzhok.Settings.set("openai_api_key", "sk-test-openai")
    Application.put_env(:druzhok_web, :tts_plan_check, fn _ -> :ok end)
    Druzhok.TtsGate.reset()

    on_exit(fn ->
      Application.delete_env(:druzhok_web, :tts_plan_check)
      Druzhok.TtsGate.reset()
    end)

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
    long = String.duplicate("а", 4000)

    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      Plug.Conn.resp(req, 200, "mp3")
    end)

    post(conn, "/v1/audio/speech", Map.put(@body, "input", long))

    assert [log] = usage_logs(instance)
    assert log.request_type == "tts"
    assert log.provider == "openai"
    assert log.model == "gpt-4o-mini-tts"
    assert log.prompt_tokens == 4000
    assert log.total_tokens == 4000
    assert log.cost_cents == 0
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

  test "the model is always gpt-4o-mini-tts and only speech fields reach OpenAI",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)

      assert Jason.decode!(raw) == %{
               "model" => "gpt-4o-mini-tts",
               "voice" => "alloy",
               "input" => "hi",
               "speed" => 1.5
             }

      Plug.Conn.resp(req, 200, "mp3")
    end)

    body = %{
      "model" => "tts-1-hd",
      "voice" => "alloy",
      "input" => "hi",
      "speed" => 1.5,
      "n" => 10
    }

    assert post(conn, "/v1/audio/speech", body).status == 200
  end

  test "refuses empty or over-long input without calling OpenAI", %{conn: conn} do
    assert json_response(post(conn, "/v1/audio/speech", Map.delete(@body, "input")), 400)

    long = String.duplicate("а", 4097)
    assert json_response(post(conn, "/v1/audio/speech", Map.put(@body, "input", long)), 400)
  end

  test "402 when the bot's plan cannot pay, without calling OpenAI", %{conn: conn} do
    Application.put_env(:druzhok_web, :tts_plan_check, fn _ -> {:error, :plan} end)

    assert json_response(post(conn, "/v1/audio/speech", @body), 402)["error"]["type"] ==
             "insufficient_quota"
  end

  test "429 past the hourly count, without calling OpenAI", %{conn: conn, instance: instance} do
    for _ <- 1..Druzhok.TtsGate.per_hour(), do: assert(Druzhok.TtsGate.take(instance.id) == :ok)

    assert json_response(post(conn, "/v1/audio/speech", @body), 429)["error"]["type"] ==
             "rate_limit_error"
  end
end
