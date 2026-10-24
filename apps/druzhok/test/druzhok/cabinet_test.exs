defmodule Druzhok.CabinetTest do
  # async: false — app env (ruoc and Telegram stubs) and shared instance rows.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
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
             {"123:456:ru", @url, true}

    assert {:ok, :unchanged} = Cabinet.bind_now(inst)
    assert length(RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram")) == 1
    assert length(telegram(seen, "setChatMenuButton")) == 1
  end

  test "a refused button keeps the binding, and the retry sets only the button",
       %{stub: stub, seen: seen, menu_ok: menu_ok, inst: inst} do
    Agent.update(menu_ok, fn _ -> false end)
    assert {:error, {:menu_button, :not_opened}} = Cabinet.bind_now(inst)
    inst = reload(inst)

    assert {inst.cabinet_binding, inst.cabinet_url, inst.cabinet_menu_set} ==
             {"123:456:ru", @url, false}

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

  test "a call that raises never takes the process down", %{inst: inst} do
    start_supervised!(Cabinet)
    pid = Process.whereis(Cabinet)
    # A bound bot whose button Telegram answers with a body that is not JSON:
    # Telegram.API's decode raises inside the handler.
    tg = Bypass.open()
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")

    Bypass.stub(tg, "POST", "/:bot/:method", fn conn ->
      Plug.Conn.resp(conn, 200, "<html>oops</html>")
    end)

    set_row(inst, cabinet_binding: "123:456:ru", cabinet_url: @url, cabinet_menu_set: false)

    Cabinet.sync(inst.id)
    :sys.get_state(Cabinet)
    assert Process.whereis(Cabinet) == pid
    refute reload(inst).cabinet_menu_set
  end

  test "another refusal of the button is reported with Telegram's reason", %{inst: inst} do
    tg = Bypass.open()
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{tg.port}")

    Bypass.stub(tg, "POST", "/:bot/:method", fn conn ->
      Plug.Conn.resp(conn, 401, ~s({"ok":false,"description":"Unauthorized"}))
    end)

    assert {:error, {:menu_button, reason}} = Cabinet.bind_now(inst)
    assert reason =~ "Unauthorized"
  end

  test "an owner change hands the button over and resets the old owner's", %{
    seen: seen,
    inst: inst
  } do
    {:ok, :bound} = Cabinet.bind_now(inst)
    set_row(inst, owner_telegram_id: 789)
    assert {:ok, :bound} = Cabinet.bind_now(reload(inst))

    buttons = telegram(seen, "setChatMenuButton") |> Enum.map(&elem(&1, 1))
    assert %{"chat_id" => 456, "menu_button" => %{"type" => "default"}} in buttons

    assert Enum.any?(
             buttons,
             &match?(%{"chat_id" => 789, "menu_button" => %{"type" => "web_app"}}, &1)
           )
  end

  test "a language change relabels the button", %{seen: seen, inst: inst} do
    {:ok, :bound} = Cabinet.bind_now(inst)
    set_row(inst, language: "en")
    assert {:ok, :bound} = Cabinet.bind_now(reload(inst))
    {_, last} = List.last(telegram(seen, "setChatMenuButton"))
    assert last["menu_button"]["text"] == "Cabinet"
  end

  test "the owner's first private message is the moment for the button", %{inst: inst} do
    private = %{"message" => %{"from" => %{"id" => 456}, "chat" => %{"type" => "private"}}}
    assert Cabinet.button_moment?(inst, private)

    refute Cabinet.button_moment?(
             %{inst | cabinet_menu_set: true, cabinet_binding: "123:456:ru"},
             private
           )

    refute Cabinet.button_moment?(inst, put_in(private, ["message", "from", "id"], 999))
    refute Cabinet.button_moment?(inst, put_in(private, ["message", "chat", "type"], "group"))
    refute Cabinet.button_moment?(inst, %{"callback_query" => %{}})

    # A rebind that failed after an owner change leaves the button "set" for
    # the old binding: the owner's message still retries it.
    stale = %{inst | cabinet_menu_set: true, cabinet_binding: "123:111:ru"}
    assert Cabinet.button_moment?(stale, private)
    refute Cabinet.button_moment?(%{stale | cabinet_binding: "123:456:ru"}, private)
    refute Cabinet.button_moment?(%{inst | cabinet_off: true}, private)
  end

  test "--off lasts until a plain bind-cabinet", %{seen: seen, inst: inst} do
    {:ok, :bound} = Cabinet.bind_now(inst)
    assert {:ok, :unset} = Cabinet.unset_now(reload(inst))

    assert {"setChatMenuButton", %{"menu_button" => %{"type" => "default"}}} =
             List.last(telegram(seen, "setChatMenuButton"))

    off = reload(inst)
    assert off.cabinet_off and off.cabinet_binding == nil
    # Nothing puts it back: not a start or wake, not the owner's message.
    assert {:ok, :off} = Cabinet.bind_now(off)

    refute Cabinet.button_moment?(off, %{
             "message" => %{"from" => %{"id" => 456}, "chat" => %{"type" => "private"}}
           })

    assert {:ok, :bound} = Cabinet.resume_now(off)
    on = reload(inst)
    refute on.cabinet_off
    assert on.cabinet_menu_set
  end

  describe "with a public host the button opens druzhok's panel" do
    setup do
      Application.put_env(:druzhok, :public_host, "druzhok.test")
      on_exit(fn -> Application.delete_env(:druzhok, :public_host) end)
      :ok
    end

    @panel "https://druzhok.test/app/?bot=123"

    test "a fresh bind writes the panel's address, not ruoc's", %{seen: seen, inst: inst} do
      assert {:ok, :bound} = Cabinet.bind_now(inst)
      assert reload(inst).cabinet_url == @panel
      [{_, button}] = telegram(seen, "setChatMenuButton")
      assert button["menu_button"]["web_app"]["url"] == @panel
    end

    test "a bot bound on ruoc's address moves with no ruoc call", %{stub: stub, seen: seen, inst: inst} do
      set_row(inst, cabinet_binding: "123:456:ru", cabinet_url: @url, cabinet_menu_set: true)
      moved = reload(inst)

      private = %{"message" => %{"from" => %{"id" => 456}, "chat" => %{"type" => "private"}}}
      assert Cabinet.button_moment?(moved, private)

      assert {:ok, :button} = Cabinet.bind_now(moved)
      assert RuocStub.calls(stub, "PUT /partner/accounts/:id/telegram") == []
      [{_, button}] = telegram(seen, "setChatMenuButton")
      assert button["menu_button"]["web_app"]["url"] == @panel

      done = reload(inst)
      assert {done.cabinet_url, done.cabinet_menu_set} == {@panel, true}
      assert {:ok, :unchanged} = Cabinet.bind_now(done)
      refute Cabinet.button_moment?(done, private)
    end

    test "a refused button keeps the old address, so the next trigger retries", %{
      menu_ok: menu_ok,
      inst: inst
    } do
      set_row(inst, cabinet_binding: "123:456:ru", cabinet_url: @url, cabinet_menu_set: true)
      Agent.update(menu_ok, fn _ -> false end)
      assert {:error, {:menu_button, :not_opened}} = Cabinet.bind_now(reload(inst))
      kept = reload(inst)
      assert {kept.cabinet_url, kept.cabinet_menu_set} == {@url, true}

      Agent.update(menu_ok, fn _ -> true end)
      assert {:ok, :button} = Cabinet.bind_now(kept)
      assert reload(inst).cabinet_url == @panel
    end

    test "the out-of-money notice opens the Счёт tab", %{seen: seen, inst: inst} do
      start_supervised!(Cabinet)
      {:ok, :bound} = Cabinet.bind_now(inst)
      Cabinet.out_of_money(inst.id)
      :sys.get_state(Cabinet)
      [{_, msg}] = telegram(seen, "sendMessage")

      assert [[%{"web_app" => %{"url" => @panel <> "&tab=billing"}}]] =
               msg["reply_markup"]["inline_keyboard"]
    end
  end

  defp set_row(inst, fields) do
    Repo.update_all(from(i in Instance, where: i.id == ^inst.id), set: fields)
  end
end
