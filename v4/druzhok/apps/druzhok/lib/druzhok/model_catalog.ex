defmodule Druzhok.ModelCatalog do
  @moduledoc """
  Available models from OpenRouter for the model picker.
  """

  @models [
    %{id: "qwen/qwen3.5-flash", name: "Qwen 3.5 Flash", price: "$0.07/M", tier: :cheap},
    %{id: "minimax/minimax-m2.5", name: "MiniMax M2.5", price: "$0.19/M", tier: :cheap},
    %{id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash", price: "$0.50/M", tier: :cheap},
    %{id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini", price: "$0.75/M", tier: :mid},
    %{id: "moonshotai/kimi-k2.5", name: "Kimi K2.5", price: "$0.42/M", tier: :mid},
    %{id: "deepseek/deepseek-v3.2", name: "DeepSeek V3.2", price: "$0.50/M", tier: :mid},
    %{id: "openai/gpt-5.4", name: "GPT-5.4", price: "$2.50/M", tier: :smart},
    %{id: "anthropic/claude-sonnet-4-6", name: "Claude Sonnet 4.6", price: "$3/M", tier: :smart},
    %{id: "google/gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", price: "$2/M", tier: :smart},
  ]

  def all, do: @models
  def cheap, do: Enum.filter(@models, &(&1.tier == :cheap))
  def smart, do: Enum.filter(@models, &(&1.tier == :smart))
  def find(id), do: Enum.find(@models, &(&1.id == id))
end
