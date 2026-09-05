defmodule DruzhokWebWeb.UpstreamStub do
  @moduledoc """
  Builders for the JSON and SSE bodies a fake OpenRouter returns in proxy
  tests. Shapes copied from real OpenRouter responses so the controller's
  parsing is exercised against what production actually sees.
  """

  @default_usage %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => 0.02}
  @default_model "z-ai/glm-5.3-flash"

  @doc "A non-streaming chat completion body (a map, not encoded)."
  def chat_completion(content, opts \\ []) do
    usage = Keyword.get(opts, :usage, @default_usage)
    model = Keyword.get(opts, :model, @default_model)
    tool_calls = Keyword.get(opts, :tool_calls)

    message =
      if tool_calls,
        do: %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls},
        else: %{"role" => "assistant", "content" => content}

    %{
      "id" => "gen-test-1",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
      "usage" => usage
    }
  end

  @doc """
  SSE lines for a streamed completion: one chunk per delta, then a usage
  chunk (unless `usage: nil`), then `[DONE]`. Each element is a full
  `"data: ...\\n\\n"` string.
  """
  def sse_stream(deltas, opts \\ []) do
    usage = Keyword.get(opts, :usage, @default_usage)
    model = Keyword.get(opts, :model, @default_model)

    content_chunks =
      Enum.map(deltas, fn text ->
        chunk(%{
          "id" => "gen-test-1",
          "object" => "chat.completion.chunk",
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
        })
      end)

    final =
      chunk(%{
        "id" => "gen-test-1",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      })

    usage_chunk =
      if usage,
        do: [
          chunk(%{
            "id" => "gen-test-1",
            "object" => "chat.completion.chunk",
            "model" => model,
            "choices" => [],
            "usage" => usage
          })
        ],
        else: []

    content_chunks ++ [final] ++ usage_chunk ++ ["data: [DONE]\n\n"]
  end

  @doc "Send a list of SSE lines as a chunked text/event-stream response from a Bypass handler."
  def send_sse(conn, lines) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(lines, conn, fn line, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, line)
      conn
    end)
  end

  @doc "Decoded `data:` payloads of an SSE body, in order (`[DONE]` kept as a string)."
  def sse_payloads(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.trim_leading(&1, "data: "))
  end

  defp chunk(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
end
