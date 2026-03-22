defmodule PiCore.LLM.ClientTest do
  use ExUnit.Case
  alias PiCore.LLM.Client

  test "build_request creates correct body" do
    request = Client.build_request(%{
      model: "zai-org/GLM-5", api_url: "https://example.com/v1", api_key: "test-key",
      system_prompt: "You are helpful",
      messages: [%{role: "user", content: "hello"}],
      tools: [], max_tokens: 1000, stream: true
    })
    assert request.url == "https://example.com/v1/chat/completions"
    body = Jason.decode!(request.body)
    assert body["model"] == "zai-org/GLM-5"
    assert body["stream"] == true
    assert body["max_tokens"] == 1000
    assert length(body["messages"]) == 2
    assert hd(body["messages"])["role"] == "system"
  end

  test "build_request includes tools when present" do
    tools = [%{type: "function", function: %{name: "bash", description: "Run", parameters: %{type: "object", properties: %{command: %{type: "string"}}, required: ["command"]}}}]
    request = Client.build_request(%{
      model: "test", api_url: "https://example.com/v1", api_key: "k",
      system_prompt: "test", messages: [], tools: tools, max_tokens: 100, stream: false
    })
    body = Jason.decode!(request.body)
    assert length(body["tools"]) == 1
  end

  test "build_request omits tools when empty" do
    request = Client.build_request(%{
      model: "test", api_url: "https://example.com/v1", api_key: "k",
      system_prompt: "test", messages: [], tools: [], max_tokens: 100, stream: false
    })
    body = Jason.decode!(request.body)
    refute Map.has_key?(body, "tools")
  end
end
