defmodule PiCore.Tools.ReadTest do
  use ExUnit.Case
  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_read_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "test.txt"), "hello world")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end
  test "reads file", %{workspace: ws} do
    tool = PiCore.Tools.Read.new()
    {:ok, content} = tool.execute.(%{"path" => "test.txt"}, %{workspace: ws})
    assert content == "hello world"
  end
  test "blocks path traversal", %{workspace: ws} do
    tool = PiCore.Tools.Read.new()
    {:error, msg} = tool.execute.(%{"path" => "../../../etc/passwd"}, %{workspace: ws})
    assert msg =~ "denied"
  end
end
