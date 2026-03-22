defmodule PiCore.Tools.WriteTest do
  use ExUnit.Case
  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_write_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end
  test "writes file", %{workspace: ws} do
    tool = PiCore.Tools.Write.new()
    {:ok, _} = tool.execute.(%{"path" => "out.txt", "content" => "hello"}, %{workspace: ws})
    assert File.read!(Path.join(ws, "out.txt")) == "hello"
  end
  test "creates subdirectories", %{workspace: ws} do
    tool = PiCore.Tools.Write.new()
    {:ok, _} = tool.execute.(%{"path" => "sub/dir/file.txt", "content" => "deep"}, %{workspace: ws})
    assert File.read!(Path.join(ws, "sub/dir/file.txt")) == "deep"
  end
  test "blocks path traversal", %{workspace: ws} do
    tool = PiCore.Tools.Write.new()
    {:error, msg} = tool.execute.(%{"path" => "../../etc/evil", "content" => "bad"}, %{workspace: ws})
    assert msg =~ "denied"
  end
end
