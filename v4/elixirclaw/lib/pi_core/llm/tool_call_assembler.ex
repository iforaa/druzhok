defmodule PiCore.LLM.ToolCallAssembler do
  @moduledoc """
  Assembles streamed tool call fragments into complete tool call maps.

  Used by both OpenAI and Anthropic streaming clients to accumulate
  partial tool call data (id, name, argument JSON chunks) and produce
  final OpenAI-format tool_calls lists.
  """

  defstruct calls: []

  def new, do: %__MODULE__{}

  def start_call(%__MODULE__{calls: calls} = state, index, id, name) do
    entry = %{index: index, id: id, name: name, args_json: ""}
    %{state | calls: calls ++ [entry]}
  end

  def append_args(%__MODULE__{calls: calls} = state, index, fragment) do
    calls = Enum.map(calls, fn
      %{index: ^index} = c -> %{c | args_json: c.args_json <> fragment}
      c -> c
    end)
    %{state | calls: calls}
  end

  def finalize(%__MODULE__{calls: calls}) do
    Enum.map(calls, fn c ->
      %{
        "id" => c.id,
        "type" => "function",
        "function" => %{
          "name" => c.name,
          "arguments" => c.args_json
        }
      }
    end)
  end
end
