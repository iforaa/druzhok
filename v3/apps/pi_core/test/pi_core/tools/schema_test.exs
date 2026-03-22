defmodule PiCore.Tools.SchemaTest do
  use ExUnit.Case
  alias PiCore.Tools.{Tool, Schema}

  test "converts tool to OpenAI format" do
    tool = %Tool{name: "bash", description: "Run command",
      parameters: %{command: %{type: :string, description: "Command to run"}},
      execute: fn _, _ -> {:ok, ""} end}
    openai = Schema.to_openai(tool)
    assert openai["type"] == "function"
    assert openai["function"]["name"] == "bash"
    assert openai["function"]["parameters"]["properties"]["command"]["type"] == "string"
    assert "command" in openai["function"]["parameters"]["required"]
  end

  test "converts list of tools" do
    tools = [
      %Tool{name: "bash", description: "Run", parameters: %{command: %{type: :string}}, execute: fn _, _ -> {:ok, ""} end},
      %Tool{name: "read", description: "Read", parameters: %{path: %{type: :string}}, execute: fn _, _ -> {:ok, ""} end},
    ]
    list = Schema.to_openai_list(tools)
    assert length(list) == 2
  end
end
