defmodule Druzhok.GroupChatsTest do
  # async: false: shared instance rows, as in the other relay tests.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{GroupChats, Repo}
  alias Druzhok.Runtime.Hermes
  alias Druzhok.Telegram.Inbox

  @chat -1001

  setup do
    %{inst: relay_instance(%{owner_telegram_id: 456, active: true, telegram_mode: "webhook"})}
  end

  defp group(inst, status, chat \\ @chat) do
    Repo.insert!(%GroupChats{instance_id: inst.id, chat_id: chat, title: "Дача", status: status})
  end

  describe "chat_of/1" do
    for {kind, body} <- [
          {"message", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"edited_message", %{"chat" => %{"id" => -1, "type" => "supergroup"}}},
          {"channel_post", %{"chat" => %{"id" => -1, "type" => "channel"}}},
          {"my_chat_member", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"chat_member", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"chat_join_request", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"message_reaction", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"message_reaction_count", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"chat_boost", %{"chat" => %{"id" => -1, "type" => "group"}}},
          {"callback_query", %{"message" => %{"chat" => %{"id" => -1, "type" => "group"}}}},
          {"poll_answer", %{"voter_chat" => %{"id" => -1, "type" => "group"}}},
          {"some_future_update", %{"chat" => %{"id" => -1, "type" => "group"}}}
        ] do
      test "finds the group in #{kind}" do
        update = %{"update_id" => 1, unquote(kind) => unquote(Macro.escape(body))}
        assert {:group, %{"id" => -1}} = GroupChats.chat_of(update)
      end
    end

    test "only a chat marked private is private" do
      private = %{"message" => %{"chat" => %{"id" => 7, "type" => "private"}}}
      assert GroupChats.chat_of(private) == :private

      assert {:group, _} = GroupChats.chat_of(%{"message" => %{"chat" => %{"id" => 7}}})
    end

    test "updates with no chat" do
      assert GroupChats.chat_of(%{"update_id" => 1, "inline_query" => %{"id" => "x"}}) == :none
      assert GroupChats.chat_of(%{"update_id" => 1, "poll" => %{"id" => "x"}}) == :none
    end
  end

  describe "env_value/1" do
    test "only approved chats, comma-separated with no spaces", %{inst: inst} do
      group(inst, "approved", -2)
      group(inst, "approved", -1_001_234)
      group(inst, "pending", -3)
      group(inst, "blocked", -4)
      assert GroupChats.env_value(inst) == "-1001234,-2"
    end

    test "empty for a polling bot, whatever is approved", %{inst: inst} do
      group(inst, "approved")
      assert GroupChats.env_value(%{inst | telegram_mode: "polling"}) == ""
      assert Hermes.env_vars(%{inst | telegram_mode: "polling"})["DRUZHOK_GROUP_CHATS"] == ""
    end

    test "reaches the bot's env", %{inst: inst} do
      assert Hermes.env_vars(inst)["DRUZHOK_GROUP_CHATS"] == ""
      group(inst, "approved")
      assert Hermes.env_vars(inst)["DRUZHOK_GROUP_CHATS"] == "#{@chat}"
    end
  end

  describe "decide/3: approve" do
    test "restarts an awake bot at once and records who decided", %{inst: inst} do
      group(inst, "pending")
      assert {:ok, after_} = GroupChats.decide(inst, @chat, "approve")

      assert after_.start_seq == inst.start_seq + 1
      assert after_.settings_seq == inst.settings_seq + 1

      row = Repo.get_by!(GroupChats, instance_id: inst.id, chat_id: @chat)
      assert row.status == "approved"
      assert row.decided_by == 456
    end

    test "does not wake a sleeping bot", %{inst: inst} do
      Repo.update!(Ecto.Changeset.change(inst, sleeping: true))
      group(inst, "pending")

      assert {:ok, after_} = GroupChats.decide(inst, @chat, "approve")
      assert after_.start_seq == inst.start_seq
      assert after_.sleeping
    end

    test "does not start a stopped bot", %{inst: inst} do
      Repo.update!(Ecto.Changeset.change(inst, active: false))
      group(inst, "pending")

      assert {:ok, after_} = GroupChats.decide(inst, @chat, "approve")
      assert after_.start_seq == inst.start_seq
      refute after_.active
    end

    test "again changes nothing", %{inst: inst} do
      group(inst, "approved")
      assert {:ok, after_} = GroupChats.decide(inst, @chat, "approve")
      assert after_.start_seq == inst.start_seq
      assert after_.settings_seq == inst.settings_seq
    end

    test "a polling bot cannot", %{inst: inst} do
      group(inst, "pending")
      polling = Repo.update!(Ecto.Changeset.change(inst, telegram_mode: "polling"))
      assert {:error, :polling} = GroupChats.decide(polling, @chat, "approve")
      assert Repo.get_by!(GroupChats, instance_id: inst.id, chat_id: @chat).status == "pending"
    end
  end

  describe "decide/3: block and remove" do
    test "blocking an approved group asks for a quiet restart, not a restart", %{inst: inst} do
      group(inst, "approved")
      assert {:ok, after_} = GroupChats.decide(inst, @chat, "block")

      assert after_.start_seq == inst.start_seq
      assert after_.settings_seq == inst.settings_seq + 1
      assert Repo.get_by!(GroupChats, instance_id: inst.id, chat_id: @chat).status == "blocked"
    end

    test "removing an approved group asks for a quiet restart and forgets it", %{inst: inst} do
      group(inst, "approved")
      assert {:ok, after_} = GroupChats.decide(inst, @chat, "remove")

      assert after_.start_seq == inst.start_seq
      assert after_.settings_seq == inst.settings_seq + 1
      refute Repo.get_by(GroupChats, instance_id: inst.id, chat_id: @chat)
    end

    test "a group that was never approved changes no env, so no restart at all", %{inst: inst} do
      group(inst, "pending")
      assert {:ok, after_} = GroupChats.decide(inst, @chat, "block")
      assert after_.settings_seq == inst.settings_seq

      assert {:ok, after_} = GroupChats.decide(inst, @chat, "remove")
      assert after_.settings_seq == inst.settings_seq
    end

    test "what that group had queued goes too; other chats stay", %{inst: inst} do
      group(inst, "approved")

      msg = fn id ->
        Jason.encode!(%{"message" => %{"chat" => %{"id" => id, "type" => "group"}}})
      end

      :ok = Inbox.enqueue(inst.id, 1, msg.(@chat))
      :ok = Inbox.enqueue(inst.id, 2, msg.(-2))

      assert {:ok, _} = GroupChats.decide(inst, @chat, "block")

      assert Inbox.pending_count(inst.id) == 1
      assert Inbox.next_pending(inst.id).update_id == 2
    end
  end

  test "an unknown chat or action is refused", %{inst: inst} do
    assert {:error, :not_found} = GroupChats.decide(inst, -404, "approve")
    group(inst, "pending")
    assert {:error, :invalid_action} = GroupChats.decide(inst, @chat, "explode")
    assert {:error, :invalid_action} = GroupChats.decide(inst, @chat, nil)
  end

  test "list/1 shows those waiting first, and nothing of another bot", %{inst: inst} do
    group(inst, "blocked", -1)
    group(inst, "approved", -2)
    group(inst, "pending", -3)
    group(relay_instance(%{}), "pending", -4)

    assert Enum.map(GroupChats.list(inst), & &1.chat_id) == [-3, -2, -1]
    assert %{chat_id: -3, title: "Дача", status: "pending"} = hd(GroupChats.list(inst))
  end

  test "deleting a bot takes its groups with it", %{inst: inst} do
    group(inst, "approved")
    Repo.delete!(inst)
    refute Repo.get_by(GroupChats, instance_id: inst.id, chat_id: @chat)
  end

  test "settings: defaults, an override, and a typo falls back" do
    alias Druzhok.Settings
    assert Settings.group_rate_user_per_min() == 5
    assert Settings.group_rate_chat_per_hour() == 30

    Settings.set("group_rate_user_per_min", "7")
    on_exit(fn -> Settings.set("group_rate_user_per_min", "") end)
    assert Settings.group_rate_user_per_min() == 7

    for bad <- ["0", "-1", "many"] do
      Settings.set("group_rate_user_per_min", bad)
      assert Settings.group_rate_user_per_min() == 5
    end

    assert "group_rate_chat_per_hour" in Settings.keys()
  end
end
