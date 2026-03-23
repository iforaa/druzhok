defmodule Druzhok.ModelInfoTest do
  use ExUnit.Case, async: false

  alias Druzhok.ModelInfo

  test "context_window returns default for unknown model" do
    assert ModelInfo.context_window("totally-unknown-model") == 32_000
  end

  test "context_window strips provider prefix" do
    assert ModelInfo.context_window("nebius/some/unknown") == 32_000
  end

  test "context_window returns DB value for known model" do
    {:ok, model} =
      Druzhok.Repo.insert(%Druzhok.Model{
        model_id: "test-model-cw-#{:rand.uniform(100_000)}",
        label: "Test",
        context_window: 128_000
      })

    assert ModelInfo.context_window(model.model_id) == 128_000
    Druzhok.Repo.delete(model)
  end

  test "context_window matches after stripping provider prefix" do
    model_id = "DeepSeek-R1-strip-#{:rand.uniform(100_000)}"

    {:ok, model} =
      Druzhok.Repo.insert(%Druzhok.Model{
        model_id: model_id,
        label: "DS",
        context_window: 64_000,
        supports_reasoning: true
      })

    assert ModelInfo.context_window("nebius/deepseek-ai/#{model_id}") == 64_000
    Druzhok.Repo.delete(model)
  end

  test "supports_reasoning? returns false for unknown model" do
    refute ModelInfo.supports_reasoning?("unknown-model-#{:rand.uniform(100_000)}")
  end

  test "supports_tools? returns true for unknown model" do
    assert ModelInfo.supports_tools?("unknown-model-#{:rand.uniform(100_000)}")
  end
end
