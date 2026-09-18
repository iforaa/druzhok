defmodule Druzhok.ManagerBotTest do
  # async: false — app env, DRUZHOK_DATA_ROOT, global Settings row.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query, only: [from: 2]
  alias Druzhok.{Instance, Repo, TelegramStub}

  # No ':' — see TelegramStub.
  @token "111MANAGER"
  @owner 4242
  @stranger 4343

  setup do
    ctx = with_tmp_data_root()
    stub = TelegramStub.start(@token)
    Druzhok.Settings.set("manager_bot_token", @token)
    on_exit(fn -> Druzhok.Settings.set("manager_bot_token", "") end)

    # The gate is on for everyone; the owner is an old hand in most tests.
    Druzhok.Admissions.admit(@owner, "test")
    on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id in [@owner, @stranger])) end)

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

  test "/start replies with the welcome text and the create-only reply keyboard", %{stub: stub} do
    TelegramStub.push_update(stub, message("/start"))

    params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
    assert params["chat_id"] == @owner
    keyboard = Jason.decode!(params["reply_markup"])
    assert keyboard["keyboard"] == [[%{"text" => "🤖 Создать бота"}]]
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

    # The creator sees a progress message at once, which is edited into the result.
    progress = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Создаю @kot_1a2b_bot"))
    assert progress["chat_id"] == @owner
    assert progress["text"] =~ "⏳"

    assert TelegramStub.await_call(stub, "getManagedBotToken", &(&1["user_id"] == 555), 10_000)
    done = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "создан и запущен"), 15_000)
    assert done["chat_id"] == @owner
    assert done["text"] =~ "https://t.me/kot_1a2b_bot"
    refute Enum.any?(sent_texts(stub), &(&1 =~ "создан и запущен"))

    menu = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Управление ботом — в меню внизу."), 5_000)

    assert Jason.decode!(menu["reply_markup"])["keyboard"] == [
             [%{"text" => "🤖 Мой бот"}, %{"text" => "🎨 Картинки"}],
             [%{"text" => "🎁 Пригласить"}, %{"text" => "🗑 Удалить"}]
           ]

    inst = Repo.get_by!(Instance, name: "kot_1a2b")
    assert inst.telegram_token == "555NEWBOT"
    assert inst.owner_telegram_id == @owner
    assert inst.language == "en"
    assert inst.model == "ruoc-flash"
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
    Application.put_env(:druzhok, :provision_progress_tick_ms, 5)
    on_exit(fn -> Application.delete_env(:druzhok, :provision_progress_tick_ms) end)

    TelegramStub.push_update(stub, managed_bot_update(556, "zhora_ff00_bot"))
    TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "создан и запущен"), 15_000)

    # The ticker advanced the checklist and stopped before the result was written.
    edits = TelegramStub.calls(stub, "editMessageText") |> Enum.map(& &1["text"])
    assert Enum.any?(edits, &(&1 =~ "✅ Выращиваю нейроны"))
    Process.sleep(200)
    assert TelegramStub.calls(stub, "editMessageText") |> List.last() |> Map.fetch!("text") =~ "создан и запущен"

    inst = Repo.get_by!(Instance, name: "zhora_ff00")
    assert inst.language == "ru"
    assert File.read!(Path.join([root, "zhora_ff00", "SOUL.md"])) =~ "Тебя зовут zhora_ff00"
  end

  test "provisioning failure is reported to the creator", %{stub: stub} do
    Bypass.stub(stub.bypass, "POST", "/bot#{@token}/getManagedBotToken", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "description" => "BOT_NOT_MANAGED"}))
    end)

    TelegramStub.push_update(stub, managed_bot_update(557, "ghost_bot"))

    err = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Ошибка создания бота"), 10_000)
    assert err["text"] =~ "BOT_NOT_MANAGED"
    assert Repo.get_by(Instance, name: "ghost") == nil
  end

  describe "with two existing bots (grandfathered)" do
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
          ruoc_api_key: "ruoc_#{n}"
        })
        |> Repo.insert!()
      end

      on_exit(fn -> Repo.delete_all(from(i in Instance, where: i.name in ["own1", "own2"])) end)
      :ok
    end

    test "creating a third is refused", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "уже есть бот"))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "the keyboard is the list, and the list still works", %{stub: stub} do
      TelegramStub.push_update(stub, message("/start"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
      assert Jason.decode!(params["reply_markup"])["keyboard"] == [[%{"text" => "📋 Мои боты"}]]
    end

    test "Мои боты lists them with balance and a delete button each", %{stub: stub} do
      ruoc = Druzhok.RuocStub.start()

      Bypass.stub(ruoc.bypass, "GET", "/v1/balance", fn conn ->
        case Plug.Conn.get_req_header(conn, "authorization") do
          ["Bearer ruoc_own2"] ->
            Druzhok.RuocStub.reply(conn, 200, %{
              "balance_nanorub" => 250_000_000, "balance_rub" => "0.25 RUB",
              "subscription" => %{"plan_name" => "Старт", "credit_nanorub" => 50_000_000_000, "period_days" => 30,
                                  "status" => "active", "current_period_end" => "2026-10-05T12:00:00+05:00"}
            })
          _ -> Druzhok.RuocStub.reply(conn, 200, %{"balance_nanorub" => 1_000_000_000, "balance_rub" => "1 RUB"})
        end
      end)

      TelegramStub.push_update(stub, message("📋 Мои боты"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Твои боты"))
      assert params["parse_mode"] == "Markdown"
      assert params["text"] =~ "🟢 *own1* — баланс 1.00 ₽"
      assert params["text"] =~ "🟢 *own2* — баланс 0.25 ₽ · план «Старт», продление 5 окт"
      rows = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert length(rows) == 2
      [[open, img, del]] = Enum.take(rows, 1)
      assert img["callback_data"] == "img:#{Repo.get_by!(Instance, name: "own1").id}"
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

  describe "with one bot" do
    setup %{data_root: root} do
      ruoc = Druzhok.RuocStub.start()

      inst =
        %Instance{}
        |> Instance.changeset(%{
          name: "solo",
          model: "m",
          workspace: Path.join([root, "solo", "workspace"]),
          tenant_key: "dk-solo",
          owner_telegram_id: @owner,
          trigger_name: "solo_bot",
          ruoc_api_key: "ruoc_solo"
        })
        |> Repo.insert!()

      on_exit(fn -> Repo.delete_all(from(i in Instance, where: i.name == "solo")) end)
      %{ruoc: ruoc, inst: inst}
    end

    test "/start shows the bot's controls and no create button", %{stub: stub} do
      TelegramStub.push_update(stub, message("/start"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))

      assert Jason.decode!(params["reply_markup"])["keyboard"] == [
               [%{"text" => "🤖 Мой бот"}, %{"text" => "🎨 Картинки"}],
               [%{"text" => "🎁 Пригласить"}, %{"text" => "🗑 Удалить"}]
             ]
    end

    test "create is refused with the one-bot message", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "У тебя уже есть бот. Удали его, чтобы создать нового."))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "Мой бот is the card with balance and a chat button", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Мой бот"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "*solo*"))
      assert params["text"] == "🟢 *solo* — баланс 12.50 ₽"
      [[open]] = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert open["url"] == "https://t.me/solo_bot"
    end

    test "Картинки opens the picture menu for the bot directly", %{stub: stub, inst: inst} do
      TelegramStub.push_update(stub, message("🎨 Картинки"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Картинки для @solo_bot"))
      rows = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert Enum.any?(List.flatten(rows), &(&1["callback_data"] == "imgoff:#{inst.id}"))

      # «Назад» from there is the card, not a list.
      TelegramStub.push_update(stub, callback("imgback"))
      assert TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "*solo*"))
    end

    test "Удалить asks, deletes, and hands back the create keyboard", %{stub: stub, inst: inst} do
      cleanup_instance("solo")
      TelegramStub.push_update(stub, message("🗑 Удалить"))
      ask = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Точно удалить @solo_bot"))
      [[yes, _no]] = Jason.decode!(ask["reply_markup"])["inline_keyboard"]
      assert yes["callback_data"] == "delyes:#{inst.id}"

      TelegramStub.push_update(stub, callback("delyes:#{inst.id}"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "✅ Бот @solo_bot удалён."), 10_000)
      menu = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Можно создать нового бота."), 5_000)
      assert Jason.decode!(menu["reply_markup"])["keyboard"] == [[%{"text" => "🤖 Создать бота"}]]
      assert Repo.get(Instance, inst.id) == nil

      # Admitted before, so a new bot needs no code.
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    end

    test "Пригласить lists the codes from ruoc with share buttons", %{stub: stub} do
      TelegramStub.push_update(stub, message("🎁 Пригласить"))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Пригласи друга"))
      share = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "https://t.me/test_manager_bot?start=ref_AAAA-BBBB"))
      [[button]] = Jason.decode!(share["reply_markup"])["inline_keyboard"]
      assert button["text"] == "Поделиться"
      assert button["url"] =~ "https://t.me/share/url?url="
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Использован 5 окт"))
    end

    test "Пригласить when ruoc fails", %{stub: stub, ruoc: ruoc} do
      Bypass.down(ruoc.bypass)
      TelegramStub.push_update(stub, message("🎁 Пригласить"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Не получилось загрузить приглашения, попробуй позже."))
    end
  end

  describe "invite gate" do
    setup do
      %{ruoc: Druzhok.RuocStub.start()}
    end

    test "a stranger pressing create is asked for a code, and a good code starts naming", %{stub: stub, ruoc: ruoc} do
      TelegramStub.push_update(stub, message("🤖 Создать бота", @stranger))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Создание по приглашению. Введи код или открой ссылку от друга."))

      TelegramStub.push_update(stub, message("ABCD-EFGH", @stranger))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == @stranger))
      [call] = Druzhok.RuocStub.calls(ruoc, "GET /admin/invites/check")
      assert call.path == "/admin/invites/check"
    end

    test "pressing create again mid-naming asks for the code, never drops it", %{stub: stub, ruoc: ruoc} do
      TelegramStub.push_update(stub, message("🤖 Создать бота", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "по приглашению"))
      TelegramStub.push_update(stub, message("ABCD-EFGH", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))

      # The session holds a checked code, but the button is still a create press:
      # it re-prompts rather than starting a nameless, codeless creation.
      TelegramStub.push_update(stub, message("🤖 Создать бота", @stranger))

      assert eventually(fn ->
               Enum.count(sent_texts(stub), &(&1 == "Создание по приглашению. Введи код или открой ссылку от друга.")) == 2
             end)

      assert Enum.count(sent_texts(stub), &(&1 == "Как назовём бота?")) == 1
      assert length(Druzhok.RuocStub.calls(ruoc, "GET /admin/invites/check")) == 1
    end

    test "a spent code is refused and the menu returns", %{stub: stub, ruoc: ruoc} do
      Bypass.stub(ruoc.bypass, "GET", "/admin/invites/check", fn conn ->
        Druzhok.RuocStub.reply(conn, 200, %{"status" => "spent"})
      end)

      TelegramStub.push_update(stub, message("🤖 Создать бота", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "по приглашению"))
      TelegramStub.push_update(stub, message("ABCD-EFGH", @stranger))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Этот код уже использован."))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "a deep link with a good code goes straight to naming", %{stub: stub} do
      TelegramStub.push_update(stub, message("/start ref_ABCD-EFGH", @stranger))
      welcome = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет" and &1["chat_id"] == @stranger))
      assert Jason.decode!(welcome["reply_markup"])["keyboard"] == [[%{"text" => "🤖 Создать бота"}]]
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == @stranger))
    end

    test "a deep link from an admitted person is just /start", %{stub: stub, ruoc: ruoc} do
      TelegramStub.push_update(stub, message("/start ref_ABCD-EFGH"))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
      Process.sleep(50)
      refute "Как назовём бота?" in sent_texts(stub)
      assert Druzhok.RuocStub.calls(ruoc, "GET /admin/invites/check") == []
    end

    test "the code reaches ruoc at creation, and a race is reported", %{stub: stub, ruoc: ruoc} do
      TelegramStub.set_managed_bot_token(stub, "558NEWBOT")
      cleanup_instance("gost_0001")

      TelegramStub.push_update(stub, message("/start ref_ABCD-EFGH", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == @stranger))
      TelegramStub.push_update(stub, message("Гость", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:" and &1["chat_id"] == @stranger))
      TelegramStub.push_update(stub, callback("lang:ru", @stranger))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Гость"))

      Bypass.expect_once(ruoc.bypass, "POST", "/admin/accounts", fn conn ->
        Druzhok.RuocStub.reply(conn, 409, %{"error" => %{"type" => "invite_spent", "message" => "used"}})
      end)

      TelegramStub.push_update(stub, managed_bot_update(558, "gost_0001_bot", @stranger))
      assert TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "Код успели использовать. Попроси новый и создай бота заново."), 10_000)
      assert Repo.get_by(Instance, name: "gost_0001") == nil
      refute Druzhok.Admissions.admitted?(@stranger)
    end

    test "the operator creates without a code", %{stub: stub} do
      Druzhok.Settings.set("operator_telegram_id", "777")
      on_exit(fn -> Druzhok.Settings.set("operator_telegram_id", "") end)
      TelegramStub.push_update(stub, message("🤖 Создать бота", 777))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == 777))
    end
  end

  describe "picture menu" do
    setup %{data_root: root} do
      ruoc = Druzhok.RuocStub.start()

      for {n, attrs} <- [
            {"pic_off", %{}},
            {"pic_on", %{image_gen_enabled: true, image_gen_model: "ruoc-flux-klein"}}
          ] do
        %Instance{}
        |> Instance.changeset(
          Map.merge(
            %{
              name: n,
              model: "m",
              workspace: Path.join([root, n, "workspace"]),
              tenant_key: "dk-#{n}",
              owner_telegram_id: @owner,
              trigger_name: "#{n}_bot",
              ruoc_api_key: "ruoc_#{n}",
              active: false
            },
            attrs
          )
        )
        |> Repo.insert!()

        cleanup_instance(n)
      end

      %{ruoc: ruoc, off: Repo.get_by!(Instance, name: "pic_off"), on: Repo.get_by!(Instance, name: "pic_on")}
    end

    defp edits(stub), do: Enum.map(TelegramStub.calls(stub, "editMessageText"), & &1["text"])

    test "🎨 opens the menu built from ruoc's image catalogue", %{stub: stub, off: off} do
      TelegramStub.push_update(stub, callback("img:#{off.id}"))
      menu = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Картинки для @pic_off_bot"))
      assert menu["text"] == "🎨 Картинки для @pic_off_bot\n\nСейчас: выключено"
      rows = Jason.decode!(menu["reply_markup"])["inline_keyboard"]

      assert Enum.map(rows, &Enum.map(&1, fn b -> {b["text"], b["callback_data"]} end)) == [
               [{"✅ 🚫 Выкл", "imgoff:#{off.id}"}],
               [{"FLUX 2 Klein · 2 ₽", "imgset:#{off.id}:ruoc-flux-klein"}],
               [{"FLUX 2 Pro · 5 ₽", "imgset:#{off.id}:ruoc-flux-pro"}],
               [{"« Назад", "imgback"}]
             ]
    end

    test "picking a model while off turns pictures on and restarts the bot", %{stub: stub, off: off} do
      TelegramStub.push_update(stub, callback("imgset:#{off.id}:ruoc-flux-pro"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "⏳ Включаю картинки для @pic_off_bot…"))

      TelegramStub.await_call(
        stub,
        "editMessageText",
        &(&1["text"] == "✅ Картинки включены: FLUX 2 Pro · 5 ₽ за картинку"),
        10_000
      )

      inst = Repo.get!(Instance, off.id)
      assert inst.image_gen_enabled
      assert inst.image_gen_model == "ruoc-flux-pro"
      assert inst.active
    end

    test "switching the model while on only updates the row and redraws the menu", %{stub: stub, on: on} do
      TelegramStub.push_update(stub, callback("imgset:#{on.id}:ruoc-flux-pro"))
      menu = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Сейчас: FLUX 2 Pro · 5 ₽ за картинку"))
      rows = Jason.decode!(menu["reply_markup"])["inline_keyboard"]
      assert [%{"text" => "✅ FLUX 2 Pro · 5 ₽"}] = Enum.at(rows, 2)

      inst = Repo.get!(Instance, on.id)
      assert inst.image_gen_model == "ruoc-flux-pro"
      refute inst.active
      refute Enum.any?(edits(stub), &String.starts_with?(&1, "⏳"))
    end

    test "Выкл turns pictures off with a restart", %{stub: stub, on: on} do
      TelegramStub.push_update(stub, callback("imgoff:#{on.id}"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "⏳ Выключаю картинки для @pic_on_bot…"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "✅ Картинки выключены для @pic_on_bot"), 10_000)
      refute Repo.get!(Instance, on.id).image_gen_enabled
    end

    test "Выкл on a bot that is already off just redraws the menu", %{stub: stub, off: off} do
      TelegramStub.push_update(stub, callback("imgoff:#{off.id}"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Сейчас: выключено"))
      refute Enum.any?(edits(stub), &String.starts_with?(&1, "⏳"))
    end

    test "Назад redraws Мои боты in place", %{stub: stub} do
      TelegramStub.push_update(stub, callback("imgback"))
      back = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Твои боты"))
      assert back["text"] =~ "*pic_off*"
      assert Jason.decode!(back["reply_markup"])["inline_keyboard"] |> hd() |> Enum.at(1) |> Map.get("text") == "🎨"
    end

    test "a stranger is refused at every step", %{stub: stub, on: on} do
      TelegramStub.push_update(stub, callback("img:#{on.id}", 999))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Это не твой бот."))
      TelegramStub.push_update(stub, callback("imgset:#{on.id}:ruoc-flux-pro", 999))
      assert eventually(fn -> Enum.count(sent_texts(stub), &(&1 == "Это не твой бот.")) == 2 end)
      TelegramStub.push_update(stub, callback("imgoff:#{on.id}", 999))
      assert eventually(fn -> Enum.count(sent_texts(stub), &(&1 == "Это не твой бот.")) == 3 end)
      assert Repo.get!(Instance, on.id).image_gen_model == "ruoc-flux-klein"
    end

    test "when ruoc is down the menu says so", %{stub: stub, ruoc: ruoc, off: off} do
      Bypass.down(ruoc.bypass)
      TelegramStub.push_update(stub, callback("img:#{off.id}"))
      menu = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Список моделей сейчас недоступен"))
      assert [[%{"text" => "« Назад"}]] = Jason.decode!(menu["reply_markup"])["inline_keyboard"]
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
