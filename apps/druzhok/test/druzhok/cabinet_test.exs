defmodule Druzhok.CabinetTest do
  # async: false — app env (ruoc and Telegram stubs) and shared instance rows.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{Cabinet, Instance, Repo, RuocStub}

  @url "https://oldey.dev/tg/?bot=123"

  setup do
    stub = RuocStub.start()

    Bypass.stub(stub.bypass, "PUT", "/partner/accounts/:id/telegram", fn conn ->
      conn = RuocStub.record(stub, "PUT /partner/accounts/:id/telegram", conn)
      RuocStub.reply(conn, 200, %{"bot_id" => 123, "mini_app_url" => @url})
    end)

    tg = Bypass.open()
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")
    on_exit(fn -> Application.delete_env(:druzhok, :telegram_api_base) end)
    {:ok, seen} = Agent.start(fn -> [] end)
    on_exit(fn -> if Process.alive?(seen), do: Agent.stop(seen) end)
    {:ok, menu_ok} = Agent.start(fn -> true end)
    on_exit(fn -> if Process.alive?(menu_ok), do: Agent.stop(menu_ok) end)

    Bypass.stub(tg, "POST", "/:bot/:method", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      method = List.last(conn.path_info)
      Agent.update(seen, &[{method, Jason.decode!(body)} | &1])

      if method == "setChatMenuButton" and not Agent.get(menu_ok, & &1) do
        Plug.Conn.resp(conn, 400, ~s({"ok":false,"description":"Bad Request: chat not found"}))
      else
        Plug.Conn.resp(conn, 200, ~s({"ok":true,"result":true}))
      end
    end)

    inst =
      relay_instance(%{
        telegram_token: "123:secret",
        owner_telegram_id: 456,
        ruoc_account_id: "acct-1",
        language: "ru"
      })

    %{stub: stub, seen: seen, menu_ok: menu_ok, inst: inst}
  end

  defp telegram(seen, method),
    do: seen |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(elem(&1, 0) == method))

  defp reload(inst), do: Repo.get(Instance, inst.id)

  test "telegram_bot_id is the token's numeric prefix" do
    assert Instance.telegram_bot_id(%Instance{telegram_token: "123:abc"}) == 123
    assert Instance.telegram_bot_id(%Instance{telegram_token: "abc:def"}) == nil
    assert Instance.telegram_bot_id(%Instance{telegram_token: "0:def"}) == nil
    assert Instance.telegram_bot_id(%Instance{telegram_token: nil}) == nil
  end

  test "binds at ruoc, sets the owner's button, then costs nothing", %{
    stub: stub,
    seen: seen,
    inst: inst
  } do
    assert {:ok, :bound} = Cabinet.bind_now(inst)

    [call] = RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram")
    assert call.path == "/partner/accounts/acct-1/telegram"
    assert call.params == %{"bot_id" => 123, "owner_telegram_id" => 456}

    [{_, button}] = telegram(seen, "setChatMenuButton")
    assert button["chat_id"] == 456

    assert button["menu_button"] == %{
             "type" => "web_app",
             "text" => "Кабинет",
             "web_app" => %{"url" => @url}
           }

    inst = reload(inst)

    assert {inst.cabinet_binding, inst.cabinet_url, inst.cabinet_menu_set} ==
             {"123:456", @url, true}

    assert {:ok, :unchanged} = Cabinet.bind_now(inst)
    assert length(RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram")) == 1
    assert length(telegram(seen, "setChatMenuButton")) == 1
  end

  test "a refused button keeps the binding, and the retry sets only the button",
       %{stub: stub, seen: seen, menu_ok: menu_ok, inst: inst} do
    Agent.update(menu_ok, fn _ -> false end)
    assert {:error, :menu_button} = Cabinet.bind_now(inst)
    inst = reload(inst)

    assert {inst.cabinet_binding, inst.cabinet_url, inst.cabinet_menu_set} ==
             {"123:456", @url, false}

    Agent.update(menu_ok, fn _ -> true end)
    assert {:ok, :button} = Cabinet.bind_now(inst)
    assert length(RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram")) == 1
    assert length(telegram(seen, "setChatMenuButton")) == 2
    assert reload(inst).cabinet_menu_set
  end

  test "a token or owner change binds again", %{stub: stub, inst: inst} do
    assert {:ok, :bound} = Cabinet.bind_now(inst)
    changed = %{reload(inst) | owner_telegram_id: 789}
    assert {:ok, :bound} = Cabinet.bind_now(changed)
    [_, second] = RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram")
    assert second.params["owner_telegram_id"] == 789
  end

  test "a bot without an account, owner or token is skipped", %{stub: stub, inst: inst} do
    for change <- [%{ruoc_account_id: nil}, %{owner_telegram_id: nil}, %{telegram_token: "bad"}] do
      assert {:error, :not_eligible} = Cabinet.bind_now(struct(inst, change))
    end

    assert RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram") == []
  end

  test "ruoc refusing leaves nothing written", %{stub: stub, inst: inst} do
    Bypass.stub(stub.bypass, "PUT", "/partner/accounts/:id/telegram", fn conn ->
      RuocStub.reply(conn, 409, %{
        "error" => %{"type" => "bot_bound_elsewhere", "message" => "no"}
      })
    end)

    assert {:error, "HTTP 409: no"} = Cabinet.bind_now(inst)
    assert reload(inst).cabinet_binding == nil
  end

  test "the out-of-money notice offers the cabinet once per six hours", %{seen: seen, inst: inst} do
    start_supervised!(Cabinet)
    Cabinet.out_of_money(inst.id)
    # Not bound yet: nothing to offer.
    :sys.get_state(Cabinet)
    assert telegram(seen, "sendMessage") == []

    {:ok, :bound} = Cabinet.bind_now(inst)
    Cabinet.out_of_money(inst.id)
    Cabinet.out_of_money(inst.id)
    :sys.get_state(Cabinet)

    [{_, msg}] = telegram(seen, "sendMessage")
    assert msg["chat_id"] == 456
    assert msg["text"] =~ "Баланс бота исчерпан"

    assert [[%{"text" => "Открыть кабинет", "web_app" => %{"url" => @url}}]] =
             msg["reply_markup"]["inline_keyboard"]
  end

  test "a failing call never takes the process down", %{stub: stub, inst: inst} do
    start_supervised!(Cabinet)
    pid = Process.whereis(Cabinet)
    Bypass.down(stub.bypass)
    Cabinet.sync(inst.id)
    :sys.get_state(Cabinet)
    assert Process.whereis(Cabinet) == pid
    assert reload(inst).cabinet_binding == nil
  end

  test "the owner's first private message is the moment for the button", %{inst: inst} do
    private = %{"message" => %{"from" => %{"id" => 456}, "chat" => %{"type" => "private"}}}
    assert Cabinet.button_moment?(inst, private)
    refute Cabinet.button_moment?(%{inst | cabinet_menu_set: true}, private)
    refute Cabinet.button_moment?(inst, put_in(private, ["message", "from", "id"], 999))
    refute Cabinet.button_moment?(inst, put_in(private, ["message", "chat", "type"], "group"))
    refute Cabinet.button_moment?(inst, %{"callback_query" => %{}})
  end

  test "--off puts the default button back and forgets the binding", %{seen: seen, inst: inst} do
    {:ok, :bound} = Cabinet.bind_now(inst)
    assert {:ok, :unset} = Cabinet.unset_now(reload(inst))

    assert {"setChatMenuButton", %{"menu_button" => %{"type" => "default"}}} =
             List.last(telegram(seen, "setChatMenuButton"))

    assert reload(inst).cabinet_binding == nil
  end
end
