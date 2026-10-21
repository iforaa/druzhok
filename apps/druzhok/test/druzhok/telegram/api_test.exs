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
end
