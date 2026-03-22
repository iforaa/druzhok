defmodule PiCore.Integration.NebiusTest do
  use ExUnit.Case
  @moduletag :integration

  defp skip_without_key do
    if is_nil(System.get_env("NEBIUS_API_KEY")) do
      IO.puts("Skipping: NEBIUS_API_KEY not set")
      :skip
    else
      :ok
    end
  end

  defp api_opts do
    %{
      api_key: System.get_env("NEBIUS_API_KEY"),
      api_url: System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"
    }
  end

  @tag :integration
  test "streaming completion" do
    unless skip_without_key() == :skip do
      opts = api_opts()
      {:ok, result} = PiCore.LLM.Client.completion(%{
        model: "Qwen/Qwen3-235B-A22B-Instruct-2507",
        api_url: opts.api_url, api_key: opts.api_key,
        system_prompt: "Reply in one word only.",
        messages: [%{role: "user", content: "Say hello"}],
        tools: [], max_tokens: 100, stream: true,
        on_delta: fn delta -> IO.write(delta) end
      })
      assert is_binary(result.content)
      assert String.length(result.content) > 0
    end
  end

  @tag :integration
  test "tool calling" do
    unless skip_without_key() == :skip do
      opts = api_opts()
      tools = [%{type: "function", function: %{name: "read", description: "Read a file",
        parameters: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]}}}]

      {:ok, result} = PiCore.LLM.Client.completion(%{
        model: "Qwen/Qwen3-235B-A22B-Instruct-2507",
        api_url: opts.api_url, api_key: opts.api_key,
        system_prompt: "Use tools when needed.",
        messages: [%{role: "user", content: "Read the file test.txt"}],
        tools: tools, max_tokens: 500, stream: true
      })
      assert length(result.tool_calls) > 0
      assert hd(result.tool_calls)["function"]["name"] == "read"
    end
  end
end
