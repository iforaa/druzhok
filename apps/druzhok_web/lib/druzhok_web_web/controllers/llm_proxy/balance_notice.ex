defmodule DruzhokWebWeb.LlmProxy.BalanceNotice do
  @moduledoc """
  What a bot says when its plan refuses: a 402, or a windowed plan's 429
  `usage_limit_reached`.

  Hermes turns any 402 into its own English "billing exhausted" lecture that
  tells the user to add credits at the provider and to switch providers with
  `/model` — neither of which a tenant can do — and a 429 into a retry. So the
  proxy answers either with an ordinary completion carrying this notice in the
  bot's language; hermes shows it like any assistant reply. The refusal itself
  is still logged. Hermes's auxiliary calls (`LlmProxy.AuxShapes`) get the real
  refusal instead.
  """

  # Anyone chatting with the bot reads this, group members included, and only
  # the owner can open the cabinet and pay: so no top-up here. The owner's own
  # note, with the button and the top-up, is `Druzhok.Cabinet`'s.
  @notices %{
    "ru" => "Лимит тарифа на сейчас исчерпан. Подробности — у владельца бота в «Кабинете».",
    "en" => "The plan's limit is used up for now. The bot's owner has the details in «Кабинет»."
  }

  @doc "The notice for an instance's language; anything but Russian gets English."
  def text(%{language: lang}), do: Map.get(@notices, lang, @notices["en"])

  @doc "A non-streaming `chat.completion` body carrying the notice."
  def completion(instance, model) do
    %{
      "id" => id(),
      "object" => "chat.completion",
      "created" => System.os_time(:second),
      "model" => model,
      "choices" => [
        %{"index" => 0, "message" => %{"role" => "assistant", "content" => text(instance)}, "finish_reason" => "stop"}
      ],
      "usage" => %{"prompt_tokens" => 0, "completion_tokens" => 0, "total_tokens" => 0}
    }
  end

  @doc "The same notice as a complete SSE stream: one content chunk, then `[DONE]`."
  def sse(instance, model) do
    chunk = %{
      "id" => id(),
      "object" => "chat.completion.chunk",
      "created" => System.os_time(:second),
      "model" => model,
      "choices" => [
        %{"index" => 0, "delta" => %{"role" => "assistant", "content" => text(instance)}, "finish_reason" => "stop"}
      ]
    }

    "data: " <> Jason.encode!(chunk) <> "\n\ndata: [DONE]\n\n"
  end

  defp id, do: "chatcmpl-balance-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
