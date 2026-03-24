defmodule PiCore.LLM.OpenAITest do
  use ExUnit.Case

  @base_opts %{
    model: "test-model",
    api_url: "https://api.test.com/v1",
    api_key: "test-key",
    system_prompt: "You are a test bot",
    messages: [],
    tools: [],
    max_tokens: 1024,
    stream: false
  }

  test "build_request includes OpenRouter headers when provider is openrouter" do
    opts = Map.put(@base_opts, :provider, :openrouter)
    request = PiCore.LLM.OpenAI.build_request(opts)
    headers_map = Map.new(request.headers)
    assert headers_map["HTTP-Referer"] == "https://druzhok.app"
    assert headers_map["X-Title"] == "Druzhok"
  end

  test "build_request does not include OpenRouter headers for other providers" do
    opts = Map.put(@base_opts, :provider, :openai)
    request = PiCore.LLM.OpenAI.build_request(opts)
    headers_map = Map.new(request.headers)
    assert headers_map["HTTP-Referer"] == nil
  end

  test "build_request works when provider key is absent" do
    request = PiCore.LLM.OpenAI.build_request(@base_opts)
    headers_map = Map.new(request.headers)
    assert headers_map["HTTP-Referer"] == nil
    assert headers_map["authorization"] == "Bearer test-key"
  end
end
