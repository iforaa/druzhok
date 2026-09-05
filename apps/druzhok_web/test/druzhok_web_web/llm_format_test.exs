defmodule DruzhokWebWeb.LlmFormatTest do
  use ExUnit.Case, async: true
  alias DruzhokWebWeb.LlmFormat

  describe "prepare_body/1" do
    test "injects usage.include=true when absent" do
      body = LlmFormat.prepare_body(%{"model" => "xiaomi/mimo-v2.5-pro", "messages" => []})
      assert body["usage"] == %{"include" => true}
    end

    test "does not override an explicit usage option" do
      body = LlmFormat.prepare_body(%{
        "model" => "x",
        "messages" => [],
        "usage" => %{"include" => false, "extra" => "preserved"}
      })
      assert body["usage"] == %{"include" => false, "extra" => "preserved"}
    end
  end

  describe "extract_cost_cents/2" do
    test "reads usage.cost and rounds to nearest cent" do
      body = %{"usage" => %{"cost" => 0.00235, "prompt_tokens" => 100, "completion_tokens" => 20}}
      # 0.00235 * 100 = 0.235 → rounds to 0
      assert LlmFormat.extract_cost_cents(body, "any") == 0
    end

    test "reads non-trivial usage.cost" do
      body = %{"usage" => %{"cost" => 0.1234}}
      assert LlmFormat.extract_cost_cents(body, "any") == 12
    end

    test "falls back to ModelCatalog price when usage.cost is missing" do
      body = %{"usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0}}
      assert LlmFormat.extract_cost_cents(body, "xiaomi/mimo-v2.5-pro") == 10
    end

    test "returns 0 when no usage at all" do
      assert LlmFormat.extract_cost_cents(%{}, "x") == 0
      assert LlmFormat.extract_cost_cents(nil, "x") == 0
    end
  end
end
