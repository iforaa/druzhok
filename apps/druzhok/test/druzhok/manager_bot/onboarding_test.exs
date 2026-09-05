defmodule Druzhok.ManagerBot.OnboardingTest do
  use ExUnit.Case, async: true

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
      {_text, [[btn, del]]} = Onboarding.my_bots_message(bots)
      assert btn.text == "💬 @fedya_b318_bot"
      assert btn.url == "https://t.me/fedya_b318_bot"
      assert del.text == "🗑"
      assert del.callback_data == "del:7"
    end

    test "button URL does not double-append _bot" do
      bots = [%{id: 8, name: "already_bot", active: true, trigger_name: nil}]
      {_text, [[btn, _del]]} = Onboarding.my_bots_message(bots)
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

  describe "main_menu_keyboard/0" do
    test "returns a reply keyboard with two buttons" do
      menu = Onboarding.main_menu_keyboard()
      assert menu.resize_keyboard == true
      [[btn1, btn2]] = menu.keyboard
      assert btn1.text == "🤖 Создать бота"
      assert btn2.text == "📋 Мои боты"
    end
  end
end
