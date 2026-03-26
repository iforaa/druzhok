defmodule PiCore.LLM.Anthropic do
  @moduledoc """
  Anthropic Messages API client. Streams via SSE, returns Client.Result.
  """
  alias PiCore.LLM.Client.Result
  alias PiCore.LLM.ToolCallAssembler


  def completion(opts) do
    url = String.trim_trailing(opts.api_url || "https://api.anthropic.com", "/") <> "/v1/messages"

    # Anthropic: system is top-level, not a message
    messages = convert_messages(opts.messages)
    tools = convert_tools(opts.tools || [])

    body = %{
      model: opts.model,
      max_tokens: opts[:max_tokens] || PiCore.Config.default_max_tokens(),
      system: opts.system_prompt || "",
      messages: messages,
      stream: opts[:stream] || false,
    }
    body = if tools != [], do: Map.put(body, :tools, tools), else: body

    headers = [
      {"content-type", "application/json"},
      {"x-api-key", opts.api_key},
      {"anthropic-version", PiCore.Config.anthropic_api_version()},
      {"accept-encoding", "identity"}
    ]

    if opts[:stream] do
      stream_completion(url, headers, body, opts[:on_delta], opts[:on_event])
    else
      sync_completion(url, headers, body)
    end
  end

  # --- Streaming ---

  defp stream_completion(url, headers, body, on_delta, on_event) do
    req = Finch.build(:post, url, headers, Jason.encode!(body))

    try do
      Finch.stream(req, PiCore.Finch, {%Result{}, "", false, ToolCallAssembler.new()}, fn
        {:status, status}, acc when status in 200..299 -> acc
        {:status, status}, _acc -> throw({:http_error, status})
        {:headers, _}, acc -> acc

        {:data, data}, {result, buffer, token_sent, tc_asm} ->
          full = buffer <> data
          {lines, rest} = split_sse(full)

          {result, token_sent, tc_asm} =
            Enum.reduce(lines, {result, token_sent, tc_asm}, fn line, {r, ts, asm} ->
              process_sse_line(line, r, ts, asm, on_delta, on_event)
            end)

          {result, rest, token_sent, tc_asm}
      end)
      |> case do
        {:ok, acc} -> {:ok, finalize_stream_result(acc)}
        {:error, reason} -> {:error, reason}
        {:error, reason, _acc} -> {:error, reason}
      end
    catch
      {:http_error, status} -> {:error, "HTTP error: #{status}"}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp split_sse(data) do
    parts = String.split(data, "\n")
    {complete, rest} = case List.last(parts) do
      "" -> {Enum.slice(parts, 0..-2//1), ""}
      partial -> {Enum.slice(parts, 0..-2//1), partial}
    end
    lines = Enum.reject(complete, &(&1 == "" || &1 == "\n"))
    {lines, rest}
  end

  defp process_sse_line("data: " <> json_str, result, token_sent, tc_asm, on_delta, on_event) do
    case Jason.decode(json_str) do
      {:ok, event} -> handle_event(event, result, token_sent, tc_asm, on_delta, on_event)
      _ -> {result, token_sent, tc_asm}
    end
  end
  defp process_sse_line(_, result, token_sent, tc_asm, _on_delta, _on_event) do
    {result, token_sent, tc_asm}
  end

  defp handle_event(%{"type" => "content_block_delta", "delta" => delta}, result, token_sent, tc_asm, on_delta, on_event) do
    case delta do
      %{"type" => "text_delta", "text" => text} ->
        if on_delta && text != "", do: on_delta.(text)
        token_sent = if !token_sent && text != "" do
          if on_event, do: on_event.(%{type: :llm_first_token})
          true
        else
          token_sent
        end
        {%{result | content: result.content <> text}, token_sent, tc_asm}

      %{"type" => "thinking_delta", "thinking" => text} ->
        {%{result | reasoning: result.reasoning <> text}, token_sent, tc_asm}

      %{"type" => "input_json_delta", "partial_json" => json_chunk} ->
        # Append to the last started tool call (Anthropic streams one at a time)
        last_index = length(tc_asm.calls) - 1
        tc_asm = if last_index >= 0, do: ToolCallAssembler.append_args(tc_asm, last_index, json_chunk), else: tc_asm
        {result, token_sent, tc_asm}

      _ ->
        {result, token_sent, tc_asm}
    end
  end

  defp handle_event(%{"type" => "content_block_start", "content_block" => block}, result, token_sent, tc_asm, _on_delta, _on_event) do
    case block do
      %{"type" => "tool_use", "id" => id, "name" => name} ->
        index = length(tc_asm.calls)
        tc_asm = ToolCallAssembler.start_call(tc_asm, index, id, name)
        {result, token_sent, tc_asm}
      _ ->
        {result, token_sent, tc_asm}
    end
  end

  defp handle_event(%{"type" => "message_start", "message" => msg}, result, token_sent, tc_asm, _on_delta, _on_event) do
    input_tokens = get_in(msg, ["usage", "input_tokens"]) || 0
    {%{result | input_tokens: input_tokens}, token_sent, tc_asm}
  end

  defp handle_event(%{"type" => "message_delta", "usage" => usage}, result, token_sent, tc_asm, _on_delta, _on_event) do
    output_tokens = usage["output_tokens"] || 0
    {%{result | output_tokens: output_tokens}, token_sent, tc_asm}
  end

  defp handle_event(_event, result, token_sent, tc_asm, _on_delta, _on_event) do
    {result, token_sent, tc_asm}
  end

  defp finalize_stream_result({result, _, _, tc_asm}) do
    tool_calls = ToolCallAssembler.finalize(tc_asm)

    if tool_calls != [] do
      %{result | tool_calls: tool_calls}
    else
      result
    end
  end

  # --- Sync ---

  defp sync_completion(url, headers, body) do
    case Finch.build(:post, url, headers, Jason.encode!(body))
         |> Finch.request(PiCore.Finch) do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        data = Jason.decode!(resp)
        {:ok, parse_response(data)}

      {:ok, %{status: status, body: resp}} ->
        {:error, "HTTP #{status}: #{resp}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(%{"content" => content} = data) do
    usage = data["usage"] || %{}

    {text, tool_calls, reasoning} =
      Enum.reduce(content, {"", [], ""}, fn block, {txt, tcs, reason} ->
        case block do
          %{"type" => "text", "text" => t} -> {txt <> t, tcs, reason}
          %{"type" => "thinking", "thinking" => t} -> {txt, tcs, reason <> t}
          %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} ->
            tc = %{
              "id" => id,
              "type" => "function",
              "function" => %{"name" => name, "arguments" => Jason.encode!(input)}
            }
            {txt, tcs ++ [tc], reason}
          _ -> {txt, tcs, reason}
        end
      end)

    %Result{
      content: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0
    }
  end

  # --- Message conversion ---

  # Convert OpenAI-format messages to Anthropic format
  defp convert_messages(messages) do
    messages
    |> Enum.reject(fn m -> m[:role] == "system" || m["role"] == "system" end)
    |> Enum.map(&convert_message/1)
  end

  defp convert_message(%{role: "tool"} = m) do
    %{
      role: "user",
      content: [%{
        type: "tool_result",
        tool_use_id: m[:tool_call_id] || m["tool_call_id"],
        content: m[:content] || m["content"] || ""
      }]
    }
  end
  defp convert_message(m) do
    role = m[:role] || m["role"]
    content = m[:content] || m["content"] || ""
    tool_calls = m[:tool_calls] || m["tool_calls"]

    if tool_calls && tool_calls != [] do
      blocks = if is_binary(content) && content != "", do: [%{type: "text", text: content}], else: []
      blocks = blocks ++ Enum.map(tool_calls, fn tc ->
        args = get_in(tc, ["function", "arguments"]) || "{}"
        %{
          type: "tool_use",
          id: tc["id"],
          name: get_in(tc, ["function", "name"]),
          input: case Jason.decode(args) do
            {:ok, parsed} -> parsed
            _ -> %{}
          end
        }
      end)
      %{role: role, content: blocks}
    else
      if PiCore.Multimodal.is_multimodal?(content) do
        %{role: role, content: PiCore.Multimodal.to_anthropic_content(content)}
      else
        %{role: role, content: content}
      end
    end
  end

  # Convert OpenAI-format tool definitions to Anthropic format
  defp convert_tools(tools) do
    Enum.map(tools, fn tool ->
      func = tool["function"] || tool
      %{
        name: func["name"],
        description: func["description"] || "",
        input_schema: func["parameters"] || %{"type" => "object", "properties" => %{}}
      }
    end)
  end
end
