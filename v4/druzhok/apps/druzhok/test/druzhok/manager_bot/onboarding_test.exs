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
      bots = [%{name: "fedya_b318", active: true, trigger_name: nil}]
      {_text, [[btn]]} = Onboarding.my_bots_message(bots)
      assert btn.text == "💬 @fedya_b318_bot"
      assert btn.url == "https://t.me/fedya_b318_bot"
    end

    test "button URL does not double-append _bot" do
      bots = [%{name: "already_bot", active: true, trigger_name: nil}]
      {_text, [[btn]]} = Onboarding.my_bots_message(bots)
      assert btn.url == "https://t.me/already_bot"
    end

    test "shows budget and spend for a bot with a limit" do
      bots = [%{name: "fedya", active: true, trigger_name: nil, daily_budget_cents: 50, spent_today_cents: 23}]
      {text, _buttons} = Onboarding.my_bots_message(bots)
      assert text =~ "*fedya*"
      assert text =~ "$0.23 / $0.50 (46%)"
    end

    test "shows 'без лимита' for a bot with no budget" do
      bots = [%{name: "vasya", active: true, trigger_name: nil, daily_budget_cents: 0, spent_today_cents: 17}]
      {text, _buttons} = Onboarding.my_bots_message(bots)
      assert text =~ "без лимита, $0.17"
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
