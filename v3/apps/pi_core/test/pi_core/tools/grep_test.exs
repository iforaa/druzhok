defmodule PiCore.Tools.GrepTest do
  use ExUnit.Case

  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_grep_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "code.ex"), "defmodule Foo do\n  def hello, do: :world\nend\n")
    File.write!(Path.join(dir, "notes.txt"), "Remember to fix the bug\nAlso update docs\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "finds matching lines", %{workspace: ws} do
    tool = PiCore.Tools.Grep.new()
    {:ok, result} = tool.execute.(%{"pattern" => "hello", "path" => "."}, %{workspace: ws})
    assert result =~ "hello"
    assert result =~ "code.ex"
  end

  test "returns no matches message", %{workspace: ws} do
    tool = PiCore.Tools.Grep.new()
    {:ok, result} = tool.execute.(%{"pattern" => "nonexistent_xyz"}, %{workspace: ws})
    assert result =~ "No matches"
  end

  test "searches specific file", %{workspace: ws} do
    tool = PiCore.Tools.Grep.new()
    {:ok, result} = tool.execute.(%{"pattern" => "bug", "path" => "notes.txt"}, %{workspace: ws})
    assert result =~ "bug"
  end

  test "blocks path traversal", %{workspace: ws} do
    tool = PiCore.Tools.Grep.new()
    {:error, msg} = tool.execute.(%{"pattern" => "test", "path" => "../../../etc"}, %{workspace: ws})
    assert msg =~ "denied"
  end
end
