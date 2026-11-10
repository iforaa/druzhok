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
        language: "ru"
      })

      assert opts[:telegram_token] == "123:ABC"
      assert opts[:model] == "xiaomi/mimo-v2-pro"
      assert opts[:owner_telegram_id] == 601956
      assert opts[:language] == "ru"
      assert opts[:mention_only] == true
    end

    test "defaults model to ruoc-deepseek-flash when none is given" do
      opts = Provisioner.build_create_opts(%{token: "123:ABC", owner_id: 1})
      assert opts[:model] == "ruoc-deepseek-flash"
    end

    test "seeds one trimmed group trigger within the panel limit" do
      for {display, expected} <- [
            {" Друг! ", "Друг!"},
            {String.duplicate("Я", 32), String.duplicate("Я", 32)},
            {String.duplicate("Я", 33), nil},
            {"  ", nil},
            {nil, nil}
          ] do
        opts = Provisioner.build_create_opts(%{display_name: display})
        assert opts.display_name == display
        assert opts.trigger_name == expected
      end
    end

    test "carries the character picked, nil when skipped" do
      assert Provisioner.build_create_opts(%{token: "1", owner_id: 1, soul_preset: "humor"})[:soul_preset] == "humor"
      assert Provisioner.build_create_opts(%{token: "1", owner_id: 1})[:soul_preset] == nil
    end

    test "carries the invite code when the session had one" do
      assert Provisioner.build_create_opts(%{token: "1", owner_id: 1, invite: "ABCD-EFGH"})[:invite] == "ABCD-EFGH"
      refute Map.has_key?(Provisioner.build_create_opts(%{token: "1", owner_id: 1}), :invite)
    end
  end
end
