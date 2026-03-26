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

    # Strip images if model doesn't support vision
    llm_messages = if supports_vision?(opts) do
      llm_messages
    else
      strip_images(llm_messages)
    end

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

        tool_calls_count = if has_tools, do: length(result.tool_calls), else: 0
        prompt_preview = format_full_prompt(opts.system_prompt, llm_messages)
        emit(opts, %{type: :llm_done, iteration: iterations, elapsed_ms: elapsed,
                     has_tool_calls: has_tools, tool_calls_count: tool_calls_count,
                     content_length: content_len,
                     reasoning_length: String.length(result.reasoning || ""),
                     input_tokens: result.input_tokens, output_tokens: result.output_tokens,
                     model: opts[:model],
                     prompt_preview: prompt_preview,
                     response_preview: result.content || ""})

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
      emit(opts, %{type: :tool_exec, name: tool_name, elapsed_ms: elapsed, is_error: is_error, output_size: byte_size(content)})

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

  defp format_full_prompt(system_prompt, messages) do
    parts = ["[SYSTEM]\n#{system_prompt || ""}\n"]

    msg_parts = Enum.map(messages, fn msg ->
      role = String.upcase(msg[:role] || "")
      content = msg[:content] || ""
      tool_calls = msg[:tool_calls]

      content_str = cond do
        is_binary(content) -> content
        is_list(content) -> PiCore.Multimodal.to_text(content) <> " [+image]"
        true -> inspect(content)
      end

      if tool_calls && tool_calls != [] do
        tools = Enum.map_join(tool_calls, "\n", fn tc ->
          name = get_in(tc, ["function", "name"]) || "?"
          args = get_in(tc, ["function", "arguments"]) || "{}"
          "  → #{name}(#{String.slice(args, 0, 500)})"
        end)
        "[#{role}]\n#{content_str}\n#{tools}"
      else
        "[#{role}]\n#{content_str}"
      end
    end)

    Enum.join(parts ++ msg_parts, "\n\n")
  end

  defp supports_vision?(opts) do
    case opts[:model_info_fn] do
      nil -> true
      fn_ref -> fn_ref.(:supports_vision, opts[:model])
    end
  rescue
    _ -> true
  end

  defp strip_images(messages) do
    Enum.map(messages, fn msg ->
      content = msg[:content]
      if is_list(content) do
        stripped = Enum.map(content, fn
          %{"type" => "image_url"} -> %{"type" => "text", "text" => "[image — this model cannot view images]"}
          %{type: "image_url"} -> %{type: "text", text: "[image — this model cannot view images]"}
          block -> block
        end)
        %{msg | content: stripped}
      else
        msg
      end
    end)
  end
end
