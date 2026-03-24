defmodule PiCore.Loop do
  alias PiCore.Tools.Schema

  defmodule Message do
    @derive Jason.Encoder
    defstruct [:role, :content, :tool_calls, :tool_call_id, :tool_name, :is_error, :timestamp, metadata: %{}]
  end

  def run(opts) do
    tools = opts[:tools] || []
    tool_context = opts[:tool_context] || %{}
    openai_tools = Schema.to_openai_list(tools)

    emit(opts, %{type: :loop_start, tool_count: length(tools), message_count: length(opts.messages), model: opts[:model]})
    loop(opts, openai_tools, tools, tool_context, [], 0)
  end

  defp loop(opts, openai_tools, tools, tool_context, new_messages, iterations) do
    if iterations > PiCore.Config.max_iterations() do
      {:error, "Too many iterations (#{iterations})"}
    else
    all_messages = opts.messages ++ new_messages

    transformed = if opts[:budget] do
      PiCore.Transform.transform_messages(all_messages, opts.budget, length(opts.messages))
    else
      all_messages
    end

    llm_messages =
      Enum.map(transformed, fn
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

    emit(opts, %{type: :llm_start, iteration: iterations, message_count: length(llm_messages)})
    t0 = System.monotonic_time(:millisecond)

    llm_opts = %{
      system_prompt: opts.system_prompt,
      messages: llm_messages,
      tools: openai_tools,
      on_delta: opts[:on_delta],
      on_event: opts[:on_event]
    }

    case opts.llm_fn.(llm_opts) do
      {:ok, result} ->
        result = %{result | content: PiCore.Sanitize.strip_artifacts(result.content || "")}

        elapsed = System.monotonic_time(:millisecond) - t0
        has_tools = result.tool_calls != nil and result.tool_calls != []
        content_len = String.length(result.content || "")

        emit(opts, %{type: :llm_done, iteration: iterations, elapsed_ms: elapsed,
                     has_tool_calls: has_tools, content_length: content_len,
                     reasoning_length: String.length(result.reasoning || "")})

        assistant_msg = %Message{
          role: "assistant",
          content: result.content,
          tool_calls: result.tool_calls,
          timestamp: System.os_time(:millisecond)
        }

        new_messages = new_messages ++ [assistant_msg]

        if !has_tools do
          {:ok, new_messages}
        else
          for call <- result.tool_calls do
            name = get_in(call, ["function", "name"])
            args = get_in(call, ["function", "arguments"]) || "{}"
            emit(opts, %{type: :tool_call, name: name, arguments: args})
          end

          tool_results = execute_tool_calls(result.tool_calls, tools, tool_context, opts)

          for tr <- tool_results do
            emit(opts, %{type: :tool_result, name: tr.tool_name, is_error: tr.is_error,
                         content: String.slice(tr.content || "", 0, 500)})
          end

          new_messages = new_messages ++ tool_results
          loop(opts, openai_tools, tools, tool_context, new_messages, iterations + 1)
        end

      {:error, reason} ->
        elapsed = System.monotonic_time(:millisecond) - t0
        emit(opts, %{type: :llm_error, iteration: iterations, elapsed_ms: elapsed, error: inspect(reason)})
        {:error, reason}
    end
    end
  end

  defp execute_tool_calls(tool_calls, tools, context, opts) do
    Enum.map(tool_calls, fn call ->
      tool_name = get_in(call, ["function", "name"])
      raw_args = get_in(call, ["function", "arguments"]) || "{}"
      tool_call_id = call["id"]

      # Case-insensitive lookup — some models emit wrong casing
      tool_name_down = String.downcase(tool_name)
      tool = Enum.find(tools, &(&1.name == tool_name_down || &1.name == tool_name))

      t0 = System.monotonic_time(:millisecond)

      {content, is_error} =
        if tool do
          case Jason.decode(raw_args) do
            {:ok, args} ->
              case tool.execute.(args, context) do
                {:ok, output} -> {truncate_output(to_string(output), opts), false}
                {:error, reason} -> {truncate_output(to_string(reason), opts), true}
              end

            {:error, _} ->
              {"Invalid JSON arguments: #{raw_args}", true}
          end
        else
          {"Tool #{tool_name} not found", true}
        end

      elapsed = System.monotonic_time(:millisecond) - t0
      emit(opts, %{type: :tool_exec, name: tool_name, elapsed_ms: elapsed, is_error: is_error})

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

  defp emit(opts, event) do
    if on_event = opts[:on_event], do: on_event.(event)
  end

  defp truncate_output(text, opts) do
    max = if opts[:budget] do
      PiCore.TokenBudget.per_tool_result_cap(opts.budget) * 4
    else
      PiCore.Config.max_tool_output()
    end

    if byte_size(text) <= max do
      text
    else
      PiCore.Truncate.head_tail(text, max)
    end
  end
end
