defmodule PiCore.MultimodalTest do
  use ExUnit.Case

  alias PiCore.Multimodal

  test "to_text converts string content to itself" do
    assert Multimodal.to_text("hello") == "hello"
  end

  test "to_text converts content array to text with image placeholder" do
    content = [
      %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,abc123"}},
      %{"type" => "text", "text" => "What is this?"}
    ]
    result = Multimodal.to_text(content)
    assert result =~ "[изображение]"
    assert result =~ "What is this?"
    refute result =~ "base64"
  end

  test "to_text handles nil" do
    assert Multimodal.to_text(nil) == ""
  end

  test "to_anthropic_content converts image_url to anthropic format" do
    content = [
      %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,/9j/abc"}},
      %{"type" => "text", "text" => "Describe this"}
    ]
    result = Multimodal.to_anthropic_content(content)

    image_block = Enum.find(result, & &1[:type] == "image")
    assert image_block.source.type == "base64"
    assert image_block.source.media_type == "image/jpeg"
    assert image_block.source.data == "/9j/abc"

    text_block = Enum.find(result, & &1[:type] == "text")
    assert text_block.text == "Describe this"
  end

  test "to_anthropic_content handles png" do
    content = [
      %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,iVBOR"}}
    ]
    [block] = Multimodal.to_anthropic_content(content)
    assert block.source.media_type == "image/png"
  end

  test "is_multimodal? returns true for list content" do
    assert Multimodal.is_multimodal?([%{"type" => "text"}])
  end

  test "is_multimodal? returns false for string content" do
    refute Multimodal.is_multimodal?("hello")
  end

  test "is_multimodal? returns false for nil" do
    refute Multimodal.is_multimodal?(nil)
  end
end
