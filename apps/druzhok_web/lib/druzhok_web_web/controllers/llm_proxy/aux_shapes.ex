defmodule DruzhokWebWeb.LlmProxy.AuxShapes do
  @moduledoc """
  Recognises hermes's auxiliary chat calls (compression summary, photo
  description, session title, memory query rewrite), whose plan refusal (a 402,
  or a 429 `usage_limit_reached`) is passed through as it came instead of
  becoming the balance notice: as a completion,
  the notice would turn into a summary, a description or a title
  (spec 2026-10-25-bot-voice-design.md, «The 402 notice»).

  The gate recognises auxiliary calls, never agent calls, so anything
  unrecognised still gets the notice. An auxiliary call carries no `tools`
  and either no system message at all (the compressor and vision send a
  single user message) or a first system message starting with one of the
  prefixes below, taken from hermes 0.22.2. The `update-hermes` skill checks
  they still match; a changed prompt only brings back the old behaviour.
  """

  @prefixes [
    # agent/title_generator.py _TITLE_PROMPT_TEMPLATE
    "You name chat sessions.",
    # plugins/memory/query_rewrite.py _SYSTEM_PROMPT
    "You rewrite a user's latest message into one concise English question for memory retrieval."
  ]

  def prefixes, do: @prefixes

  @doc "Whether a chat request body is one of hermes's auxiliary calls."
  def aux?(%{} = body) do
    no_tools?(body["tools"]) and
      case first_system(body["messages"]) do
        nil -> true
        text -> Enum.any?(@prefixes, &String.starts_with?(text, &1))
      end
  end

  def aux?(_), do: false

  defp no_tools?(tools), do: tools in [nil, []]

  defp first_system(messages) when is_list(messages) do
    Enum.find_value(messages, fn
      %{"role" => role, "content" => content} when role in ["system", "developer"] ->
        text(content)

      _ ->
        nil
    end)
  end

  defp first_system(_), do: nil

  defp text(content) when is_binary(content), do: content

  defp text(parts) when is_list(parts) do
    Enum.map_join(parts, fn
      %{"type" => "text", "text" => t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp text(_), do: ""
end
