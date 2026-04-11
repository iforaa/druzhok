defmodule Druzhok.ModelCatalog do
  @moduledoc """
  Available models from OpenRouter for the model picker.
  Images are automatically stripped from conversation for non-vision models.
  """

  @models [
    # Cheap tier — for everyday messages
    %{id: "qwen/qwen3.5-flash", name: "Qwen 3.5 Flash", price: "$0.07/M", tier: :cheap},
    %{id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite", price: "$0.15/M", tier: :cheap},
    %{id: "openai/gpt-5.4-nano", name: "GPT-5.4 Nano", price: "$0.20/M", tier: :cheap},
    %{id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash", price: "$0.50/M", tier: :cheap},
    # Mid tier — good balance
    %{id: "moonshotai/kimi-k2.5", name: "Kimi K2.5", price: "$0.42/M", tier: :mid},
    %{id: "deepseek/deepseek-v3.2", name: "DeepSeek V3.2", price: "$0.50/M", tier: :mid},
    %{id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini", price: "$0.75/M", tier: :mid},
    %{id: "x-ai/grok-4.1-fast", name: "Grok 4.1 Fast", price: "$1/M", tier: :mid},
    # Mid-smart tier
    %{id: "google/gemma-4-31b-it", name: "Gemma 4 31B", price: "$0.20/M", tier: :mid},
    # Smart tier — for complex tasks
    %{id: "google/gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", price: "$2/M", tier: :smart},
    %{id: "openai/gpt-5.4", name: "GPT-5.4", price: "$2.50/M", tier: :smart},
    %{id: "anthropic/claude-sonnet-4-6", name: "Claude Sonnet 4.6", price: "$3/M", tier: :smart},
    # Reasoning tier — models that expose step-by-step thinking via OpenRouter
    # `reasoning` + `reasoning_details`. Druzhok proxy passes the format
    # through transparently.
    %{id: "xiaomi/mimo-v2-pro", name: "MiMo V2 Pro (reasoning)", price: "$1.50/M", tier: :reasoning},
  ]

  def all, do: @models
  def default_options, do: @models
  def smart, do: @models
  def find(id), do: Enum.find(@models, &(&1.id == id))

  @image_models [
    %{id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"},
    %{id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash"},
    %{id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini"},
  ]

  @audio_models [
    %{id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe"},
  ]

  @embedding_models [
    %{id: "openai/text-embedding-3-small", name: "Text Embedding 3 Small"},
  ]

  def image_models, do: @image_models
  def audio_models, do: @audio_models
  def embedding_models, do: @embedding_models

  def default_image_model, do: "google/gemini-2.5-flash-lite"
  def default_audio_model, do: "gpt-4o-mini-transcribe"
  def default_embedding_model, do: "openai/text-embedding-3-small"
end
