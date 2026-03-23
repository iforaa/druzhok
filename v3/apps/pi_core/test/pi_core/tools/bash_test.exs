defmodule PiCore.Tools.BashTest do
  use ExUnit.Case

  test "executes command" do
    tool = PiCore.Tools.Bash.new()
    {:ok, output} = tool.execute.(%{"command" => "echo hello"}, %{workspace: "/tmp"})
    assert String.trim(output) == "hello"
  end

  test "returns error for failed command" do
    tool = PiCore.Tools.Bash.new()
    {:error, _} = tool.execute.(%{"command" => "exit 1"}, %{workspace: "/tmp"})
  end

  test "times out long-running commands" do
    tool = PiCore.Tools.Bash.new()
    context = %{workspace: System.tmp_dir!(), bash_timeout_ms: 100}
    result = tool.execute.(%{"command" => "sleep 10"}, context)
    assert {:error, msg} = result
    assert msg =~ "timed out"
  end
end
