defmodule Druzhok.ManagerBot.ProvisionerTest do
  use ExUnit.Case, async: true

  alias Druzhok.ManagerBot.Provisioner

  describe "derive_instance_name/1" do
    test "strips trailing _bot from username" do
      assert Provisioner.derive_instance_name("vasya_a7f3_bot") == "vasya_a7f3"
    end

    test "handles username without _bot suffix" do
      assert Provisioner.derive_instance_name("vasya") == "vasya"
    end

    test "handles complex usernames" do
      assert Provisioner.derive_instance_name("my_cool_ai_bot") == "my_cool_ai"
    end
  end

  describe "build_create_opts/1" do
    test "assembles the options map for BotManager.create" do
      opts = Provisioner.build_create_opts(%{
        token: "123:ABC",
        model: "xiaomi/mimo-v2-pro",
        owner_id: 601956,
        language: "ru",
        bot_runtime: "hermes"
      })

      assert opts[:telegram_token] == "123:ABC"
      assert opts[:model] == "xiaomi/mimo-v2-pro"
      assert opts[:owner_telegram_id] == 601956
      assert opts[:language] == "ru"
      assert opts[:bot_runtime] == "hermes"
      assert opts[:mention_only] == true
    end

    test "defaults model to z-ai/glm-5.3-flash when none is given" do
      opts = Provisioner.build_create_opts(%{token: "123:ABC", owner_id: 1})
      assert opts[:model] == "z-ai/glm-5.3-flash"
    end
  end
end
