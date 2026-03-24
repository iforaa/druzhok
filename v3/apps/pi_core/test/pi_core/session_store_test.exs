defmodule PiCore.SessionStoreTest do
  use ExUnit.Case

  alias PiCore.SessionStore
  alias PiCore.Loop.Message

  @workspace System.tmp_dir!() |> Path.join("session_store_test_#{:rand.uniform(99999)}")

  setup do
    File.rm_rf!(@workspace)
    File.mkdir_p!(@workspace)
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "save and load round-trip" do
    messages = [
      %Message{role: "user", content: "hello", timestamp: 1},
      %Message{role: "assistant", content: "hi", timestamp: 2}
    ]
    SessionStore.save(@workspace, 12345, messages)
    loaded = SessionStore.load(@workspace, 12345)
    assert length(loaded) == 2
    assert Enum.at(loaded, 0)["role"] == "user"
    assert Enum.at(loaded, 0)["content"] == "hello"
  end

  test "load returns empty list when no file" do
    assert SessionStore.load(@workspace, 99999) == []
  end

  test "append_many adds messages" do
    msg1 = %Message{role: "user", content: "first", timestamp: 1}
    SessionStore.save(@workspace, 100, [msg1])
    new_msgs = [
      %Message{role: "assistant", content: "reply", timestamp: 2},
      %Message{role: "user", content: "second", timestamp: 3}
    ]
    SessionStore.append_many(@workspace, 100, new_msgs)
    loaded = SessionStore.load(@workspace, 100)
    assert length(loaded) == 3
  end

  test "append_many creates file if not exists" do
    msgs = [%Message{role: "user", content: "hi", timestamp: 1}]
    SessionStore.append_many(@workspace, 200, msgs)
    assert length(SessionStore.load(@workspace, 200)) == 1
  end

  test "save enforces 500 message cap" do
    messages = for i <- 1..600 do
      %Message{role: "user", content: "msg #{i}", timestamp: i}
    end
    SessionStore.save(@workspace, 300, messages)
    loaded = SessionStore.load(@workspace, 300)
    assert length(loaded) == 500
    assert Enum.at(loaded, 0)["content"] == "msg 101"
  end

  test "clear deletes per-chat file" do
    SessionStore.save(@workspace, 400, [%Message{role: "user", content: "bye", timestamp: 1}])
    SessionStore.clear(@workspace, 400)
    assert SessionStore.load(@workspace, 400) == []
  end

  test "different chat_ids are isolated" do
    SessionStore.save(@workspace, 1, [%Message{role: "user", content: "chat1", timestamp: 1}])
    SessionStore.save(@workspace, 2, [%Message{role: "user", content: "chat2", timestamp: 1}])
    assert Enum.at(SessionStore.load(@workspace, 1), 0)["content"] == "chat1"
    assert Enum.at(SessionStore.load(@workspace, 2), 0)["content"] == "chat2"
  end

  test "creates sessions/ directory on first write" do
    refute File.dir?(Path.join(@workspace, "sessions"))
    SessionStore.save(@workspace, 500, [%Message{role: "user", content: "hi", timestamp: 1}])
    assert File.dir?(Path.join(@workspace, "sessions"))
  end
end
