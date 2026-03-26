defmodule PiCore.LLM.OpenAI do
  alias PiCore.LLM.SSEParser
  alias PiCore.LLM.Client.Result
  alias PiCore.LLM.ToolCallAssembler

  defmodule Request do
    defstruct [:url, :headers, :body]
  end

  def build_request(opts) do
    messages = [%{role: "system", content: opts.system_prompt} | opts.messages]

    body = %{model: opts.model, messages: messages, max_tokens: opts.max_tokens, stream: opts.stream}
    body = if opts.stream, do: Map.put(body, :stream_options, %{include_usage: true}), else: body
    body = if opts.tools != [], do: Map.put(body, :tools, opts.tools), else: body

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{opts.api_key}"},
      {"accept-encoding", "identity"}
    ]

    headers = if opts[:provider] in [:openrouter, "openrouter"] do
      headers ++ [{"HTTP-Referer", "https://druzhok.app"}, {"X-Title", "Druzhok"}]
    else
      headers
    end

    %Request{
      url: "#{String.trim_trailing(opts.api_url, "/")}/chat/completions",
      headers: headers,
      body: Jason.encode!(body)
    }
  end

  def completion(opts) do
    request = build_request(opts)
    if opts.stream do
      stream_completion(request, opts[:on_delta], opts[:on_event])
    else
      sync_completion(request)
    end
  end

  defp stream_completion(request, on_delta, on_event) do
    req = Finch.build(:post, request.url, request.headers, request.body)
    try do
      Finch.stream(req, PiCore.Finch, {%Result{}, "", false, ToolCallAssembler.new()}, fn
        {:status, status}, acc when status in 200..299 ->
          acc

        {:status, status}, _acc ->
          throw({:http_error, status})

        {:headers, _}, acc -> acc

        {:data, data}, {result, buffer, token_sent, tc_asm} ->
          {events, new_buffer} = SSEParser.parse(data, buffer)
          {new_result, token_sent, tc_asm} = Enum.reduce(events, {result, token_sent, tc_asm}, fn
            :done, acc -> acc
            event, {acc, sent, asm} ->
              {new_acc, asm} = process_stream_event(event, acc, asm, on_delta)
              sent = if !sent && new_acc.content != "" do
                if on_event, do: on_event.(%{type: :llm_first_token})
                true
              else
                sent
              end
              {new_acc, sent, asm}
          end)
          {new_result, new_buffer, token_sent, tc_asm}
      end)
      |> case do
        {:ok, {result, _, _, tc_asm}} ->
          tool_calls = ToolCallAssembler.finalize(tc_asm)
          result = if tool_calls != [], do: %{result | tool_calls: tool_calls}, else: result
          {:ok, result}
        {:error, reason} -> {:error, reason}
        {:error, reason, _acc} -> {:error, reason}
      end
    catch
      {:http_error, status} -> {:error, "HTTP error: #{status}"}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp process_stream_event(event, result, tc_asm, on_delta) do
    # Parse usage from final chunk
    result = case event["usage"] do
      %{"prompt_tokens" => input, "completion_tokens" => output} ->
        %{result | input_tokens: input, output_tokens: output}
      _ -> result
    end

    choices = event["choices"] || []

    Enum.reduce(choices, {result, tc_asm}, fn choice, {acc, asm} ->
      delta = choice["delta"] || %{}
      message = choice["message"]

      # Text content from delta
      acc = if delta["content"] && delta["content"] != "" do
        if on_delta, do: on_delta.(delta["content"])
        %{acc | content: acc.content <> delta["content"]}
      else
        acc
      end

      # Reasoning content from delta
      acc = if delta["reasoning_content"] && delta["reasoning_content"] != "" do
        %{acc | reasoning: acc.reasoning <> delta["reasoning_content"]}
      else
        acc
      end

      # Tool calls from delta (streaming assembly)
      asm = if delta["tool_calls"] do
        Enum.reduce(delta["tool_calls"], asm, fn call, a ->
          index = call["index"] || 0
          a = if call["id"] do
            ToolCallAssembler.start_call(a, index, call["id"], get_in(call, ["function", "name"]) || "")
          else
            a
          end
          args_fragment = get_in(call, ["function", "arguments"]) || ""
          if args_fragment != "", do: ToolCallAssembler.append_args(a, index, args_fragment), else: a
        end)
      else
        asm
      end

      # Non-streaming message (some events include full message)
      acc = if message do
        acc = if message["content"], do: %{acc | content: message["content"]}, else: acc
        acc = if message["tool_calls"], do: %{acc | tool_calls: message["tool_calls"]}, else: acc
        acc
      else
        acc
      end

      {acc, asm}
    end)
  end

  defp sync_completion(request) do
    case Finch.build(:post, request.url, request.headers, request.body)
         |> Finch.request(PiCore.Finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        data = Jason.decode!(body)
        choice = hd(data["choices"])
        message = choice["message"]
        usage = data["usage"] || %{}
        {:ok, %Result{
          content: message["content"] || "",
          tool_calls: message["tool_calls"] || [],
          reasoning: message["reasoning_content"] || "",
          input_tokens: usage["prompt_tokens"] || 0,
          output_tokens: usage["completion_tokens"] || 0
        }}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
