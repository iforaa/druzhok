defmodule PiCore.Tools.FindTest do
  use ExUnit.Case

  setup do
    dir = Path.join(System.tmp_dir!(), "pi_core_find_#{:rand.uniform(100000)}")
    File.mkdir_p!(Path.join(dir, "src"))
    File.write!(Path.join(dir, "src/main.ex"), "defmodule Main do end")
    File.write!(Path.join(dir, "src/helper.ex"), "defmodule Helper do end")
    File.write!(Path.join(dir, "readme.md"), "# Readme")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "finds files by pattern", %{workspace: ws} do
    tool = PiCore.Tools.Find.new()
    {:ok, result} = tool.execute.(%{"pattern" => "**/*.ex"}, %{workspace: ws})
    assert result =~ "main.ex"
    assert result =~ "helper.ex"
    refute result =~ "readme.md"
  end

  test "returns message when no matches", %{workspace: ws} do
    tool = PiCore.Tools.Find.new()
    {:ok, result} = tool.execute.(%{"pattern" => "**/*.py"}, %{workspace: ws})
    assert result =~ "No files found"
  end
end
