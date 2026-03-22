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
end
