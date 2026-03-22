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
        model: "Qwen/Qwen3.5-397B-A17B",
        api_url: opts.api_url, api_key: opts.api_key,
        system_prompt: "Reply in one word only.",
        messages: [%{role: "user", content: "Say hello"}],
        tools: [], max_tokens: 2000, stream: true,
        on_delta: fn delta -> IO.write(delta) end
      })
      # Some models return content, some return reasoning_content
      has_content = is_binary(result.content) && String.length(result.content) > 0
      has_reasoning = is_binary(result.reasoning) && String.length(result.reasoning) > 0
      assert has_content || has_reasoning, "Expected content or reasoning, got neither"
    end
  end

  @tag :integration
  test "tool calling" do
    unless skip_without_key() == :skip do
      opts = api_opts()
      tools = [%{type: "function", function: %{name: "read", description: "Read a file",
        parameters: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]}}}]

      {:ok, result} = PiCore.LLM.Client.completion(%{
        model: "Qwen/Qwen3.5-397B-A17B",
        api_url: opts.api_url, api_key: opts.api_key,
        system_prompt: "Use tools when needed.",
        messages: [%{role: "user", content: "Read the file test.txt"}],
        tools: tools, max_tokens: 500, stream: true
      })
      assert length(result.tool_calls) > 0
      assert hd(result.tool_calls)["function"]["name"] == "read"
    end
  end

  @tag :integration
  test "full agent run: create file and read it back" do
    unless skip_without_key() == :skip do
      opts = api_opts()
      dir = Path.join(System.tmp_dir!(), "pi_core_e2e_#{:rand.uniform(100000)}")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "AGENTS.md"), "You are a helpful assistant. Use tools when needed. Be brief.")

      {:ok, pid} = PiCore.Session.start_link(%{
        workspace: dir,
        model: "Qwen/Qwen3.5-397B-A17B",
        api_url: opts.api_url,
        api_key: opts.api_key,
        caller: self()
      })

      PiCore.Session.prompt(pid, "Create a file called hello.txt containing 'hello from elixir', then read it back and tell me what it says. Be brief.")

      assert_receive {:pi_response, %{text: text}}, 120_000
      assert text =~ "hello"
      assert File.exists?(Path.join(dir, "hello.txt"))
      assert File.read!(Path.join(dir, "hello.txt")) =~ "hello from elixir"

      File.rm_rf!(dir)
    end
  end
end
