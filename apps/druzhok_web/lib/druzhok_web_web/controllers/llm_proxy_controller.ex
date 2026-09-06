defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmFormat
  alias DruzhokWebWeb.LlmProxy.Ruoc, as: RuocProxy
  alias Druzhok.Usage
  require Logger

  # Legacy-path vision default for /v1/responses; migrated bots set image_model.
  @default_image_model "google/gemini-2.5-flash-lite"

  # Chat, search, transcription and image generation are served by
  # ruoc-gateway with the bot's own account (`LlmProxy.Ruoc`). LlmAuth
  # guarantees `ruoc_api_key` is set. Embeddings, TTS and /v1/responses still
  # go to OpenRouter/OpenAI directly, unmetered for money, until ruoc sells them.
  def chat_completions(conn, _params), do: RuocProxy.chat(conn, conn.assigns.instance)
  def images_generations(conn, _params), do: RuocProxy.generate_image(conn, conn.assigns.instance)

  defp chunk_sse(conn, payload), do: chunk_raw(conn, "data: #{Jason.encode!(payload)}\n\n")

  # Thread the conn through so test adapters (and anything else that records
  # chunks on the struct) see every chunk; a closed client is not an error.
  defp chunk_raw(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  def audio_transcriptions(conn, _params), do: RuocProxy.transcribe(conn, conn.assigns.instance)

  def audio_speech(conn, _params) do
    openai_key = Druzhok.Settings.get("openai_api_key")

    if is_nil(openai_key) do
      json_error(conn, 503, "Text-to-speech not configured", "server_error")
    else
      do_audio_speech(conn, openai_key, conn.assigns.instance)
    end
  end

  defp do_audio_speech(conn, openai_key, instance) do
    started_at = System.monotonic_time(:millisecond)
    body = conn.body_params

    url = openai_api_url() <> "/audio/speech"

    headers = [
      {"authorization", "Bearer #{openai_key}"},
      {"content-type", "application/json"}
    ]

    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: 200, body: audio, headers: resp_headers}} ->
        latency = System.monotonic_time(:millisecond) - started_at
        meter_tts(instance, body, latency)

        content_type =
          Enum.find_value(resp_headers, "audio/mpeg", fn
            {"content-type", v} -> v
            _ -> nil
          end)

        conn
        |> put_resp_content_type(content_type)
        |> send_resp(200, audio)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("TTS proxy error: #{inspect(reason)}")
        json_error(conn, 502, "TTS provider unavailable", "server_error")
    end
  end

  defp meter_tts(nil, _body, _latency), do: :ok

  defp meter_tts(instance, body, latency) do
    input = body["input"] || ""
    chars = String.length(input)
    # OpenAI gpt-4o-mini-tts: $0.60 / 1M input characters → 0.00006 cents/char.
    cost_cents = round(chars * 0.00006)

    Usage.log(%{
      instance_id: instance.id,
      model: body["model"] || "gpt-4o-mini-tts",
      prompt_tokens: chars,
      completion_tokens: 0,
      total_tokens: chars,
      cost_cents: cost_cents,
      request_type: "tts",
      requested_model: body["model"],
      resolved_model: body["model"] || "gpt-4o-mini-tts",
      provider: "openai",
      latency_ms: latency,
      prompt_preview: String.slice(input, 0, 500)
    })
  end

  def firecrawl_search(conn, _params) do
    body = conn.body_params
    query = body["query"] || ""
    limit = Map.get(body, "limit", 5) |> normalize_limit()

    if query == "" do
      send_resp(conn, 400, Jason.encode!(%{success: false, error: "query is required"}))
    else
      RuocProxy.search(conn, conn.assigns.instance, query, limit)
    end
  end

  # hermes web_extract: Firecrawl `/v2/scrape {url, formats}`. Only markdown
  # is served, whatever `formats` asks; the page comes from ruoc `/v1/fetch`.
  def firecrawl_scrape(conn, _params) do
    url = conn.body_params["url"]

    if is_binary(url) and String.trim(url) != "" do
      RuocProxy.fetch(conn, conn.assigns.instance, String.trim(url))
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(400, Jason.encode!(%{success: false, error: "url is required"}))
    end
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0 and limit <= 20, do: limit
  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {n, _} when n > 0 and n <= 20 -> n
      _ -> 5
    end
  end
  defp normalize_limit(_), do: 5

  defp meter_image(nil, _usage, _model, _started_at, _cost_cents), do: :ok
  defp meter_image(instance, usage, image_model, started_at, cost_cents) do
    total = usage.prompt_tokens + usage.completion_tokens
    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Usage.log(%{
        instance_id: instance.id,
        model: image_model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        cost_cents: cost_cents,
        request_type: "image",
        requested_model: image_model,
        resolved_model: image_model,
        provider: "openrouter",
        latency_ms: latency
      })
    end
  end

  def embeddings(conn, _params), do: RuocProxy.embeddings(conn, conn.assigns.instance)

  def responses_proxy(conn, _params) do
    # OpenAI Responses API → convert to chat/completions format for OpenRouter
    body = conn.body_params
    instance = conn.assigns.instance
    image_model = instance.image_model || @default_image_model
    do_responses_proxy(conn, body, image_model, instance)
  end

  defp do_responses_proxy(conn, body, image_model, instance) do
    started_at = System.monotonic_time(:millisecond)
    chat_body = convert_responses_to_chat(body, image_model)
    url = LlmFormat.request_url()
    headers = LlmFormat.request_headers(conn.req_headers)

    request = Finch.build(:post, url, headers, Jason.encode!(chat_body))

    # Log request details for debugging
    msg_summary = Enum.map(chat_body["messages"], fn msg ->
      content = msg["content"]
      cond do
        is_binary(content) -> "#{msg["role"]}:text(#{String.length(content)})"
        is_list(content) -> "#{msg["role"]}:parts(#{length(content)})[#{Enum.map(content, & &1["type"]) |> Enum.join(",")}]"
        true -> "#{msg["role"]}:?"
      end
    end) |> Enum.join(" ")
    Logger.info("[responses] model=#{chat_body["model"]} #{msg_summary}")

    if chat_body["stream"] do
      stream_responses_proxy(conn, request, image_model, instance, started_at)
    else
      case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          trimmed = String.trim(resp_body)
          Logger.info("[responses] status=#{status} body=#{String.slice(trimmed, 0, 300)}")
          resp_body = convert_chat_to_responses(resp_body, body["model"])

          case Jason.decode(trimmed) do
            {:ok, decoded} ->
              cost_cents = LlmFormat.extract_cost_cents(decoded, image_model)
              meter_image(instance, LlmFormat.extract_usage(decoded), image_model, started_at, cost_cents)

            _ ->
              :ok
          end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, resp_body)

        {:error, reason} ->
          Logger.error("Responses proxy error: #{inspect(reason)}")
          json_error(conn, 502, "Provider unavailable", "server_error")
      end
    end
  end

  defp convert_responses_to_chat(body, model) do
    input = body["input"] || []

    messages = Enum.map(List.wrap(input), fn
      %{"role" => "developer", "content" => content} ->
        %{"role" => "system", "content" => content}
      %{"role" => role, "content" => content} when is_list(content) ->
        %{"role" => role, "content" => convert_content_parts(content)}
      %{"role" => role, "content" => content} when is_binary(content) ->
        %{"role" => role, "content" => content}
      item when is_binary(item) ->
        %{"role" => "user", "content" => item}
      other ->
        %{"role" => "user", "content" => inspect(other)}
    end)

    messages = if messages == [], do: [%{"role" => "user", "content" => "Describe this image."}], else: messages

    %{
      "model" => model,
      "messages" => messages,
      "max_tokens" => body["max_output_tokens"] || 1024,
      "stream" => body["stream"] || false,
      "usage" => %{"include" => true}
    }
  end

  defp stream_responses_proxy(conn, request, image_model, instance, started_at) do
    conn = conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)

    # Collect full streamed response, then send as Responses API events
    result = Finch.stream(request, Druzhok.Finch, "", fn
      {:status, _status}, acc -> acc
      {:headers, _headers}, acc -> acc
      {:data, data}, acc -> acc <> data
    end, receive_timeout: 120_000)

    case result do
      {:ok, raw_data} ->
        # Parse streamed SSE chunks to extract full text, usage, and cost
        {text, usage, cost_cents} = raw_data
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&String.trim_leading(&1, "data: "))
        |> Enum.reject(&(&1 == "[DONE]"))
        |> Enum.reduce({"", %{prompt_tokens: 0, completion_tokens: 0}, 0}, fn json_str, {text_acc, usage_acc, cost_acc} ->
          case Jason.decode(json_str) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]} = chunk} when is_binary(content) ->
              {new_usage, new_cost} = case chunk do
                %{"usage" => u} when is_map(u) ->
                  {LlmFormat.extract_usage(%{"usage" => u}), LlmFormat.extract_cost_cents(chunk, image_model)}
                _ ->
                  {usage_acc, cost_acc}
              end
              {text_acc <> content, new_usage, new_cost}
            {:ok, %{"usage" => u} = chunk} when is_map(u) ->
              {text_acc, LlmFormat.extract_usage(%{"usage" => u}), LlmFormat.extract_cost_cents(chunk, image_model)}
            _ -> {text_acc, usage_acc, cost_acc}
          end
        end)

        Logger.info("[responses] streamed text=#{String.slice(text, 0, 100)}")

        # Send full Responses API SSE event sequence
        output_item = %{
          "type" => "message",
          "id" => "msg_proxy",
          "status" => "completed",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => text}]
        }

        events = [
          %{"type" => "response.output_item.added", "output_index" => 0, "item" => output_item},
          %{"type" => "response.output_text.delta", "output_index" => 0, "content_index" => 0, "delta" => text},
          %{"type" => "response.output_text.done", "output_index" => 0, "content_index" => 0, "text" => text},
          %{"type" => "response.output_item.done", "output_index" => 0, "item" => output_item},
          %{"type" => "response.completed", "response" => %{
            "id" => "resp_proxy",
            "object" => "response",
            "status" => "completed",
            "output" => [output_item],
            "model" => image_model,
            "usage" => %{"input_tokens" => usage.prompt_tokens, "output_tokens" => usage.completion_tokens}
          }}
        ]

        conn = Enum.reduce(events, conn, &chunk_sse(&2, &1))
        meter_image(instance, usage, image_model, started_at, cost_cents)
        conn

      {:error, reason, _partial} ->
        Logger.error("Responses stream error: #{inspect(reason)}")
        conn
    end
  end

  defp convert_content_parts(parts) when is_list(parts) do
    Enum.map(parts, fn
      %{"type" => "input_image", "image_url" => url} = part ->
        detail = Map.get(part, "detail")
        img = %{"url" => url}
        img = if detail, do: Map.put(img, "detail", detail), else: img
        %{"type" => "image_url", "image_url" => img}
      other -> other
    end)
  end

  defp convert_chat_to_responses(resp_body, model) do
    case Jason.decode(String.trim(resp_body)) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]} = resp} ->
        usage = resp["usage"] || %{}
        Jason.encode!(%{
          "id" => "resp_proxy",
          "object" => "response",
          "status" => "completed",
          "output" => [%{
            "type" => "message",
            "id" => "msg_proxy",
            "status" => "completed",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => content || ""}]
          }],
          "model" => model,
          "usage" => %{
            "input_tokens" => usage["prompt_tokens"] || 0,
            "output_tokens" => usage["completion_tokens"] || 0
          }
        })
      _ ->
        resp_body
    end
  end

  # Overridable so tests can point TTS at a local stub.
  defp openai_api_url do
    Application.get_env(:druzhok, :openai_api_url) || "https://api.openai.com/v1"
  end

  defp json_error(conn, status, message, type) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{message: message, type: type}}))
  end
end
