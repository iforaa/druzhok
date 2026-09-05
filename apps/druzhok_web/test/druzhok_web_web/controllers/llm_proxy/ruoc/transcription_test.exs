defmodule DruzhokWebWeb.LlmProxy.Ruoc.TranscriptionTest do
  use DruzhokWebWeb.RuocProxyCase

  setup do
    path = Path.join(System.tmp_dir!(), "voice-#{System.unique_integer([:positive])}.oga")
    File.write!(path, "OggS-fake-bytes")
    on_exit(fn -> File.rm(path) end)
    %{upload: %Plug.Upload{path: path, filename: "voice.oga", content_type: "audio/ogg"}}
  end

  test "base64s the upload as ogg to ruoc transcribe and returns {text}",
       %{conn: conn, bypass: bypass, upload: upload, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/transcribe", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert Jason.decode!(raw) == %{"audio" => Base.encode64("OggS-fake-bytes"), "format" => "ogg"}
      gateway_reply(req, 200, %{"text" => "  привет мир \n", "request_id" => "req_t"}, "req_t")
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload, "model" => "whisper-1"})

    assert json_response(conn, 200) == %{"text" => "привет мир"}
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_t"]
    assert [log] = usage_logs(instance)
    assert {log.request_type, log.provider, log.response_preview, log.cost_cents} == {"audio", "ruoc", "привет мир", 0}
  end

  test "returns plain text when response_format=text", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/transcribe", fn req -> gateway_reply(req, 200, %{"text" => "hello"}) end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload, "response_format" => "text"})
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert conn.resp_body == "hello"
  end

  test "maps mp3 and wav extensions, refuses others before calling the gateway",
       %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect(bypass, "POST", "/v1/transcribe", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      gateway_reply(req, 200, %{"text" => Jason.decode!(raw)["format"]})
    end)

    for {name, format} <- [{"a.mp3", "mp3"}, {"a.MPGA", "mp3"}, {"a.wav", "wav"}, {"a.opus", "ogg"}] do
      conn = post(conn, "/v1/audio/transcriptions", %{"file" => %{upload | filename: name}})
      assert json_response(conn, 200) == %{"text" => format}, name
    end

    for name <- ["a.webm", "a.m4a", "noext"] do
      conn = post(conn, "/v1/audio/transcriptions", %{"file" => %{upload | filename: name}})
      assert %{"error" => %{"type" => "invalid_request_error"}} = json_response(conn, 400), name
    end
  end

  test "no file is a 400", %{conn: conn} do
    assert json_response(post(conn, "/v1/audio/transcriptions", %{}), 400)["error"]["message"] == "No audio file provided"
  end

  for {status, type} <- [{402, "insufficient_quota"}, {413, "invalid_request_error"}, {429, "repeated_no_output"}] do
    test "relays a #{status} #{type}", %{conn: conn, bypass: bypass, upload: upload, instance: instance} do
      Bypass.expect_once(bypass, "POST", "/v1/transcribe", fn req -> gateway_error(req, unquote(status), unquote(type), "no") end)

      conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
      assert json_response(conn, unquote(status)) == %{"error" => %{"type" => unquote(type), "message" => "no"}}
      assert usage_logs(instance) == []
    end
  end

  test "502 when the gateway is down", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.down(bypass)
    assert %{"error" => %{"type" => "api_error"}} = json_response(post(conn, "/v1/audio/transcriptions", %{"file" => upload}), 502)
  end
end
