defmodule PiCore.WorkspaceLoaderTest do
  use ExUnit.Case

  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_ws_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "AGENTS.md"), "# Instructions\nBe helpful.")
    File.write!(Path.join(dir, "SOUL.md"), "# Soul\nBe genuine.")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "loads workspace files into system prompt", %{workspace: ws} do
    prompt = PiCore.WorkspaceLoader.Default.load(ws, %{})
    assert prompt =~ "Be helpful."
    assert prompt =~ "Be genuine."
  end

  test "handles missing files gracefully", %{workspace: ws} do
    File.rm!(Path.join(ws, "SOUL.md"))
    prompt = PiCore.WorkspaceLoader.Default.load(ws, %{})
    assert prompt =~ "Be helpful."
    refute prompt =~ "Be genuine."
  end

  test "handles empty workspace" do
    dir = Path.join(System.tmp_dir!(), "empty_ws_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    prompt = PiCore.WorkspaceLoader.Default.load(dir, %{})
    assert prompt == "You are a helpful AI assistant."
    File.rm_rf!(dir)
  end
end
