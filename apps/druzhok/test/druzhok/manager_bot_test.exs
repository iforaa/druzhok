defmodule Druzhok.ManagerBotTest do
  # async: false — app env, DRUZHOK_DATA_ROOT, global Settings row.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{Instance, Repo, TelegramStub}

  # No ':' — see TelegramStub.
  @token "111MANAGER"
  @owner 4242

  setup do
    ctx = with_tmp_data_root()
    stub = TelegramStub.start(@token)
    Druzhok.Settings.set("manager_bot_token", @token)
    on_exit(fn -> Druzhok.Settings.set("manager_bot_token", "") end)

    pid = TelegramStub.start_manager_bot()

    # Started as @test_manager_bot: getMe was called and polling began.
    TelegramStub.await_call(stub, "getMe", fn _ -> true end)

    Map.merge(ctx, %{stub: stub, pid: pid})
  end

  defp message(text, uid \\ @owner) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{"message_id" => 1, "from" => %{"id" => uid}, "chat" => %{"id" => uid}, "text" => text}
    }
  end

  defp callback(data, uid \\ @owner, message_id \\ 55) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "callback_query" => %{
        "id" => "cb#{System.unique_integer([:positive])}",
        "from" => %{"id" => uid},
        "data" => data,
        "message" => %{"message_id" => message_id, "chat" => %{"id" => uid}}
      }
    }
  end

  defp managed_bot_update(bot_id, username, uid \\ @owner) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "managed_bot" => %{"user" => %{"id" => uid}, "bot" => %{"id" => bot_id, "username" => username}}
    }
  end

  defp sent_texts(stub), do: Enum.map(TelegramStub.calls(stub, "sendMessage"), & &1["text"])

  defp start_create_flow(stub, name) do
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    TelegramStub.push_update(stub, message(name))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:"))
  end

  test "stays idle and polls nothing when no token is configured", %{stub: stub} do
    Druzhok.Settings.set("manager_bot_token", "")
    pid = TelegramStub.start_manager_bot()
    Process.sleep(100)
    assert Process.alive?(pid)
    # Only the instance from setup called getMe.
    assert length(TelegramStub.calls(stub, "getMe")) == 1
  end

  test "retries later when getMe fails", %{stub: stub} do
    test_pid = self()

    Bypass.stub(stub.bypass, "POST", "/bot#{@token}/getMe", fn conn ->
      send(test_pid, :get_me)
      Plug.Conn.resp(conn, 401, ~s({"ok":false,"description":"Unauthorized"}))
    end)

    pid = TelegramStub.start_manager_bot()
    assert_receive :get_me, 2_000
    Process.sleep(50)
    assert Process.alive?(pid)
    # Never reached the poll loop.
    refute Enum.any?(TelegramStub.calls(stub, "getUpdates"), &(&1["offset"] == 1001))
  end

  test "survives a getUpdates error and keeps the process alive", %{stub: stub, pid: pid} do
    Bypass.stub(stub.bypass, "POST", "/bot#{@token}/getUpdates", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    TelegramStub.await_call(stub, "getUpdates", fn _ -> true end)
    Process.sleep(100)
    assert Process.alive?(pid)
  end

  test "advances the offset past the last processed update", %{stub: stub} do
    TelegramStub.push_update(stub, %{"update_id" => 1000, "message" => %{"from" => %{"id" => 1}, "chat" => %{"id" => 1}, "text" => "/start"}})
    TelegramStub.await_call(stub, "getUpdates", &(&1["offset"] == 1001))
  end

  test "/start replies with the welcome text and the two-button reply keyboard", %{stub: stub} do
    TelegramStub.push_update(stub, message("/start"))

    params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
    assert params["chat_id"] == @owner
    keyboard = Jason.decode!(params["reply_markup"])
    assert keyboard["keyboard"] == [[%{"text" => "🤖 Создать бота"}, %{"text" => "📋 Мои боты"}]]
    assert keyboard["resize_keyboard"] == true
  end

  test "unknown text outside a flow shows the main menu", %{stub: stub} do
    TelegramStub.push_update(stub, message("blah"))
    assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
  end

  test "Мои боты with no bots says so without buttons", %{stub: stub} do
    TelegramStub.push_update(stub, message("📋 Мои боты"))
    params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "пока нет ботов"))
    refute Map.has_key?(params, "reply_markup")
  end

  test "create flow: name → language keyboard → confirm with a t.me/newbot link", %{stub: stub} do
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))

    TelegramStub.push_update(stub, message("Вася"))
    lang = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:"))

    assert Jason.decode!(lang["reply_markup"])["inline_keyboard"] == [
             [
               %{"text" => "🇷🇺 Русский", "callback_data" => "lang:ru"},
               %{"text" => "🇬🇧 English", "callback_data" => "lang:en"}
             ]
           ]

    TelegramStub.push_update(stub, callback("lang:ru"))
    TelegramStub.await_call(stub, "answerCallbackQuery", fn _ -> true end)
    confirm = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Вася"))
    assert confirm["message_id"] == 55
    assert confirm["parse_mode"] == "Markdown"
    assert confirm["text"] =~ "Язык: Русский"
    [[button]] = Jason.decode!(confirm["reply_markup"])["inline_keyboard"]
    assert button["url"] =~ ~r"^https://t\.me/newbot/test_manager_bot/vasya_[0-9a-f]{4}_bot\?name="

    # Stray text at the confirm step re-sends the confirm card.
    TelegramStub.push_update(stub, message("hm?"))
    assert eventually(fn -> Enum.count(TelegramStub.calls(stub, "editMessageText"), &(&1["text"] =~ "Вася")) == 2 end)
  end

  test "empty name re-prompts; stray text at the language step re-shows the keyboard", %{stub: stub} do
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    TelegramStub.push_update(stub, message("   "))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "не может быть пустым"))

    TelegramStub.push_update(stub, message("Kot"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:"))
    TelegramStub.push_update(stub, message("hello?"))
    # The language keyboard's message_id is known, so the retry edits it in place.
    assert TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "Язык:"))
    assert Enum.count(sent_texts(stub), &(&1 == "Язык:")) == 1
  end

  test "menu buttons during name entry restart the flow", %{stub: stub} do
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    assert eventually(fn -> Enum.count(sent_texts(stub), &(&1 == "Как назовём бота?")) == 2 end)
  end

  test "managed_bot update provisions a bot for the creator", %{stub: stub, data_root: root} do
    TelegramStub.set_managed_bot_token(stub, "555NEWBOT")
    cleanup_instance("kot_1a2b")

    start_create_flow(stub, "Кот")
    TelegramStub.push_update(stub, callback("lang:en"))
    TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Кот"))

    TelegramStub.push_update(stub, managed_bot_update(555, "kot_1a2b_bot"))

    assert TelegramStub.await_call(stub, "getManagedBotToken", &(&1["user_id"] == 555), 10_000)
    done = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "создан и запущен"), 15_000)
    assert done["chat_id"] == @owner
    assert done["text"] =~ "https://t.me/kot_1a2b_bot"

    inst = Repo.get_by!(Instance, name: "kot_1a2b")
    assert inst.telegram_token == "555NEWBOT"
    assert inst.owner_telegram_id == @owner
    assert inst.language == "en"
    assert inst.model == "z-ai/glm-5.3-flash"
    assert inst.mention_only
    refute inst.allow_all_telegram_users
    assert File.read!(Path.join([root, "kot_1a2b", "SOUL.md"])) =~ "Тебя зовут Кот"
    assert eventually(fn -> Druzhok.BotManager.status("kot_1a2b") == "active" end)

    # The session is consumed: the next message shows the main menu again.
    TelegramStub.push_update(stub, message("anything"))
    assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
  end

  test "managed_bot without a prior session still provisions, defaulting to Russian", %{stub: stub, data_root: root} do
    TelegramStub.set_managed_bot_token(stub, "556NEWBOT")
    cleanup_instance("zhora_ff00")

    TelegramStub.push_update(stub, managed_bot_update(556, "zhora_ff00_bot"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "создан и запущен"), 15_000)

    inst = Repo.get_by!(Instance, name: "zhora_ff00")
    assert inst.language == "ru"
    assert File.read!(Path.join([root, "zhora_ff00", "SOUL.md"])) =~ "Тебя зовут zhora_ff00"
  end

  test "provisioning failure is reported to the creator", %{stub: stub} do
    Bypass.stub(stub.bypass, "POST", "/bot#{@token}/getManagedBotToken", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "description" => "BOT_NOT_MANAGED"}))
    end)

    TelegramStub.push_update(stub, managed_bot_update(557, "ghost_bot"))

    err = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Ошибка создания бота"), 10_000)
    assert err["text"] =~ "BOT_NOT_MANAGED"
    assert Repo.get_by(Instance, name: "ghost") == nil
  end

  describe "with two existing bots" do
    setup %{data_root: root} do
      for n <- ["own1", "own2"] do
        %Instance{}
        |> Instance.changeset(%{
          name: n,
          model: "m",
          workspace: Path.join([root, n, "workspace"]),
          tenant_key: "dk-#{n}",
          owner_telegram_id: @owner,
          trigger_name: "#{n}_bot",
          daily_budget_cents: 100
        })
        |> Repo.insert!()
      end

      on_exit(fn -> Repo.delete_all(from(i in Instance, where: i.name in ["own1", "own2"])) end)
      :ok
    end

    test "creating a third is refused", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "уже 2 бота"))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "Мои боты lists them with budget and a delete button each", %{stub: stub} do
      Druzhok.Budget.deduct(Repo.get_by!(Instance, name: "own2").id, 25)

      TelegramStub.push_update(stub, message("📋 Мои боты"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Твои боты"))
      assert params["parse_mode"] == "Markdown"
      assert params["text"] =~ "🟢 *own1* — $0.00 / $1.00 (0%)"
      assert params["text"] =~ "🟢 *own2* — $0.25 / $1.00 (25%)"
      rows = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert length(rows) == 2
      [[open, del]] = Enum.take(rows, 1)
      assert open["url"] == "https://t.me/own1_bot"
      assert del["callback_data"] == "del:#{Repo.get_by!(Instance, name: "own1").id}"
    end

    test "delete asks for confirmation, then deletes only the owner's bot", %{stub: stub} do
      id = Repo.get_by!(Instance, name: "own1").id
      cleanup_instance("own1")

      TelegramStub.push_update(stub, callback("del:#{id}"))
      ask = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Точно удалить @own1_bot"))
      [[yes, no]] = Jason.decode!(ask["reply_markup"])["inline_keyboard"]
      assert yes["callback_data"] == "delyes:#{id}"
      assert no["callback_data"] == "delno"

      TelegramStub.push_update(stub, callback("delno"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "Отменено."))
      assert Repo.get(Instance, id)

      TelegramStub.push_update(stub, callback("delyes:#{id}"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "✅ Бот @own1_bot удалён."), 10_000)
      assert Repo.get(Instance, id) == nil
    end

    test "a stranger cannot delete someone else's bot", %{stub: stub} do
      id = Repo.get_by!(Instance, name: "own2").id
      TelegramStub.push_update(stub, callback("del:#{id}", 999))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Это не твой бот."))

      TelegramStub.push_update(stub, callback("delyes:#{id}", 999))
      assert eventually(fn -> Enum.count(sent_texts(stub), &(&1 == "Это не твой бот.")) == 2 end)
      assert Repo.get(Instance, id)
    end

    test "deleting an unknown id says not found", %{stub: stub} do
      TelegramStub.push_update(stub, callback("del:999999"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Бот не найден."))

      TelegramStub.push_update(stub, callback("delyes:999999"))
      assert TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "Бот не найден."))
    end
  end

  test "a callback whose message is inaccessible is acknowledged and ignored", %{stub: stub} do
    TelegramStub.push_update(stub, %{
      "update_id" => 7,
      "callback_query" => %{"id" => "cbx", "from" => %{"id" => @owner}, "data" => "lang:ru"}
    })

    assert TelegramStub.await_call(stub, "answerCallbackQuery", &(&1["callback_query_id"] == "cbx"))
    Process.sleep(50)
    assert TelegramStub.calls(stub, "sendMessage") == []
  end

  test "a callback outside any flow is answered with the menu hint", %{stub: stub} do
    TelegramStub.push_update(stub, callback("lang:ru"))
    assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Используй кнопки меню внизу."))
  end

  test "updates of unknown kinds are skipped", %{stub: stub} do
    TelegramStub.push_update(stub, %{"update_id" => 8, "edited_message" => %{}})
    TelegramStub.await_call(stub, "getUpdates", &(&1["offset"] == 9))
    assert TelegramStub.calls(stub, "sendMessage") == []
  end
end
