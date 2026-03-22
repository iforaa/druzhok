defmodule PiCore.LLM.Client do
  alias PiCore.LLM.SSEParser

  defmodule Request do
    defstruct [:url, :headers, :body]
  end

  defmodule Result do
    defstruct content: "", tool_calls: [], reasoning: ""
  end

  def build_request(opts) do
    messages = [%{role: "system", content: opts.system_prompt} | opts.messages]

    body = %{model: opts.model, messages: messages, max_tokens: opts.max_tokens, stream: opts.stream}
    body = if opts.tools != [], do: Map.put(body, :tools, opts.tools), else: body

    %Request{
      url: "#{String.trim_trailing(opts.api_url, "/")}/chat/completions",
      headers: [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{opts.api_key}"},
        {"accept-encoding", "identity"}
      ],
      body: Jason.encode!(body)
    }
  end

  def completion(opts) do
    request = build_request(opts)
    if opts.stream, do: stream_completion(request, opts[:on_delta]), else: sync_completion(request)
  end

  defp stream_completion(request, on_delta) do
    req = Finch.build(:post, request.url, request.headers, request.body)

    try do
      Finch.stream(req, PiCore.Finch, {%Result{}, ""}, fn
        {:status, status}, {result, buffer} when status in 200..299 ->
          {result, buffer}

        {:status, status}, {_result, buffer} ->
          {%Result{content: "HTTP error: #{status}"}, buffer}

        {:headers, _}, acc -> acc

        {:data, data}, {result, buffer} ->
          {events, new_buffer} = SSEParser.parse(data, buffer)
          new_result = Enum.reduce(events, result, fn
            :done, acc -> acc
            event, acc -> process_stream_event(event, acc, on_delta)
          end)
          {new_result, new_buffer}
      end)
      |> case do
        {:ok, {result, _}} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp process_stream_event(event, result, on_delta) do
    choices = event["choices"] || []

    Enum.reduce(choices, result, fn choice, acc ->
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
      acc = if delta["tool_calls"], do: merge_tool_calls(acc, delta["tool_calls"]), else: acc

      # Non-streaming message (some events include full message)
      acc = if message do
        acc = if message["content"], do: %{acc | content: message["content"]}, else: acc
        acc = if message["tool_calls"], do: %{acc | tool_calls: message["tool_calls"]}, else: acc
        acc
      else
        acc
      end

      acc
    end)
  end

  defp merge_tool_calls(result, incoming_calls) do
    Enum.reduce(incoming_calls, result, fn call, acc ->
      index = call["index"] || 0
      existing = Enum.at(acc.tool_calls, index)

      if existing do
        updated = update_in(existing, ["function", "arguments"], fn args ->
          (args || "") <> (get_in(call, ["function", "arguments"]) || "")
        end)
        %{acc | tool_calls: List.replace_at(acc.tool_calls, index, updated)}
      else
        new_call = %{
          "id" => call["id"],
          "type" => "function",
          "function" => %{
            "name" => get_in(call, ["function", "name"]) || "",
            "arguments" => get_in(call, ["function", "arguments"]) || ""
          }
        }
        %{acc | tool_calls: acc.tool_calls ++ [new_call]}
      end
    end)
  end

  defp sync_completion(request) do
    case Finch.build(:post, request.url, request.headers, request.body)
         |> Finch.request(PiCore.Finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        data = Jason.decode!(body)
        choice = hd(data["choices"])
        message = choice["message"]
        {:ok, %Result{
          content: message["content"] || "",
          tool_calls: message["tool_calls"] || [],
          reasoning: message["reasoning_content"] || ""
        }}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
