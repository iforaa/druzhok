defmodule Druzhok.GroupChatTest do
  use ExUnit.Case, async: false

  alias Druzhok.{Pairing, AllowedChat, Repo, Instance}

  # --- Pairing Tests ---

  test "create_code generates 8-char code" do
    {:ok, pairing} = Pairing.create_code("test-inst", 12345, "testuser", "Test User")
    assert String.length(pairing.code) == 8
    assert pairing.telegram_user_id == 12345
    assert pairing.display_name == "Test User"
    # Cleanup
    Repo.delete(pairing)
  end

  test "get_pending returns pending code" do
    {:ok, pairing} = Pairing.create_code("test-pair-1", 12345, nil, "Test")
    result = Pairing.get_pending("test-pair-1")
    assert result.code == pairing.code
    Repo.delete(pairing)
  end

  test "get_pending returns nil for expired codes" do
    {:ok, pairing} = Pairing.create_code("test-pair-2", 12345, nil, "Test")
    # Manually expire the code
    expired_at = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
    pairing |> Ecto.Changeset.change(%{expires_at: expired_at}) |> Repo.update!()
    assert Pairing.get_pending("test-pair-2") == nil
    Repo.delete(pairing)
  end

  test "approve sets owner_telegram_id on instance" do
    # Create a test instance in DB
    {:ok, inst} = %Instance{}
    |> Instance.changeset(%{name: "test-approve", telegram_token: "fake", model: "test", workspace: "/tmp/test"})
    |> Repo.insert()

    {:ok, _pairing} = Pairing.create_code("test-approve", 99999, "user", "User")
    {:ok, approved} = Pairing.approve("test-approve")
    assert approved.telegram_user_id == 99999

    # Verify instance has owner set
    updated = Repo.get!(Instance, inst.id)
    assert updated.owner_telegram_id == 99999

    # Verify pairing code is deleted
    assert Pairing.get_pending("test-approve") == nil

    Repo.delete(updated)
  end

  # --- AllowedChat Tests ---

  test "upsert_pending creates new record" do
    {:ok, chat} = AllowedChat.upsert_pending("test-chat-1", -100123, "group", "Test Group")
    assert chat.status == "pending"
    assert chat.chat_id == -100123
    Repo.delete(chat)
  end

  test "approve changes status" do
    {:ok, _} = AllowedChat.upsert_pending("test-chat-2", -100456, "group", "Group 2")
    {:ok, chat} = AllowedChat.approve("test-chat-2", -100456)
    assert chat.status == "approved"
    Repo.delete(chat)
  end

  test "reject changes status" do
    {:ok, _} = AllowedChat.upsert_pending("test-chat-3", -100789, "group", "Group 3")
    {:ok, chat} = AllowedChat.reject("test-chat-3", -100789)
    assert chat.status == "rejected"
    Repo.delete(chat)
  end

  test "mark_removed and re-add goes back to pending" do
    {:ok, chat} = AllowedChat.upsert_pending("test-chat-4", -100111, "group", "Group 4")
    AllowedChat.approve("test-chat-4", -100111)
    AllowedChat.mark_removed("test-chat-4", -100111)

    removed = AllowedChat.get("test-chat-4", -100111)
    assert removed.status == "removed"

    # Re-add should go back to pending
    {:ok, readded} = AllowedChat.upsert_pending("test-chat-4", -100111, "group", "Group 4 New")
    assert readded.status == "pending"

    Repo.delete(readded)
  end

  test "mark_info_sent sets flag" do
    {:ok, chat} = AllowedChat.upsert_pending("test-chat-5", -100222, "group", "Group 5")
    assert chat.info_sent == false
    AllowedChat.mark_info_sent("test-chat-5", -100222)
    updated = AllowedChat.get("test-chat-5", -100222)
    assert updated.info_sent == true
    Repo.delete(updated)
  end

  test "groups_for_instance returns only groups" do
    {:ok, g1} = AllowedChat.upsert_pending("test-list", -200001, "group", "G1")
    {:ok, g2} = AllowedChat.upsert_pending("test-list", -200002, "supergroup", "G2")

    groups = AllowedChat.groups_for_instance("test-list")
    assert length(groups) == 2

    Repo.delete(g1)
    Repo.delete(g2)
  end
end
