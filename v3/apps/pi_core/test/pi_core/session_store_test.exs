defmodule PiCore.SessionStoreTest do
  use ExUnit.Case
  alias PiCore.SessionStore

  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_store_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "save and load messages", %{dir: dir} do
    messages = [
      %{role: "user", content: "hello", timestamp: 1},
      %{role: "assistant", content: "hi", timestamp: 2},
    ]
    SessionStore.save(dir, messages)
    loaded = SessionStore.load(dir)
    assert length(loaded) == 2
    assert hd(loaded)["content"] == "hello"
  end

  test "load returns empty for missing file", %{dir: dir} do
    assert SessionStore.load(dir) == []
  end

  test "append adds to existing", %{dir: dir} do
    SessionStore.save(dir, [%{role: "user", content: "first", timestamp: 1}])
    SessionStore.append(dir, %{role: "assistant", content: "second", timestamp: 2})
    loaded = SessionStore.load(dir)
    assert length(loaded) == 2
  end

  test "clear removes session file", %{dir: dir} do
    SessionStore.save(dir, [%{role: "user", content: "test"}])
    SessionStore.clear(dir)
    assert SessionStore.load(dir) == []
  end
end
