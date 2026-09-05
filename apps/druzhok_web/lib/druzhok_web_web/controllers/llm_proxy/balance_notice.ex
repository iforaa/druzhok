defmodule DruzhokWebWeb.LlmProxy.BalanceNotice do
  @moduledoc """
  What a bot says when its ruoc account is empty.

  Hermes turns any 402 into its own English "billing exhausted" lecture that
  tells the user to add credits at the provider and to switch providers with
  `/model` — neither of which a tenant can do. So the proxy answers a 402
  with an ordinary completion carrying this notice in the bot's language;
  hermes shows it like any assistant reply. The 402 itself is still logged.
  """

  @notices %{
    "ru" => "💳 Баланс бота исчерпан. Пополни счёт, чтобы продолжить.",
    "en" => "💳 The bot's balance is used up. Top up the account to continue."
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
