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

  test "append_many creates file with header if not exists" do
    msgs = [%Message{role: "user", content: "hi", timestamp: 1}]
    SessionStore.append_many(@workspace, 200, msgs)
    loaded = SessionStore.load(@workspace, 200)
    assert length(loaded) == 1

    # Verify header is in the raw file
    raw = File.read!(Path.join([@workspace, "sessions", "200.jsonl"]))
    first_line = raw |> String.split("\n", trim: true) |> hd()
    assert first_line =~ "\"type\":\"session\""
    assert first_line =~ "\"version\":1"
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

  test "session header is written and skipped on load" do
    SessionStore.save(@workspace, 600, [%Message{role: "user", content: "test", timestamp: 1}])

    # Raw file should have header as first line
    raw = File.read!(Path.join([@workspace, "sessions", "600.jsonl"]))
    lines = String.split(raw, "\n", trim: true)
    assert length(lines) == 2  # header + 1 message
    assert hd(lines) =~ "\"type\":\"session\""

    # Load should return only messages, not header
    loaded = SessionStore.load(@workspace, 600)
    assert length(loaded) == 1
    assert Enum.at(loaded, 0)["content"] == "test"
  end

  test "truncate_after_compaction replaces file atomically" do
    # Write initial session
    messages = for i <- 1..20 do
      %Message{role: "user", content: "msg #{i}", timestamp: i}
    end
    SessionStore.save(@workspace, 700, messages)
    assert length(SessionStore.load(@workspace, 700)) == 20

    # Simulate compaction: summary + 5 recent
    compacted = [
      %Message{role: "user", content: "[Summary]", timestamp: 0, metadata: %{type: :compaction_summary}},
      %Message{role: "user", content: "msg 16", timestamp: 16},
      %Message{role: "assistant", content: "reply 16", timestamp: 17},
      %Message{role: "user", content: "msg 18", timestamp: 18},
      %Message{role: "assistant", content: "reply 18", timestamp: 19}
    ]
    SessionStore.truncate_after_compaction(@workspace, 700, compacted)

    loaded = SessionStore.load(@workspace, 700)
    assert length(loaded) == 5
    assert Enum.at(loaded, 0)["content"] == "[Summary]"

    # Verify no .tmp file left behind
    refute File.exists?(Path.join([@workspace, "sessions", "700.jsonl.tmp"]))
  end

  test "save uses atomic write (no .tmp left)" do
    SessionStore.save(@workspace, 800, [%Message{role: "user", content: "hi", timestamp: 1}])
    refute File.exists?(Path.join([@workspace, "sessions", "800.jsonl.tmp"]))
  end

  test "load handles legacy files without header" do
    # Write a file directly without header (legacy format)
    path = Path.join([@workspace, "sessions", "900.jsonl"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, ~s({"role":"user","content":"legacy"}\n))

    loaded = SessionStore.load(@workspace, 900)
    assert length(loaded) == 1
    assert Enum.at(loaded, 0)["content"] == "legacy"
  end
end
