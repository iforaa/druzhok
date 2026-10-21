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
end
