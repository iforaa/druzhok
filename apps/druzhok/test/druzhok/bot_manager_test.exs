defmodule Druzhok.BotManagerTest do
  # async: false — mutates the DRUZHOK_DATA_ROOT env var.
  use ExUnit.Case, async: false

  alias Druzhok.BotManager

  describe "safe_to_wipe?/1" do
    setup do
      prev = System.get_env("DRUZHOK_DATA_ROOT")
      System.put_env("DRUZHOK_DATA_ROOT", "/tmp/druzhok-test-root")
      on_exit(fn ->
        if prev, do: System.put_env("DRUZHOK_DATA_ROOT", prev),
                else: System.delete_env("DRUZHOK_DATA_ROOT")
      end)
      :ok
    end

    test "allows a path strictly under the data root" do
      assert BotManager.safe_to_wipe?("/tmp/druzhok-test-root/somebot")
      assert BotManager.safe_to_wipe?("/tmp/druzhok-test-root/somebot/")
    end

    test "refuses the data root itself" do
      refute BotManager.safe_to_wipe?("/tmp/druzhok-test-root")
    end

    test "refuses paths outside the data root" do
      refute BotManager.safe_to_wipe?("/etc")
      refute BotManager.safe_to_wipe?("/tmp/other")
    end

    test "refuses nil, empty, and root" do
      refute BotManager.safe_to_wipe?(nil)
      refute BotManager.safe_to_wipe?("")
      refute BotManager.safe_to_wipe?("/")
    end

    test "refuses a sibling that merely shares the prefix string" do
      # "/tmp/druzhok-test-root-evil" must NOT be treated as inside the root.
      refute BotManager.safe_to_wipe?("/tmp/druzhok-test-root-evil/x")
    end
  end
end
