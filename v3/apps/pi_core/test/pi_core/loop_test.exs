defmodule PiCore.LoopTest do
  use ExUnit.Case

  alias PiCore.Loop
  alias PiCore.LLM.Client.Result

  # Mock LLM: always returns text
  defp mock_text(text) do
    fn _opts -> {:ok, %Result{content: text, tool_calls: []}} end
  end

  # Mock LLM: first call returns tool_call, second returns text
  defp mock_with_tool(tool_name, tool_args, final_text) do
    counter = :counters.new(1, [:atomics])

    fn _opts ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      if count == 0 do
        {:ok,
         %Result{
           content: "",
           tool_calls: [
             %{
               "id" => "call_1",
               "function" => %{
                 "name" => tool_name,
                 "arguments" => Jason.encode!(tool_args)
               }
             }
           ]
         }}
      else
        {:ok, %Result{content: final_text, tool_calls: []}}
      end
    end
  end

  test "simple text response" do
    {:ok, messages} =
      Loop.run(%{
        system_prompt: "Be brief.",
        messages: [%{role: "user", content: "Hi"}],
        tools: [],
        llm_fn: mock_text("Hello!")
      })

    assistant = Enum.find(messages, &(&1.role == "assistant"))
    assert assistant.content == "Hello!"
  end

  test "tool call and response" do
    read_tool = %PiCore.Tools.Tool{
      name: "read",
      description: "Read file",
      parameters: %{path: %{type: :string}},
      execute: fn %{"path" => _}, _ctx -> {:ok, "file content here"} end
    }

    {:ok, messages} =
      Loop.run(%{
        system_prompt: "Use tools.",
        messages: [%{role: "user", content: "Read test.txt"}],
        tools: [read_tool],
        tool_context: %{workspace: "/tmp"},
        llm_fn: mock_with_tool("read", %{path: "test.txt"}, "File says: file content here")
      })

    roles = Enum.map(messages, & &1.role)
    assert "assistant" in roles
    assert "toolResult" in roles
    final = List.last(messages)
    assert final.content =~ "file content"
  end

  test "unknown tool returns error result" do
    counter = :counters.new(1, [:atomics])

    {:ok, messages} =
      Loop.run(%{
        system_prompt: "test",
        messages: [%{role: "user", content: "test"}],
        tools: [],
        llm_fn: fn _opts ->
          count = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if count == 0 do
            {:ok,
             %Result{
               content: "",
               tool_calls: [
                 %{
                   "id" => "call_1",
                   "function" => %{"name" => "unknown", "arguments" => "{}"}
                 }
               ]
             }}
          else
            {:ok, %Result{content: "ok", tool_calls: []}}
          end
        end
      })

    tool_result = Enum.find(messages, &(&1.role == "toolResult"))
    assert tool_result.content =~ "not found"
    assert tool_result.is_error == true
  end

  test "llm error propagates" do
    {:error, reason} =
      Loop.run(%{
        system_prompt: "test",
        messages: [%{role: "user", content: "test"}],
        tools: [],
        llm_fn: fn _opts -> {:error, "API down"} end
      })

    assert reason == "API down"
  end

  test "max iterations prevents infinite loop" do
    {:error, reason} =
      Loop.run(%{
        system_prompt: "test",
        messages: [%{role: "user", content: "test"}],
        tools: [],
        llm_fn: fn _opts ->
          {:ok,
           %Result{
             content: "",
             tool_calls: [
               %{
                 "id" => "call_1",
                 "function" => %{"name" => "fake", "arguments" => "{}"}
               }
             ]
           }}
        end
      })

    assert reason =~ "Too many iterations"
  end
end
