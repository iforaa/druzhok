defmodule Druzhok.SandboxTest do
  use ExUnit.Case, async: false

  alias Druzhok.Sandbox.Local

  test "local exec runs command" do
    {:ok, result} = Local.exec("test", "echo hello")
    assert result.stdout =~ "hello"
    assert result.exit_code == 0
  end

  test "local exec returns non-zero exit code" do
    {:ok, result} = Local.exec("test", "exit 42")
    assert result.exit_code == 42
  end

  test "local read_file works" do
    path = Path.join(System.tmp_dir!(), "sandbox_test_read_#{:rand.uniform(100000)}")
    File.write!(path, "test content")
    {:ok, content} = Local.read_file("test", path)
    assert content == "test content"
    File.rm!(path)
  end

  test "local read_file returns error for missing file" do
    {:error, _} = Local.read_file("test", "/tmp/nonexistent_#{:rand.uniform(100000)}")
  end

  test "local write_file creates file and dirs" do
    dir = Path.join(System.tmp_dir!(), "sandbox_test_write_#{:rand.uniform(100000)}")
    path = Path.join(dir, "subdir/file.txt")
    :ok = Local.write_file("test", path, "written")
    assert File.read!(path) == "written"
    File.rm_rf!(dir)
  end

  test "local list_dir returns entries" do
    dir = Path.join(System.tmp_dir!(), "sandbox_test_ls_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "a.txt"), "hello")
    File.mkdir_p!(Path.join(dir, "subdir"))

    {:ok, items} = Local.list_dir("test", dir)
    assert length(items) == 2
    names = Enum.map(items, & &1.name) |> Enum.sort()
    assert names == ["a.txt", "subdir"]

    File.rm_rf!(dir)
  end

  test "sandbox behaviour impl returns correct module" do
    assert Druzhok.Sandbox.impl("local") == Druzhok.Sandbox.Local
    assert Druzhok.Sandbox.impl("docker") == Druzhok.Sandbox.Docker
    assert Druzhok.Sandbox.impl(nil) == Druzhok.Sandbox.Local
  end
end
