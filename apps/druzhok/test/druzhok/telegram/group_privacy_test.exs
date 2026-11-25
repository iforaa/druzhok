defmodule Druzhok.Telegram.GroupPrivacyTest do
  # async: false — swaps the Telegram base URL in app env.
  use ExUnit.Case, async: false

  alias Druzhok.Telegram.GroupPrivacy

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

  defp ok(conn, result),
    do: Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => result}))

  # setMySettings records what was asked; getMe answers `reported`.
  defp telegram(bypass, reported) do
    test = self()

    Bypass.expect(bypass, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      case conn.request_path do
        "/botTOK/setMySettings" ->
          send(test, {:set, Jason.decode!(raw)})
          ok(conn, true)

        "/botTOK/getMe" ->
          ok(conn, Map.merge(%{"id" => 7, "is_bot" => true, "username" => "romik_bot"}, reported))
      end
    end)
  end

  test "turns privacy off and reports what getMe now says", %{bypass: bypass} do
    telegram(bypass, %{"can_read_all_group_messages" => true})
    assert {:ok, true, %{"username" => "romik_bot"}} = GroupPrivacy.set("TOK", true)
    assert_received {:set, %{"can_read_all_group_messages" => true}}
  end

  test "turns privacy back on", %{bypass: bypass} do
    telegram(bypass, %{"can_read_all_group_messages" => false})
    assert {:ok, false, _me} = GroupPrivacy.set("TOK", false)
    assert_received {:set, %{"can_read_all_group_messages" => false}}
  end

  test "an accepted call that getMe does not confirm is an error", %{bypass: bypass} do
    telegram(bypass, %{"can_read_all_group_messages" => false})
    assert GroupPrivacy.set("TOK", true) == {:error, {:not_applied, false}}

    telegram(bypass, %{})
    assert GroupPrivacy.set("TOK", true) == {:error, :not_reported}
  end

  test "a refusal from Telegram is an error", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/setMySettings", fn conn ->
      Plug.Conn.resp(conn, 404, Jason.encode!(%{"ok" => false, "description" => "Not Found: method not found"}))
    end)

    assert {:error, _} = GroupPrivacy.set("TOK", true)
  end

  test "no token" do
    assert GroupPrivacy.set(nil, true) == {:error, :no_token}
    assert GroupPrivacy.set("", true) == {:error, :no_token}
  end
end
