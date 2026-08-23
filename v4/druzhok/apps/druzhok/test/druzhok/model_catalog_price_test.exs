defmodule Druzhok.ModelCatalogPriceTest do
  use ExUnit.Case, async: true
  alias Druzhok.ModelCatalog

  describe "price_per_million/1" do
    test "returns known prices for common models" do
      assert %{input: 10, output: 150} = ModelCatalog.price_per_million("xiaomi/mimo-v2.5-pro")
      assert %{input: 10, output: 40} = ModelCatalog.price_per_million("google/gemini-2.5-flash-lite")
      assert %{input: 300, output: 1500} = ModelCatalog.price_per_million("anthropic/claude-sonnet-4-6")
    end

    test "returns safe zeros for unknown models" do
      assert %{input: 0, output: 0} = ModelCatalog.price_per_million("nonexistent/model")
      assert %{input: 0, output: 0} = ModelCatalog.price_per_million(nil)
    end
  end
end
