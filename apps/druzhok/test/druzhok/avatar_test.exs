defmodule Druzhok.AvatarTest do
  # async: false — app env (ruoc and Telegram stubs) and shared instance rows.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{Avatar, Instance, RuocStub}

  # A 2×2 PNG, so ffmpeg has a real picture to convert.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAEklEQVR4nGP8yjGPgYGBiQEMABPFAZ8Rl76UAAAAAElFTkSuQmCC"
       )

  setup do
    stub = RuocStub.start()
    tg = Bypass.open()
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")
    on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)

    inst =
      relay_instance(%{
        telegram_token: "123:secret",
        ruoc_api_key: "ruoc_key_bot",
        display_name: "Кеша",
        soul_preset: "humor"
      })

    %{stub: stub, tg: tg, inst: inst}
  end

  test "draws through ruoc on the bot's key and sets the result as a JPEG", %{stub: stub, tg: tg, inst: inst} do
    parent = self()

    Bypass.expect_once(stub.bypass, "POST", "/v1/images", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:ruoc, Plug.Conn.get_req_header(conn, "authorization"), Jason.decode!(body)})
      RuocStub.reply(conn, 200, %{"request_id" => "r", "model" => "m", "image" => %{"b64" => Base.encode64(@png), "mime" => "image/png"}})
    end)

    Bypass.expect_once(tg, "POST", "/bot123:secret/setMyProfilePhoto", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 5_000_000)
      send(parent, {:telegram, Plug.Conn.get_req_header(conn, "content-type"), body})
      Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":true}))
    end)

    assert :ok = Avatar.run(inst.name)
    assert_received {:ruoc, ["Bearer ruoc_key_bot"], %{"size" => "1024x1024", "prompt" => prompt}}
    assert prompt =~ "Кеша"
    assert prompt =~ "winking"
    assert_received {:telegram, ["multipart/form-data; boundary=" <> _], body}
    assert body =~ ~s({"photo":"attach://avatar","type":"static"}) or body =~ ~s({"type":"static","photo":"attach://avatar"})
    # A JPEG starts with FF D8 FF.
    assert body =~ <<0xFF, 0xD8, 0xFF>>
  end

  test "a refused drawing is logged and nothing is set", %{stub: stub, inst: inst} do
    Bypass.expect_once(stub.bypass, "POST", "/v1/images", fn conn ->
      RuocStub.reply(conn, 402, %{"error" => %{"type" => "insufficient_quota"}})
    end)

    log = ExUnit.CaptureLog.capture_log(fn -> Avatar.run(inst.name) end)
    assert log =~ "[avatar] #{inst.name}"
    assert log =~ "402"
  end

  test "redraw/2 draws the owner's description and returns the JPEG it set", %{stub: stub, tg: tg, inst: inst} do
    parent = self()

    Bypass.expect_once(stub.bypass, "POST", "/v1/images", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:prompt, Jason.decode!(body)["prompt"]})
      RuocStub.reply(conn, 200, %{"image" => %{"b64" => Base.encode64(@png)}})
    end)

    Bypass.expect_once(tg, "POST", "/bot123:secret/setMyProfilePhoto", fn conn ->
      Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":true}))
    end)

    assert {:ok, <<0xFF, 0xD8, 0xFF, _::binary>>} = Avatar.redraw(inst, "рыжий кот в очках")
    assert_received {:prompt, prompt}
    assert prompt =~ "рыжий кот в очках"
    assert prompt =~ "Кеша"
    refute prompt =~ "winking"
  end

  test "redraw/2 reports where it failed", %{stub: stub, tg: tg, inst: inst} do
    Bypass.expect_once(stub.bypass, "POST", "/v1/images", fn conn ->
      RuocStub.reply(conn, 402, %{"error" => %{"type" => "insufficient_quota"}})
    end)

    assert {:error, {:ruoc, 402, _} = reason} = Avatar.redraw(inst, "кот")
    assert Avatar.reason(reason) == "лимит тарифа исчерпан, подробности в «Кабинете»"
    assert Avatar.reason(reason, "en") =~ "limit"

    Bypass.expect_once(stub.bypass, "POST", "/v1/images", fn conn ->
      RuocStub.reply(conn, 200, %{"image" => %{"b64" => Base.encode64(@png)}})
    end)

    Bypass.expect_once(tg, "POST", "/bot123:secret/setMyProfilePhoto", fn conn ->
      Plug.Conn.resp(conn, 400, ~s({"ok":false,"description":"Bad Request"}))
    end)

    assert {:error, {:telegram, _} = reason} = Avatar.redraw(inst, "кот")
    assert Avatar.reason(reason) == "Telegram не принял картинку"
    assert {:error, :no_keys} = Avatar.redraw(%{inst | ruoc_api_key: nil}, "кот")
  end

  test "the prompt falls back to a friendly look without a character" do
    prompt = Avatar.prompt(%Instance{name: "max_1a2b", display_name: nil, soul_preset: nil})
    assert prompt =~ "max_1a2b"
    assert prompt =~ "friendly and kind"
    assert prompt =~ "No text"
  end
end
