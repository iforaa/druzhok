defmodule PiCore.Tools.MemoryWriteTest do
  use ExUnit.Case

  alias PiCore.Tools.MemoryWrite

  @workspace System.tmp_dir!() |> Path.join("memory_write_test_#{:rand.uniform(99999)}")

  setup do
    File.mkdir_p!(Path.join(@workspace, "memory"))
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "writes to daily file by default" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:ok, result} = tool.execute.(%{"content" => "User likes cats"}, context)

    today = Date.utc_today() |> Date.to_string()
    path = Path.join(@workspace, "memory/#{today}.md")
    assert File.exists?(path)
    content = File.read!(path)
    assert content =~ "User likes cats"
    assert content =~ "###"
    assert result =~ "Saved"
  end

  test "appends to existing file" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    tool.execute.(%{"content" => "Fact one"}, context)
    tool.execute.(%{"content" => "Fact two"}, context)

    today = Date.utc_today() |> Date.to_string()
    path = Path.join(@workspace, "memory/#{today}.md")
    content = File.read!(path)
    assert content =~ "Fact one"
    assert content =~ "Fact two"
  end

  test "rejects writes outside memory/ directory" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:error, msg} = tool.execute.(%{"content" => "hack", "file" => "AGENTS.md"}, context)
    assert msg =~ "memory/"
  end

  test "rejects path traversal" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:error, _} = tool.execute.(%{"content" => "hack", "file" => "memory/../../etc/passwd"}, context)
  end

  test "writes to custom file within memory/" do
    tool = MemoryWrite.new()
    context = %{workspace: @workspace, timezone: "UTC"}
    {:ok, _} = tool.execute.(%{"content" => "Custom note", "file" => "memory/project.md"}, context)

    path = Path.join(@workspace, "memory/project.md")
    assert File.exists?(path)
    assert File.read!(path) =~ "Custom note"
  end
end
