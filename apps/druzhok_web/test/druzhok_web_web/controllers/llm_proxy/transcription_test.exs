defmodule DruzhokWebWeb.LlmProxy.TranscriptionTest do
  use DruzhokWebWeb.ProxyCase

  setup do
    path = Path.join(System.tmp_dir!(), "voice-#{System.unique_integer([:positive])}.oga")
    File.write!(path, "OggS-fake-bytes")
    on_exit(fn -> File.rm(path) end)
    %{upload: %Plug.Upload{path: path, filename: "voice.oga", content_type: "audio/ogg"}}
  end

  test "wraps the file as an input_audio part with format ogg and the pinned prompt",
       %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      assert sent["model"] == "google/gemini-2.5-flash"
      [%{"role" => "user", "content" => [text, audio]}] = sent["messages"]
      assert text["type"] == "text"
      assert text["text"] =~ "Transcribe the audio VERBATIM"
      assert audio == %{"type" => "input_audio", "input_audio" => %{"data" => Base.encode64("OggS-fake-bytes"), "format" => "ogg"}}
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("  привет мир \n")))
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload, "model" => "whisper-1"})

    assert json_response(conn, 200) == %{"text" => "привет мир"}
  end

  test "returns plain text when response_format=text", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hello")))
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload, "response_format" => "text"})
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert conn.resp_body == "hello"
  end

  test "uses the transcription_model setting when set", %{conn: conn, bypass: bypass, upload: upload} do
    Druzhok.Settings.set("transcription_model", "google/gemini-3-flash-preview")

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["model"] == "google/gemini-3-flash-preview"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x")))
    end)

    assert post(conn, "/v1/audio/transcriptions", %{"file" => upload}).status == 200
  end

  test "maps filename extensions to OpenRouter formats", %{conn: conn, bypass: bypass, upload: upload} do
    cases = [
      {"a.mp3", "mp3"},
      {"a.MPGA", "mp3"},
      {"a.wav", "wav"},
      {"a.opus", "ogg"},
      {"a.ogg", "ogg"},
      {"a.m4a", "m4a"},
      {"a.mp4", "mp4"},
      {"a.webm", "webm"},
      {"a.flac", "flac"},
      {"a.aiff", "aiff"},
      {"noext", "mp3"}
    ]

    Bypass.expect(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      [%{"content" => [_, audio]}] = Jason.decode!(raw)["messages"]
      send(self(), {:format, audio["input_audio"]["format"]})
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(audio["input_audio"]["format"])))
    end)

    for {filename, format} <- cases do
      conn = post(conn, "/v1/audio/transcriptions", %{"file" => %{upload | filename: filename}})
      assert json_response(conn, 200)["text"] == format, "#{filename} → #{format}"
    end
  end

  test "meters the call as request_type audio", %{conn: conn, bypass: bypass, upload: upload, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x", usage: %{"prompt_tokens" => 200, "completion_tokens" => 10, "cost" => 0.012})))
    end)

    post(conn, "/v1/audio/transcriptions", %{"file" => upload})

    assert [log] = usage_logs(instance)
    assert log.request_type == "audio"
    assert log.provider == "openrouter"
    assert log.model == "google/gemini-2.5-flash"
    assert log.total_tokens == 210
    assert log.cost_cents == 1
    assert spent_today(instance) == 1
  end

  test "400 when no file is attached", %{conn: conn} do
    conn = post(conn, "/v1/audio/transcriptions", %{"model" => "whisper-1"})
    assert json_response(conn, 400)["error"]["type"] == "invalid_request"
  end

  test "503 when no OpenRouter key is configured", %{conn: conn, upload: upload} do
    Application.delete_env(:druzhok, :openrouter_api_key)
    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 503)["error"]["message"] == "Audio transcription not configured"
  end

  test "falls back to the OpenRouter key from Settings", %{conn: conn, bypass: bypass, upload: upload} do
    Application.delete_env(:druzhok, :openrouter_api_key)
    Druzhok.Settings.set("openrouter_api_key", "settings-key")

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer settings-key"]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x")))
    end)

    assert post(conn, "/v1/audio/transcriptions", %{"file" => upload}).status == 200
  end

  test "relays upstream errors", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 400, ~s({"error":{"message":"bad audio"}}))
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 400)["error"]["message"] == "bad audio"
  end

  test "502 when the upstream is unreachable", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 502)["error"]["message"] == "Transcription provider unavailable"
  end

  test "returns an empty transcript when the upstream body is not JSON",
       %{conn: conn, bypass: bypass, upload: upload, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 200, "garbage") end)
    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 200) == %{"text" => ""}
    assert usage_logs(instance) == []
  end

  test "429 when the daily budget is spent", %{upload: upload} do
    instance = create_instance(%{daily_budget_cents: 10})
    Druzhok.Budget.deduct(instance.id, 10)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 429)["error"]["type"] == "budget_exceeded"
  end
end
