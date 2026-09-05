defmodule DruzhokWebWeb.LlmProxy.Ruoc do
  @moduledoc """
  The ruoc-gateway path of the LLM proxy: chat, web search and transcription
  for a bot that has a `ruoc_api_key`.

  Money lives in ruoc-gateway. Nothing here checks a budget or computes a
  cost; a 402 from the gateway is relayed to the bot as the answer. What
  stays on this side is the two dialects hermes speaks that the gateway does
  not — Firecrawl-shaped search and OpenAI multipart audio — and the request
  previews the dashboard shows.

  Every response carries the gateway's `X-Ruoc-Request-Id`, and every call
  logs it with the bot name, so a disputed charge is traceable in the ruoc
  console.
  """

  import Plug.Conn
  require Logger

  alias Druzhok.Ruoc
  alias Druzhok.Ruoc.Client
  alias Druzhok.Usage
  alias DruzhokWebWeb.LlmFormat

  @request_id_header "x-ruoc-request-id"
  @search_max_results 10
  @no_usage %{prompt_tokens: 0, completion_tokens: 0}

  # --- Chat -------------------------------------------------------------------

  def chat(conn, instance) do
    body = prepare_chat_body(conn.body_params)
    model = body["model"] || instance.model
    started_at = System.monotonic_time(:millisecond)

    if body["stream"] == true,
      do: stream_chat(conn, instance, body, model, started_at),
      else: sync_chat(conn, instance, body, model, started_at)
  end

  # Only image stripping survives from the OpenRouter path: the gateway
  # forwards the body verbatim, and the reasoning/mimo workarounds were for
  # models the ruoc catalog does not carry.
  defp prepare_chat_body(body) do
    case Ruoc.find_model(body["model"] || "") do
      %{capabilities: %{"attachment" => true}} -> body
      _ -> Map.update(body, "messages", [], &LlmFormat.strip_images/1)
    end
  end

  defp sync_chat(conn, instance, body, model, started_at) do
    case Client.post("/v1/chat/completions", instance.ruoc_api_key, Jason.encode!(body)) do
      {:ok, status, headers, resp_body} ->
        request_id = request_id(headers)

        if status == 200 do
          decoded = Jason.decode!(resp_body)
          preview = get_in(decoded, ["choices", Access.at(0), "message", "content"])
          meter(instance, "chat", model, LlmFormat.extract_usage(decoded), started_at, body, preview, request_id)
        else
          log(instance, "chat", request_id, started_at, "HTTP #{status}")
        end

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("[ruoc] #{instance.name} chat unreachable: #{inspect(reason)}")
        json_error(conn, 502, "ruoc-gateway unavailable", "api_error")
    end
  end

  # The response is only committed once the gateway's status is known, so a
  # 402 or 429 on a streaming request reaches the bot as that status with the
  # gateway's own envelope, not as an empty 200 event stream.
  defp stream_chat(conn, instance, body, model, started_at) do
    request = Client.build(:post, "/v1/chat/completions", instance.ruoc_api_key, Jason.encode!(body))
    usage_ref = make_ref()
    Process.put(usage_ref, @no_usage)

    acc0 = %{conn: conn, status: nil, headers: [], error_body: ""}

    result =
      Finch.stream(
        request,
        Druzhok.Finch,
        acc0,
        fn
          {:status, status}, acc ->
            %{acc | status: status}

          {:headers, headers}, %{status: 200} = acc ->
            conn =
              acc.conn
              |> relay_headers(headers, request_id(headers))
              |> put_resp_header("cache-control", "no-cache")
              |> send_chunked(200)

            %{acc | conn: conn, headers: headers}

          {:headers, headers}, acc ->
            %{acc | headers: headers}

          {:data, data}, %{status: 200} = acc ->
            for line <- String.split(data, "\n"), String.starts_with?(line, "data: ") do
              json = String.trim_leading(line, "data: ")

              if json != "[DONE]" do
                case Jason.decode(json) do
                  {:ok, %{"usage" => usage}} when is_map(usage) ->
                    Process.put(usage_ref, LlmFormat.extract_usage(%{"usage" => usage}))

                  _ ->
                    :ok
                end
              end
            end

            %{acc | conn: chunk_raw(acc.conn, data)}

          {:data, data}, acc ->
            %{acc | error_body: acc.error_body <> data}
        end,
        receive_timeout: Client.receive_timeout()
      )

    case result do
      {:ok, %{status: 200} = acc} ->
        meter(instance, "chat", model, Process.get(usage_ref), started_at, body, nil, request_id(acc.headers))
        acc.conn

      {:ok, %{status: status} = acc} when is_integer(status) ->
        request_id = request_id(acc.headers)
        log(instance, "chat", request_id, started_at, "HTTP #{status}")

        acc.conn
        |> relay_headers(acc.headers, request_id)
        |> send_resp(status, acc.error_body)

      {:error, reason, %{status: 200} = acc} ->
        Logger.error("[ruoc] #{instance.name} chat stream cut: #{inspect(reason)}")
        meter(instance, "chat", model, Process.get(usage_ref), started_at, body, nil, request_id(acc.headers))
        acc.conn

      {:error, reason, acc} ->
        Logger.error("[ruoc] #{instance.name} chat unreachable: #{inspect(reason)}")
        json_error(acc.conn, 502, "ruoc-gateway unavailable", "api_error")
    end
  end

  defp chunk_raw(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # --- Search -----------------------------------------------------------------

  @doc "Firecrawl `{query, limit}` in, `{success, data: {web: [...]}}` out, over ruoc `/v1/search`."
  def search(conn, instance, query, limit) do
    started_at = System.monotonic_time(:millisecond)
    payload = %{"query" => query, "max_results" => min(limit, @search_max_results)}

    case Client.post("/v1/search", instance.ruoc_api_key, Jason.encode!(payload)) do
      {:ok, 200, headers, resp_body} ->
        request_id = request_id(headers)
        results = resp_body |> Jason.decode!() |> Map.get("results", []) |> to_firecrawl()
        titles = Enum.map_join(results, " | ", & &1["title"])
        meter(instance, "search", "ruoc-search", @no_usage, started_at, nil, titles, request_id, query)

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(200, Jason.encode!(%{success: true, data: %{web: results}}))

      {:ok, status, headers, resp_body} ->
        request_id = request_id(headers)
        log(instance, "search", request_id, started_at, "HTTP #{status}")

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(status, Jason.encode!(%{success: false, error: error_message(resp_body, "upstream error")}))

      {:error, reason} ->
        Logger.error("[ruoc] #{instance.name} search unreachable: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{success: false, error: "search provider unavailable"}))
    end
  end

  defp to_firecrawl(results) do
    results
    |> Enum.with_index(1)
    |> Enum.map(fn {r, pos} ->
      %{"title" => r["title"] || "", "url" => r["url"] || "", "description" => r["content"] || "", "position" => pos}
    end)
  end

  # --- Transcription ----------------------------------------------------------

  @doc "OpenAI multipart `file` in, `{text}` (or plain text) out, over ruoc `/v1/transcribe`."
  def transcribe(conn, instance) do
    started_at = System.monotonic_time(:millisecond)
    params = conn.body_params

    with %Plug.Upload{path: path, filename: filename} <- params["file"],
         {:ok, format} <- audio_format(filename) do
      payload = %{"audio" => path |> File.read!() |> Base.encode64(), "format" => format}

      case Client.post("/v1/transcribe", instance.ruoc_api_key, Jason.encode!(payload)) do
        {:ok, 200, headers, resp_body} ->
          request_id = request_id(headers)
          text = resp_body |> Jason.decode!() |> Map.get("text", "") |> to_string() |> String.trim()
          meter(instance, "audio", "ruoc-transcribe", @no_usage, started_at, nil, text, request_id)

          conn
          |> relay_headers(headers, request_id)
          |> send_transcription(text, params["response_format"])

        {:ok, status, headers, resp_body} ->
          request_id = request_id(headers)
          log(instance, "audio", request_id, started_at, "HTTP #{status}")

          conn
          |> relay_headers(headers, request_id)
          |> send_resp(status, resp_body)

        {:error, reason} ->
          Logger.error("[ruoc] #{instance.name} transcribe unreachable: #{inspect(reason)}")
          json_error(conn, 502, "ruoc-gateway unavailable", "api_error")
      end
    else
      {:error, :unsupported_format} ->
        json_error(conn, 400, "unsupported audio format (wav, mp3 or ogg)", "invalid_request_error")

      _ ->
        json_error(conn, 400, "No audio file provided", "invalid_request_error")
    end
  end

  # Telegram voice notes are ogg/opus; the gateway accepts exactly these three.
  defp audio_format(filename) do
    case filename |> to_string() |> Path.extname() |> String.downcase() |> String.trim_leading(".") do
      ext when ext in ["ogg", "oga", "opus"] -> {:ok, "ogg"}
      ext when ext in ["mp3", "mpga", "mpeg"] -> {:ok, "mp3"}
      "wav" -> {:ok, "wav"}
      _ -> {:error, :unsupported_format}
    end
  end

  defp send_transcription(conn, text, format) when format in ["text", "srt", "vtt"] do
    conn |> put_resp_content_type("text/plain") |> send_resp(200, text)
  end

  defp send_transcription(conn, text, _format) do
    conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(%{text: text}))
  end

  # --- Shared -----------------------------------------------------------------

  defp request_id(headers) do
    case List.keyfind(headers, @request_id_header, 0) do
      {_, id} -> id
      nil -> nil
    end
  end

  # Content-type and the request id come from the gateway; nothing else does.
  defp relay_headers(conn, headers, request_id) do
    conn =
      case List.keyfind(headers, "content-type", 0) do
        {_, ct} -> put_resp_header(conn, "content-type", ct)
        nil -> put_resp_content_type(conn, "application/json")
      end

    if request_id, do: put_resp_header(conn, @request_id_header, request_id), else: conn
  end

  defp error_message(body, fallback) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => msg}}} when is_binary(msg) -> msg
      _ -> fallback
    end
  end

  defp json_error(conn, status, message, type) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{message: message, type: type}}))
  end

  defp log(instance, kind, request_id, started_at, outcome) do
    latency = System.monotonic_time(:millisecond) - started_at
    Logger.info("[ruoc] #{instance.name} #{kind} req=#{request_id || "-"} #{latency}ms #{outcome}")
  end

  defp meter(instance, kind, model, usage, started_at, request_body, response_preview, request_id, prompt_preview \\ nil) do
    log(instance, kind, request_id, started_at, "ok")

    Usage.log(%{
      instance_id: instance.id,
      model: model,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      total_tokens: usage.prompt_tokens + usage.completion_tokens,
      cost_cents: 0,
      request_type: kind,
      requested_model: model,
      resolved_model: model,
      provider: "ruoc",
      latency_ms: System.monotonic_time(:millisecond) - started_at,
      prompt_preview: prompt_preview || (request_body && LlmFormat.prompt_preview(request_body)),
      response_preview: response_preview && String.slice(response_preview, 0, 500),
      request_body: request_body && Jason.encode!(request_body)
    })
  end
end
