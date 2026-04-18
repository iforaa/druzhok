defmodule Druzhok.ManagerBot.OnboardingTest do
  use ExUnit.Case, async: true

  alias Druzhok.ManagerBot.Onboarding

  describe "new_session/0" do
    test "starts at :name step" do
      session = Onboarding.new_session()
      assert session.step == :name
      assert session.name == nil
      assert session.personality == nil
      assert session.language == nil
    end
  end

  describe "handle_input/2 at :name step" do
    test "accepts a name and moves to :personality" do
      session = Onboarding.new_session()
      {:ok, session, _reply} = Onboarding.handle_input(session, %{text: "Вася"})
      assert session.step == :personality
      assert session.name == "Вася"
    end

    test "rejects empty name" do
      session = Onboarding.new_session()
      {:retry, _session, _reply} = Onboarding.handle_input(session, %{text: ""})
    end
  end

  describe "handle_input/2 at :personality step" do
    test "accepts a valid personality callback" do
      session = %{Onboarding.new_session() | step: :personality, name: "Вася"}
      {:ok, session, _reply} = Onboarding.handle_input(session, %{callback_data: "personality:kawaii"})
      assert session.step == :language
      assert session.personality == "kawaii"
    end

    test "rejects unknown personality" do
      session = %{Onboarding.new_session() | step: :personality, name: "Вася"}
      {:retry, _session, _reply} = Onboarding.handle_input(session, %{callback_data: "personality:nonexistent"})
    end
  end

  describe "handle_input/2 at :language step" do
    test "accepts language and moves to :confirm" do
      session = %{Onboarding.new_session() | step: :language, name: "Вася", personality: "kawaii"}
      {:ok, session, _reply} = Onboarding.handle_input(session, %{callback_data: "lang:ru"})
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

    test "strips special characters" do
      username = Onboarding.generate_bot_username("My Bot! 123")
      assert username =~ ~r/^my_bot_123_[a-f0-9]{4}_bot$/
    end

    test "truncates long names" do
      username = Onboarding.generate_bot_username(String.duplicate("a", 50))
      assert String.length(username) <= 32
    end
  end

  describe "confirm_message/2" do
    test "builds the creation link" do
      session = %{Onboarding.new_session() | step: :confirm, name: "Вася", personality: "kawaii", language: "ru"}
      {text, keyboard, link} = Onboarding.confirm_message(session, "DruzhokBot")
      assert text =~ "Создать"
      assert link =~ "t.me/newbot/DruzhokBot/"
      assert link =~ "name="
      assert keyboard != nil
    end
  end

  describe "personalities/0" do
    test "returns a non-empty list of {key, label} tuples" do
      list = Onboarding.personalities()
      assert length(list) > 10
      assert {"kawaii", "Кавай"} in list
      assert {"pirate", "Пират"} in list
    end
  end
end
