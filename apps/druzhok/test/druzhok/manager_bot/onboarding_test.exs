defmodule Druzhok.ManagerBot.OnboardingTest do
  # async: false — one test sets the :public_host app env.
  use ExUnit.Case, async: false

  alias Druzhok.ManagerBot.Onboarding

  describe "new_session/0" do
    test "starts at :idle step" do
      session = Onboarding.new_session()
      assert session.step == :idle
      assert session.name == nil
      assert session.language == nil
      assert session.username == nil
      assert session.message_id == nil
    end
  end

  describe "handle_input/2 — menu buttons" do
    test "create bot button moves to :name step" do
      session = Onboarding.new_session()
      {:ok, session, {:text, _}} = Onboarding.handle_input(session, %{text: "🤖 Создать бота"})
      assert session.step == :name
    end

    test "my bots button returns :my_bots reply" do
      session = Onboarding.new_session()
      {:ok, _session, {:my_bots}} = Onboarding.handle_input(session, %{text: "📋 Мои боты"})
    end
  end

  describe "handle_input/2 at :name step" do
    test "accepts a name, generates username, moves to :language" do
      session = %{Onboarding.new_session() | step: :name}
      {:ok, session, {:keyboard, _, _}} = Onboarding.handle_input(session, %{text: "Вася"})
      assert session.step == :language
      assert session.name == "Вася"
      assert session.username =~ ~r/^vasya_[a-f0-9]{4}_bot$/
    end

    test "rejects empty name" do
      session = %{Onboarding.new_session() | step: :name}
      {:retry, _session, {:text, _}} = Onboarding.handle_input(session, %{text: ""})
    end

    test "menu buttons restart from a fresh session instead of looping" do
      session = %{Onboarding.new_session() | step: :name}
      assert {:ok, %{step: :name}, {:text, "Как назовём бота?"}} =
               Onboarding.handle_input(session, %{text: "🤖 Создать бота"})
      assert {:ok, %{step: :idle}, {:my_bots}} = Onboarding.handle_input(session, %{text: "📋 Мои боты"})
    end
  end

  describe "handle_input/2 at :language step" do
    test "accepts language, returns :edit_confirm" do
      session = %{Onboarding.new_session() | step: :language, name: "Вася", username: "vasya_1234_bot"}
      {:ok, session, {:edit_confirm, _}} = Onboarding.handle_input(session, %{callback_data: "lang:ru"})
      assert session.step == :confirm
      assert session.language == "ru"
    end
  end

  describe "generate_bot_username/1" do
    test "transliterates cyrillic and appends suffix" do
      username = Onboarding.generate_bot_username("Вася")
      assert username =~ ~r/^vasya_[a-f0-9]{4}_bot$/
    end

    test "handles latin input" do
      username = Onboarding.generate_bot_username("CoolBot")
      assert username =~ ~r/^coolbot_[a-f0-9]{4}_bot$/
    end

    test "truncates long names" do
      username = Onboarding.generate_bot_username(String.duplicate("a", 50))
      assert String.length(username) <= 32
    end

    test "prefixes a letter when the name starts with a digit" do
      username = Onboarding.generate_bot_username("3000")
      assert username =~ ~r/^b3000_[a-f0-9]{4}_bot$/
    end
  end

  describe "confirm_message/2" do
    test "uses stored username, not regenerated" do
      session = %{Onboarding.new_session() |
        step: :confirm, name: "Вася",
        language: "ru", username: "vasya_abcd_bot"}
      {_text, _keyboard, link} = Onboarding.confirm_message(session, "DruzhokBot")
      assert link =~ "vasya_abcd_bot"
    end

    test "includes name and language in text" do
      session = %{Onboarding.new_session() |
        step: :confirm, name: "Тест",
        language: "en", username: "test_1234_bot"}
      {text, _keyboard, _link} = Onboarding.confirm_message(session, "DruzhokBot")
      assert text =~ "Тест"
      assert text =~ "English"
    end
  end

  describe "progress_message/2" do
    test "step 0 shows only the first step pending" do
      assert Onboarding.progress_message("kot_bot", 0) ==
               "🥚 Создаю @kot_bot\n\n⏳ #{hd(Onboarding.provision_steps())}…"
    end

    test "later steps list the finished ones and clamp at the last step" do
      last = length(Onboarding.provision_steps()) - 1
      msg = Onboarding.progress_message("kot_bot", 2)
      assert msg =~ "✅ #{Enum.at(Onboarding.provision_steps(), 0)}"
      assert msg =~ "✅ #{Enum.at(Onboarding.provision_steps(), 1)}"
      assert msg =~ "⏳ #{Enum.at(Onboarding.provision_steps(), 2)}…"
      assert Onboarding.progress_message("kot_bot", 99) == Onboarding.progress_message("kot_bot", last)
      assert length(String.split(Onboarding.progress_message("kot_bot", last), "\n")) == last + 3
    end
  end

  describe "image_menu/2" do
    @models [
      %{id: "ruoc-flux-klein", name: "FLUX 2 Klein", rub_per_image: "2", default: true},
      %{id: "ruoc-flux-pro", name: "FLUX 2 Pro", rub_per_image: "5", default: false}
    ]

    test "off: says so and offers every model with its price" do
      bot = %{id: 7, name: "fedya", trigger_name: nil, image_gen_enabled: false, image_gen_model: nil}
      {text, rows} = Onboarding.image_menu(bot, {:ok, @models})
      assert text == "🎨 Картинки для @fedya_bot\n\nСейчас: выключено"

      assert rows == [
               [%{text: "✅ 🚫 Выкл", callback_data: "imgoff:7"}],
               [%{text: "FLUX 2 Klein · 2 ₽", callback_data: "imgset:7:ruoc-flux-klein"}],
               [%{text: "FLUX 2 Pro · 5 ₽", callback_data: "imgset:7:ruoc-flux-pro"}],
               [%{text: "« Назад", callback_data: "imgback"}]
             ]
    end

    test "on with a model: names it with the price and ticks it" do
      bot = %{id: 7, name: "fedya", trigger_name: nil, image_gen_enabled: true, image_gen_model: "ruoc-flux-pro"}
      {text, rows} = Onboarding.image_menu(bot, {:ok, @models})
      assert text =~ "Сейчас: FLUX 2 Pro · 5 ₽ за картинку"
      assert Enum.at(rows, 0) == [%{text: "🚫 Выкл", callback_data: "imgoff:7"}]
      assert Enum.at(rows, 2) == [%{text: "✅ FLUX 2 Pro · 5 ₽", callback_data: "imgset:7:ruoc-flux-pro"}]
    end

    test "on with no model: the tick sits on ruoc's default" do
      bot = %{id: 7, name: "fedya", trigger_name: nil, image_gen_enabled: true, image_gen_model: nil}
      {text, rows} = Onboarding.image_menu(bot, {:ok, @models})
      assert text =~ "Сейчас: FLUX 2 Klein · 2 ₽ за картинку"
      assert Enum.at(rows, 1) == [%{text: "✅ FLUX 2 Klein · 2 ₽", callback_data: "imgset:7:ruoc-flux-klein"}]
    end

    test "a model ruoc no longer lists is shown by id" do
      bot = %{id: 7, name: "fedya", trigger_name: nil, image_gen_enabled: true, image_gen_model: "ruoc-gone"}
      {text, _} = Onboarding.image_menu(bot, {:ok, @models})
      assert text =~ "Сейчас: ruoc-gone"
    end

    test "when the list is unavailable only Назад remains" do
      bot = %{id: 7, name: "fedya", trigger_name: nil, image_gen_enabled: false, image_gen_model: nil}
      {text, rows} = Onboarding.image_menu(bot, {:error, "down"})
      assert text =~ "Список моделей сейчас недоступен, попробуй позже"
      assert rows == [[%{text: "« Назад", callback_data: "imgback"}]]
    end
  end

  describe "image_result/3" do
    test "phrases enabling, switching and disabling" do
      model = %{id: "ruoc-flux-pro", name: "FLUX 2 Pro", rub_per_image: "5", default: false}
      assert Onboarding.image_result(:enabled, "fedya_bot", model) == "✅ Картинки включены: FLUX 2 Pro · 5 ₽ за картинку"
      assert Onboarding.image_result(:disabled, "fedya_bot", nil) == "✅ Картинки выключены для @fedya_bot"
      assert Onboarding.image_restarting(:enabled, "fedya_bot") == "⏳ Включаю картинки для @fedya_bot…"
      assert Onboarding.image_restarting(:disabled, "fedya_bot") == "⏳ Выключаю картинки для @fedya_bot…"
    end
  end

  describe "panel-ready owners" do
    test "one panel-ready bot: no 🎨 or 🗑 on the keyboard" do
      assert Onboarding.main_menu_keyboard(1, true).keyboard == [
               [%{text: "🤖 Мой бот"}],
               [%{text: "🎁 Пригласить"}]
             ]

      assert Onboarding.main_menu_keyboard(1).keyboard == Onboarding.main_menu_keyboard(1, false).keyboard
      assert Onboarding.main_menu_keyboard(2, true).keyboard == [[%{text: "📋 Мои боты"}]]
    end

    test "the list keeps only the chat button for a panel-ready bot" do
      bots = [
        %{id: 1, name: "a", panel_ready: true, active: true},
        %{id: 2, name: "b", active: true}
      ]

      {_text, [[only], [_chat, img, del]]} = Onboarding.my_bots_message(bots)
      assert only.url =~ "t.me/a_bot"
      assert {img.callback_data, del.callback_data} == {"img:2", "del:2"}
    end

    test "the card and the after-create text point at the Кабинет" do
      {text, _} = Onboarding.my_bot_message(%{name: "a", panel_ready: true, active: true})
      assert text =~ "Настройки, тариф и удаление — в «Кабинете»"
      {text, _} = Onboarding.my_bot_message(%{name: "a", active: true})
      refute text =~ "Кабинет"

      assert Onboarding.after_create_message(true) =~ "«Кабинете»"
      assert Onboarding.after_create_message() == "Управление ботом — в меню внизу."
    end

    test "panel_ready? needs the button set to the panel's own address" do
      Application.put_env(:druzhok, :public_host, "druzhok.test")
      on_exit(fn -> Application.delete_env(:druzhok, :public_host) end)

      ready = %Druzhok.Instance{
        telegram_token: "77:abc",
        cabinet_menu_set: true,
        cabinet_url: "https://druzhok.test/app/?bot=77"
      }

      if System.get_env("PHX_HOST") in [nil, ""] do
        assert Onboarding.panel_ready?(ready)
        refute Onboarding.panel_ready?(%{ready | cabinet_off: true})
        refute Onboarding.panel_ready?(%{ready | cabinet_menu_set: false})
        refute Onboarding.panel_ready?(%{ready | cabinet_url: "https://oldey.dev/tg/"})
      end

      refute Onboarding.panel_ready?(%{name: "a"})
    end

    test "the panel delete confirm carries the token on both buttons" do
      {text, [[yes, no]]} = Onboarding.panel_delete_confirm("vasya_bot", "t0k")
      assert text =~ "@vasya_bot навсегда"
      assert {yes.callback_data, no.callback_data} == {"pdel:t0k", "pdelno:t0k"}
    end
  end

  describe "my_bots_message/1" do
    test "empty list shows helpful text" do
      {text, buttons} = Onboarding.my_bots_message([])
      assert text =~ "нет ботов"
      assert buttons == []
    end

    test "shows bot list with status" do
      bots = [%{name: "vasya", active: true, trigger_name: "vasya_bot"}]
      {text, _buttons} = Onboarding.my_bots_message(bots)
      assert text =~ "🟢"
      assert text =~ "vasya"
    end

    test "button URL appends _bot to the handle" do
      bots = [%{id: 7, name: "fedya_b318", active: true, trigger_name: nil}]
      {_text, [[btn, img, del]]} = Onboarding.my_bots_message(bots)
      assert btn.text == "💬 @fedya_b318_bot"
      assert btn.url == "https://t.me/fedya_b318_bot"
      assert img.text == "🎨"
      assert img.callback_data == "img:7"
      assert del.text == "🗑"
      assert del.callback_data == "del:7"
    end

    test "button URL does not double-append _bot" do
      bots = [%{id: 8, name: "already_bot", active: true, trigger_name: nil}]
      {_text, [[btn, _img, _del]]} = Onboarding.my_bots_message(bots)
      assert btn.url == "https://t.me/already_bot"
    end

    test "shows the ruoc balance for a migrated bot" do
      bots = [%{name: "z", active: true, trigger_name: nil, ruoc_api_key: "ruoc_x", ruoc_balance_rub: "12.5"}]
      {text, _} = Onboarding.my_bots_message(bots)
      assert text =~ "*z* — баланс 12.5 ₽"

      bots = [%{name: "z", active: true, trigger_name: nil, ruoc_api_key: "ruoc_x", ruoc_balance_rub: nil}]
      {text, _} = Onboarding.my_bots_message(bots)
      assert text =~ "*z* — баланс —"
    end

    test "a subscribed bot shows its plan and the renewal date" do
      sub = %{plan_name: "Старт", credit_rub: "50.00", period_days: 30, status: "active", period_end: ~U[2026-10-05 07:00:00Z]}
      bots = [%{name: "z", active: true, trigger_name: nil, ruoc_balance_rub: "42.00", ruoc_subscription: sub}]
      {text, _} = Onboarding.my_bots_message(bots)
      assert text =~ "*z* — баланс 42.00 ₽ · план «Старт», продление 5 окт"

      bots = [%{name: "z", active: true, trigger_name: nil, ruoc_balance_rub: "42.00", ruoc_subscription: %{sub | status: "cancelled"}}]
      {text, _} = Onboarding.my_bots_message(bots)
      assert text =~ "*z* — баланс 42.00 ₽ · план «Старт» отменён, до 5 окт"
    end

    test "a bot with no balance yet shows a dash" do
      bots = [%{name: "vasya", active: true, trigger_name: nil}]
      {text, _buttons} = Onboarding.my_bots_message(bots)
      assert text =~ "*vasya* — баланс —"
    end
  end

  describe "delete_confirm/2" do
    test "builds a yes/no keyboard carrying the bot id" do
      {text, [[yes, no]]} = Onboarding.delete_confirm(42, "vasya_bot")
      assert text =~ "@vasya_bot"
      assert text =~ "навсегда"
      assert yes.callback_data == "delyes:42"
      assert no.callback_data == "delno"
    end
  end

  describe "main_menu_keyboard/1" do
    test "no bot: only create" do
      assert %{keyboard: [[%{text: "🤖 Создать бота"}]], resize_keyboard: true} = Onboarding.main_menu_keyboard(0)
      assert Onboarding.main_menu_keyboard() == Onboarding.main_menu_keyboard(0)
    end

    test "one bot: its controls, no create" do
      assert %{keyboard: [[%{text: "🤖 Мой бот"}, %{text: "🎨 Картинки"}], [%{text: "🎁 Пригласить"}, %{text: "🗑 Удалить"}]]} =
               Onboarding.main_menu_keyboard(1)
    end

    test "several bots (grandfathered): the list, no create" do
      assert %{keyboard: [[%{text: "📋 Мои боты"}]]} = Onboarding.main_menu_keyboard(2)
    end

    test "menu_texts covers every label" do
      for count <- [0, 1, 2], row <- Onboarding.main_menu_keyboard(count).keyboard, %{text: t} <- row do
        assert t in Onboarding.menu_texts()
      end
    end
  end

  describe "invite step" do
    test "ask_invite moves to :invite with the prompt" do
      {session, text} = Onboarding.ask_invite(Onboarding.new_session())
      assert session.step == :invite
      assert text == "Создание по приглашению. Введи код или открой ссылку от друга."
    end

    test "a typed code is handed back for checking" do
      {session, _} = Onboarding.ask_invite(Onboarding.new_session())
      assert {:ok, %{step: :invite}, {:check_invite, "ABCD-EFGH"}} = Onboarding.handle_input(session, %{text: "  ABCD-EFGH \n"})
    end

    test "menu buttons during the invite step are not codes" do
      {session, _} = Onboarding.ask_invite(Onboarding.new_session())
      assert {:ok, _, {:my_bots}} = Onboarding.handle_input(session, %{text: "📋 Мои боты"})
    end

    test "begin_create keeps the code on the session" do
      {session, text} = Onboarding.begin_create(Onboarding.new_session(), "ABCD-EFGH")
      assert session.step == :name
      assert session.invite == "ABCD-EFGH"
      assert text == "Как назовём бота?"
      assert {%{invite: nil}, _} = Onboarding.begin_create(Onboarding.new_session())
    end

    test "status messages" do
      assert Onboarding.invite_status_message(:spent) == "Этот код уже использован."
      assert Onboarding.invite_status_message(:expired) == "Срок этого кода истёк."
      assert Onboarding.invite_status_message(:invalid) == "Код не найден. Проверь ссылку или попроси новый."
      assert Onboarding.invite_status_message(:error) == "Не получилось проверить код, попробуй позже."
      assert Onboarding.create_race_message() == "Код успели использовать. Попроси новый и создай бота заново."
      assert Onboarding.limit_message() == "У тебя уже есть бот. Удали его, чтобы создать нового."
    end
  end

  describe "my_bot_message/1" do
    test "the bot line and a chat button" do
      bot = %{id: 7, name: "Кот", active: true, trigger_name: "kot_bot", ruoc_balance_rub: "1.00", ruoc_subscription: nil}
      {text, [[open]]} = Onboarding.my_bot_message(bot)
      assert text == "🟢 *Кот* — баланс 1.00 ₽"
      assert open == %{text: "💬 Написать", url: "https://t.me/kot_bot"}
    end
  end

  describe "referrals_messages/2" do
    test "an available code becomes a link with a share button; redeemed ones are listed" do
      codes = [
        %{code: "AAAA-BBBB", status: "available", redeemed_at: nil, friend_rub: "0.00", you_rub: "0.00"},
        %{code: "CCCC-DDDD", status: "redeemed", redeemed_at: ~U[2026-10-05 09:00:00Z], friend_rub: "0.00", you_rub: "0.00"}
      ]

      [{intro, []}, {share, [[button]]}, {used, []}] = Onboarding.referrals_messages(codes, "druzhoksuperbot")
      assert intro == "Пригласи друга — по этой ссылке он сможет создать своего бота:"
      assert share == "https://t.me/druzhoksuperbot?start=ref_AAAA-BBBB"
      assert button.text == "Поделиться"
      assert button.url =~ "https://t.me/share/url?url=https%3A%2F%2Ft.me%2Fdruzhoksuperbot%3Fstart%3Dref_AAAA-BBBB&text="
      assert used == "Использован 5 окт"
    end

    test "a bonus is mentioned in the share caption" do
      codes = [%{code: "AAAA-BBBB", status: "available", redeemed_at: nil, friend_rub: "0.00", you_rub: "20.00"}]
      [_, {_, [[button]]}] = Onboarding.referrals_messages(codes, "b")
      assert URI.decode_www_form(button.url) =~ "20.00"
    end

    test "no codes" do
      assert [{"У тебя пока нет приглашений.", []}] = Onboarding.referrals_messages([], "b")
    end

    test "only redeemed codes: no intro, just the list" do
      codes = [%{code: "C", status: "redeemed", redeemed_at: ~U[2026-10-05 09:00:00Z], friend_rub: "0.00", you_rub: "0.00"}]
      assert [{"Использован 5 окт", []}] = Onboarding.referrals_messages(codes, "b")
    end
  end
end
