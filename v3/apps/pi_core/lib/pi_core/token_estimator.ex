defmodule PiCore.TokenEstimator do
  @moduledoc """
  Token estimation using byte_size / divisor heuristic.
  Conservative for non-Latin text (Cyrillic = 2 bytes/char in UTF-8).
  """

  alias PiCore.Loop.Message

  @default_divisor 4

  def estimate(nil), do: 0
  def estimate(""), do: 0
  def estimate(content) when is_list(content) do
    estimate(PiCore.Multimodal.to_text(content))
  end
  def estimate(text) when is_binary(text) do
    div(byte_size(text) + @default_divisor - 1, divisor())
  end

  def estimate_message(%Message{} = msg) do
    content_tokens = estimate(msg.content)
    tool_tokens = estimate_tool_calls(msg.tool_calls)
    content_tokens + tool_tokens
  end
  def estimate_message(%{} = msg) do
    content_tokens = estimate(msg[:content] || msg["content"])
    tool_tokens = estimate_tool_calls(msg[:tool_calls] || msg["tool_calls"])
    content_tokens + tool_tokens
  end

  def estimate_messages(messages) when is_list(messages) do
    Enum.reduce(messages, 0, fn msg, acc -> acc + estimate_message(msg) end)
  end

  def estimate_tools(tools) when is_list(tools) do
    tools
    |> Jason.encode!()
    |> estimate()
  end

  defp estimate_tool_calls(nil), do: 0
  defp estimate_tool_calls([]), do: 0
  defp estimate_tool_calls(calls) do
    Enum.reduce(calls, 0, fn call, acc ->
      name = get_in(call, ["function", "name"]) || ""
      args = get_in(call, ["function", "arguments"]) || ""
      acc + estimate(name) + estimate(args)
    end)
  end

  defp divisor do
    Application.get_env(:pi_core, :token_estimation_divisor, @default_divisor)
  end
end
