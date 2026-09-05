defmodule DruzhokWebWeb.LlmFormatTest do
  use ExUnit.Case, async: true
  alias DruzhokWebWeb.LlmFormat

  describe "strip_images/1 and prompt_preview/1" do
    test "flattens image parts to text" do
      [msg] = LlmFormat.strip_images([%{"role" => "user", "content" => [%{"type" => "text", "text" => "look"}, %{"type" => "image_url", "image_url" => %{"url" => "data:x"}}]}])
      assert msg["content"] == "look"
      assert LlmFormat.strip_images("not a list") == "not a list"
    end

    test "previews the last message, text or parts, capped at 500" do
      assert LlmFormat.prompt_preview(%{"messages" => [%{"role" => "user", "content" => String.duplicate("a", 600)}]}) == String.duplicate("a", 500)
      assert LlmFormat.prompt_preview(%{"messages" => [%{"content" => [%{"type" => "text", "text" => "hi"}, %{"type" => "image_url"}]}]}) == "hi"
      assert LlmFormat.prompt_preview(%{"messages" => []}) == nil
      assert LlmFormat.prompt_preview(%{}) == nil
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

    test "falls back to the OpenRouter price table when usage.cost is missing" do
      body = %{"usage" => %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0}}
      assert LlmFormat.extract_cost_cents(body, "xiaomi/mimo-v2.5-pro") == 10
    end

    test "returns 0 when no usage at all" do
      assert LlmFormat.extract_cost_cents(%{}, "x") == 0
      assert LlmFormat.extract_cost_cents(nil, "x") == 0
    end
  end
end
