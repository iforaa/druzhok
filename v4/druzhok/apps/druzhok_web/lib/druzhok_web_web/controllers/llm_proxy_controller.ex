defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmFormat
  alias Druzhok.{Budget, Usage}
  require Logger

  @default_image_model Druzhok.ModelCatalog.default_image_model()

  def chat_completions(conn, _params) do
    instance = conn.assigns.instance
    body = conn.body_params
    model = body["model"] || "default"
    stream = body["stream"] == true

    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        json_error(conn, 429, "Token budget exceeded", "insufficient_quota")

      {:ok, _remaining} ->
        url = LlmFormat.request_url()
        headers = LlmFormat.request_headers(conn.req_headers)
        body = LlmFormat.prepare_body(body)
        started_at = System.monotonic_time(:millisecond)

        if stream do
          stream_proxy(conn, instance, url, headers, body, model, started_at)
        else
          sync_proxy(conn, instance, url, headers, body, model, started_at)
        end
    end
  end

  defp sync_proxy(conn, instance, url, headers, body, model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        decoded = Jason.decode!(resp_body)
        usage = LlmFormat.extract_usage(decoded)
        response_preview = get_in(decoded, ["choices", Access.at(0), "message", "content"])
        meter(instance, usage, model, started_at, body, response_preview)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("LLM proxy error: #{inspect(reason)}")
        json_error(conn, 502, "Provider unavailable", "server_error")
    end
  end

  defp stream_proxy(conn, instance, url, headers, body, model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    conn = conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> send_chunked(200)

    usage_ref = make_ref()
    Process.put(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})

    result = Finch.stream(request, Druzhok.Finch, conn, fn
      {:status, _status}, conn -> conn
      {:headers, _resp_headers}, conn -> conn
      {:data, data}, conn ->
        for line <- String.split(data, "\n"), String.starts_with?(line, "data: ") do
          json_str = String.trim_leading(line, "data: ")
          if json_str != "[DONE]" do
            case Jason.decode(json_str) do
              {:ok, %{"usage" => usage}} when is_map(usage) ->
                Process.put(usage_ref, LlmFormat.extract_usage(%{"usage" => usage}))
              _ -> :ok
            end
          end
        end

        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} -> conn
          {:error, _} -> conn
        end
    end, receive_timeout: 120_000)

    usage = Process.get(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})
    meter(instance, usage, model, started_at, body, nil)

    case result do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp meter(instance, usage, model, started_at, request_body, response_preview) do
    total = usage.prompt_tokens + usage.completion_tokens
    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Budget.deduct(instance.id, total)

      prompt_preview = case request_body["messages"] do
        [_ | _] = msgs ->
          content = msgs |> List.last() |> Map.get("content", "")
          case content do
            text when is_binary(text) -> String.slice(text, 0, 500)
            parts when is_list(parts) ->
              parts
              |> Enum.filter(&(&1["type"] == "text"))
              |> Enum.map_join(" ", &(&1["text"] || ""))
              |> String.slice(0, 500)
            _ -> nil
          end
        _ -> nil
      end

      resp_preview = if response_preview, do: String.slice(response_preview, 0, 500), else: nil

      Usage.log(%{
        instance_id: instance.id,
        model: model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        request_type: "chat",
        requested_model: model,
        resolved_model: model,
        provider: "openrouter",
        latency_ms: latency,
        prompt_preview: prompt_preview,
        response_preview: resp_preview,
        request_body: Jason.encode!(request_body),
      })
    end
  end

  def audio_transcriptions(conn, _params) do
    openai_key = get_setting("openai_api_key")

    if is_nil(openai_key) do
      json_error(conn, 503, "Audio transcription not configured", "server_error")
    else
      instance = resolve_instance(conn)

      if instance do
        case Budget.check(instance.id) do
          {:error, :exceeded} ->
            json_error(conn, 429, "Token budget exceeded", "insufficient_quota")
          {:ok, _} ->
            do_audio_transcription(conn, openai_key, instance)
        end
      else
        do_audio_transcription(conn, openai_key, nil)
      end
    end
  end

  defp do_audio_transcription(conn, openai_key, instance) do
    started_at = System.monotonic_time(:millisecond)

    # Plug.Parsers already consumed the multipart body — rebuild it
    {multipart_body, content_type} = build_multipart(conn.body_params)

    url = "https://api.openai.com/v1/audio/transcriptions"
    headers = [
      {"authorization", "Bearer #{openai_key}"},
      {"content-type", content_type}
    ]

    request = Finch.build(:post, url, headers, multipart_body)

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        latency = System.monotonic_time(:millisecond) - started_at

        if status == 200 do
          Logger.info("[audio] transcription #{latency}ms")
          meter_audio(instance, resp_body, latency, conn.body_params["model"])
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("Audio transcription proxy error: #{inspect(reason)}")
        json_error(conn, 502, "Transcription provider unavailable", "server_error")
    end
  end

  defp meter_image(nil, _usage, _model, _started_at), do: :ok
  defp meter_image(instance, usage, image_model, started_at) do
    total = usage.prompt_tokens + usage.completion_tokens
    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Budget.deduct(instance.id, total)
      Usage.log(%{
        instance_id: instance.id,
        model: image_model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        request_type: "image",
        requested_model: image_model,
        resolved_model: image_model,
        provider: "openrouter",
        latency_ms: latency
      })
    end
  end

  defp meter_audio(nil, _resp_body, _latency, _model), do: :ok
  defp meter_audio(instance, resp_body, latency, requested_model) do
    duration_ms = case Jason.decode(resp_body) do
      {:ok, %{"duration" => d}} when is_number(d) -> round(d * 1000)
      _ -> nil
    end

    tokens_per_second = case get_setting("audio_tokens_per_second") do
      nil -> 10
      val -> String.to_integer(val)
    end

    equivalent_tokens = if duration_ms, do: div(duration_ms, 1000) * tokens_per_second, else: 0
    if equivalent_tokens > 0, do: Budget.deduct(instance.id, equivalent_tokens)

    Usage.log(%{
      instance_id: instance.id,
      model: requested_model || "whisper-1",
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: equivalent_tokens,
      request_type: "audio",
      audio_duration_ms: duration_ms,
      requested_model: requested_model || "whisper-1",
      resolved_model: "whisper-1",
      provider: "openai",
      latency_ms: latency
    })
  end

  defp build_multipart(params) do
    boundary = "----ElixirMultipart#{:rand.uniform(999_999_999)}"
    parts = Enum.map(params, fn
      {"file", %Plug.Upload{path: path, filename: filename, content_type: ct}} ->
        data = File.read!(path)
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\nContent-Type: #{ct}\r\n\r\n#{data}\r\n"
      {key, value} when is_binary(value) ->
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{key}\"\r\n\r\n#{value}\r\n"
      _ -> ""
    end)
    body = Enum.join(parts) <> "--#{boundary}--\r\n"
    {body, "multipart/form-data; boundary=#{boundary}"}
  end

  def embeddings(conn, _params) do
    body = conn.body_params
    instance = conn.assigns.instance
    started_at = System.monotonic_time(:millisecond)
    url = LlmFormat.provider_url() <> "/embeddings"
    headers = LlmFormat.request_headers(conn.req_headers)
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 60_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        if status == 200 do
          case Jason.decode(resp_body) do
            {:ok, %{"usage" => %{"total_tokens" => total} = u}} when is_integer(total) and total > 0 ->
              Usage.log(%{
                instance_id: instance.id,
                model: body["model"] || "unknown",
                prompt_tokens: u["prompt_tokens"] || total,
                completion_tokens: 0,
                total_tokens: total,
                request_type: "embedding",
                requested_model: body["model"],
                resolved_model: body["model"],
                provider: "openrouter",
                latency_ms: System.monotonic_time(:millisecond) - started_at
              })
            _ -> :ok
          end
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("Embeddings proxy error: #{inspect(reason)}")
        json_error(conn, 502, "Embeddings provider unavailable", "server_error")
    end
  end

  def responses_proxy(conn, _params) do
    # OpenAI Responses API → convert to chat/completions format for OpenRouter
    body = conn.body_params
    instance = resolve_instance(conn)
    image_model = if instance, do: instance.image_model || @default_image_model, else: @default_image_model

    if instance do
      case Budget.check(instance.id) do
        {:error, :exceeded} ->
          json_error(conn, 429, "Token budget exceeded", "insufficient_quota")
        {:ok, _} ->
          do_responses_proxy(conn, body, image_model, instance)
      end
    else
      do_responses_proxy(conn, body, image_model, nil)
    end
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

          if instance do
            case Jason.decode(trimmed) do
              {:ok, decoded} -> meter_image(instance, LlmFormat.extract_usage(decoded), image_model, started_at)
              _ -> :ok
            end
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

    %{"model" => model, "messages" => messages, "max_tokens" => body["max_output_tokens"] || 1024, "stream" => body["stream"] || false}
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
        # Parse streamed SSE chunks to extract full text and usage
        {text, usage} = raw_data
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&String.trim_leading(&1, "data: "))
        |> Enum.reject(&(&1 == "[DONE]"))
        |> Enum.reduce({"", %{prompt_tokens: 0, completion_tokens: 0}}, fn json_str, {text_acc, usage_acc} ->
          case Jason.decode(json_str) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]} = chunk} when is_binary(content) ->
              new_usage = case chunk do
                %{"usage" => u} when is_map(u) -> LlmFormat.extract_usage(%{"usage" => u})
                _ -> usage_acc
              end
              {text_acc <> content, new_usage}
            {:ok, %{"usage" => u}} when is_map(u) ->
              {text_acc, LlmFormat.extract_usage(%{"usage" => u})}
            _ -> {text_acc, usage_acc}
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

        for event <- events do
          Plug.Conn.chunk(conn, "data: #{Jason.encode!(event)}\n\n")
        end

        meter_image(instance, usage, image_model, started_at)
        conn

      {:error, reason} ->
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

  defp get_setting(key) do
    import Ecto.Query
    Druzhok.Repo.one(from s in "settings", where: s.key == ^key, select: s.value)
  end

  defp resolve_instance(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        Druzhok.Repo.get_by(Druzhok.Instance, tenant_key: token)
      _ -> nil
    end
  end

  defp json_error(conn, status, message, type) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{message: message, type: type}}))
  end
end
