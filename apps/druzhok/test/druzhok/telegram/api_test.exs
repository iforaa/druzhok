defmodule Druzhok.Telegram.APITest do
  # async: false — swaps the Telegram base URL in app env.
  use ExUnit.Case, async: false

  alias Druzhok.Telegram.API

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:druzhok, :telegram_api_base)
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      if prev,
        do: Application.put_env(:druzhok, :telegram_api_base, prev),
        else: Application.delete_env(:druzhok, :telegram_api_base)
    end)

    %{bypass: bypass}
  end

  test "posts JSON to /bot<token>/<method> and unwraps result", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/sendMessage", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Jason.decode!(raw) == %{"chat_id" => 5, "text" => "hi", "parse_mode" => "Markdown"}
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 9}}))
    end)

    assert {:ok, %{"message_id" => 9}} = API.send_message("TOK", 5, "hi", %{parse_mode: "Markdown"})
  end

  test "edit_message_text, answer_callback_query, send_chat_action and get_updates encode their params",
       %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/botTOK/:method", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(self(), {conn.path_params["method"], Jason.decode!(raw)})
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => true}))
    end)

    # The Bypass handler runs in another process; collect via the calls it made.
    assert {:ok, true} = API.edit_message_text("TOK", 5, 9, "new", %{reply_markup: "{}"})
    assert {:ok, true} = API.answer_callback_query("TOK", "cb1")
    assert {:ok, true} = API.send_chat_action("TOK", 5)
    assert {:ok, true} = API.get_updates("TOK", 42, 7)
    assert {:ok, true} = API.get_file("TOK", "f1")
  end

  test "returns {:error, body} when Telegram says ok=false", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getMe", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "description" => "Unauthorized"}))
    end)

    assert {:error, %{"ok" => false, "description" => "Unauthorized"}} = API.get_me("TOK")
  end

  test "returns {:error, body} on a non-200 status", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getUpdates", fn conn -> Plug.Conn.resp(conn, 401, "nope") end)
    assert {:error, "nope"} = API.get_updates("TOK", 0, 1)
  end

  test "returns {:error, reason} when unreachable", %{bypass: bypass} do
    Bypass.down(bypass)
    assert {:error, %Mint.TransportError{}} = API.get_me("TOK")
  end

  test "get_managed_bot_token sends user_id", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getManagedBotToken", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"user_id" => 777}
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => "777SECRET"}))
    end)

    assert {:ok, "777SECRET"} = API.get_managed_bot_token("TOK", 777)
  end

  test "download_file fetches from /file/bot<token>/<path>", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/file/botTOK/voice/1.oga", fn conn -> Plug.Conn.resp(conn, 200, "bytes") end)
    assert {:ok, "bytes"} = API.download_file("TOK", "voice/1.oga")

    Bypass.expect_once(bypass, "GET", "/file/botTOK/missing", fn conn -> Plug.Conn.resp(conn, 404, "") end)
    assert {:error, "HTTP 404"} = API.download_file("TOK", "missing")
  end

  test "fetch_file_by_id resolves the path with getFile then downloads it", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getFile", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"file_id" => "f1"}
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => %{"file_path" => "photos/p.jpg"}}))
    end)

    Bypass.expect_once(bypass, "GET", "/file/botTOK/photos/p.jpg", fn conn -> Plug.Conn.resp(conn, 200, "jpg") end)
    assert {:ok, "jpg"} = API.fetch_file_by_id("TOK", "f1")
  end

  test "send_photo and send_document post multipart bodies", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/sendPhoto", fn conn ->
      [ct] = Plug.Conn.get_req_header(conn, "content-type")
      assert ct =~ "multipart/form-data; boundary="
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert raw =~ ~s(name="chat_id"\r\n\r\n5\r\n)
      assert raw =~ ~s(name="photo"; filename="image.png")
      assert raw =~ "PNGBYTES"
      assert raw =~ ~s(name="caption"\r\n\r\nhello)
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
    end)

    assert {:ok, %{"ok" => true}} = API.send_photo("TOK", 5, "PNGBYTES", %{caption: "hello"})

    path = Path.join(System.tmp_dir!(), "doc-#{System.unique_integer([:positive])}.txt")
    File.write!(path, "DOCBYTES")
    on_exit(fn -> File.rm(path) end)

    Bypass.expect_once(bypass, "POST", "/botTOK/sendDocument", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert raw =~ ~s(name="document"; filename="#{Path.basename(path)}")
      assert raw =~ "DOCBYTES"
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, "boom"} = API.send_document("TOK", 5, path)
  end
end
