defmodule PiCore.Loop do
  alias PiCore.Tools.Schema

  defmodule Message do
    defstruct [:role, :content, :tool_calls, :tool_call_id, :tool_name, :is_error, :timestamp]
  end

  @max_iterations 20

  def run(opts) do
    tools = opts[:tools] || []
    tool_context = opts[:tool_context] || %{}
    openai_tools = Schema.to_openai_list(tools)

    loop(opts, openai_tools, tools, tool_context, [], 0)
  end

  defp loop(_opts, _openai_tools, _tools, _tool_context, _messages, iterations)
       when iterations > @max_iterations do
    {:error, "Too many iterations (#{iterations})"}
  end

  defp loop(opts, openai_tools, tools, tool_context, new_messages, iterations) do
    all_messages = opts.messages ++ new_messages

    llm_messages =
      Enum.map(all_messages, fn
        %Message{role: "toolResult"} = m ->
          %{role: "tool", tool_call_id: m.tool_call_id, content: m.content || ""}

        %Message{} = m ->
          base = %{role: m.role, content: m.content || ""}

          if m.tool_calls && m.tool_calls != [],
            do: Map.put(base, :tool_calls, m.tool_calls),
            else: base

        %{} = m ->
          base = %{role: m[:role] || m["role"], content: m[:content] || m["content"] || ""}
          tool_calls = m[:tool_calls] || m["tool_calls"]

          if tool_calls && tool_calls != [],
            do: Map.put(base, :tool_calls, tool_calls),
            else: base
      end)

    llm_opts = %{
      system_prompt: opts.system_prompt,
      messages: llm_messages,
      tools: openai_tools,
      on_delta: opts[:on_delta]
    }

    case opts.llm_fn.(llm_opts) do
      {:ok, result} ->
        assistant_msg = %Message{
          role: "assistant",
          content: result.content,
          tool_calls: result.tool_calls,
          timestamp: System.os_time(:millisecond)
        }

        new_messages = new_messages ++ [assistant_msg]

        if result.tool_calls == nil || result.tool_calls == [] do
          {:ok, new_messages}
        else
          tool_results = execute_tool_calls(result.tool_calls, tools, tool_context)
          new_messages = new_messages ++ tool_results
          loop(opts, openai_tools, tools, tool_context, new_messages, iterations + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool_calls(tool_calls, tools, context) do
    Enum.map(tool_calls, fn call ->
      tool_name = get_in(call, ["function", "name"])
      raw_args = get_in(call, ["function", "arguments"]) || "{}"
      tool_call_id = call["id"]

      tool = Enum.find(tools, &(&1.name == tool_name))

      {content, is_error} =
        if tool do
          case Jason.decode(raw_args) do
            {:ok, args} ->
              case tool.execute.(args, context) do
                {:ok, output} -> {to_string(output), false}
                {:error, reason} -> {to_string(reason), true}
              end

            {:error, _} ->
              {"Invalid JSON arguments: #{raw_args}", true}
          end
        else
          {"Tool #{tool_name} not found", true}
        end

      %Message{
        role: "toolResult",
        content: content,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        is_error: is_error,
        timestamp: System.os_time(:millisecond)
      }
    end)
  end
end
