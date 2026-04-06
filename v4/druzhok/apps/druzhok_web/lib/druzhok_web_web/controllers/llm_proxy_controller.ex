defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmFormat
  alias Druzhok.{Budget, Usage}
  require Logger

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
          end

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, resp_body)

        {:error, reason} ->
          Logger.error("Audio transcription proxy error: #{inspect(reason)}")
          json_error(conn, 502, "Transcription provider unavailable", "server_error")
      end
    end
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
    url = LlmFormat.provider_url() <> "/embeddings"
    headers = LlmFormat.request_headers(conn.req_headers)

    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 60_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
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
    chat_body = convert_responses_to_chat(body)
    url = LlmFormat.request_url()
    headers = LlmFormat.request_headers(conn.req_headers)

    request = Finch.build(:post, url, headers, Jason.encode!(chat_body))

    Logger.info("[responses] model=#{chat_body["model"]} messages=#{length(chat_body["messages"])}")

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.info("[responses] status=#{status} body=#{String.slice(resp_body, 0, 300)}")
        resp_body = convert_chat_to_responses(resp_body, body["model"])
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("Responses proxy error: #{inspect(reason)}")
        json_error(conn, 502, "Provider unavailable", "server_error")
    end
  end

  defp convert_responses_to_chat(body) do
    model = body["model"] || "openai/gpt-4o-mini"
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

    %{"model" => model, "messages" => messages, "max_tokens" => body["max_output_tokens"] || 1024, "stream" => false}
  end

  defp convert_content_parts(parts) when is_list(parts) do
    Enum.map(parts, fn
      %{"type" => "input_image", "image_url" => url} ->
        %{"type" => "image_url", "image_url" => %{"url" => url}}
      %{"type" => "input_image", "image_url" => url, "detail" => detail} ->
        %{"type" => "image_url", "image_url" => %{"url" => url, "detail" => detail}}
      other -> other
    end)
  end

  defp convert_chat_to_responses(resp_body, model) do
    case Jason.decode(resp_body) do
      {:ok, %{"choices" => [%{"message" => %{"content" => content}} | _]}} ->
        Jason.encode!(%{
          "id" => "resp_proxy",
          "output" => [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => content}]}],
          "model" => model,
          "usage" => %{"input_tokens" => 0, "output_tokens" => 0}
        })
      _ ->
        resp_body
    end
  end

  defp get_setting(key) do
    import Ecto.Query
    Druzhok.Repo.one(from s in "settings", where: s.key == ^key, select: s.value)
  end

  defp json_error(conn, status, message, type) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{message: message, type: type}}))
  end
end
