defmodule DruzhokWebWeb.LlmProxy.Ruoc do
  @moduledoc """
  The ruoc-gateway path of the LLM proxy: chat, web search, page fetch,
  embeddings, transcription and image generation for a bot that has a
  `ruoc_api_key`.

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
  alias DruzhokWebWeb.LlmProxy.BalanceNotice

  @request_id_header "x-ruoc-request-id"
  @search_max_results 10
  @no_usage %{prompt_tokens: 0, completion_tokens: 0}
  # A render takes tens of seconds; ruoc gives the provider 180 s.
  @image_timeout 190_000
  # A page read: ruoc allows the fetcher 45 s.
  @fetch_timeout 50_000

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
      {:ok, 402, headers, _resp_body} ->
        request_id = request_id(headers)
        log(instance, "chat", request_id, started_at, "HTTP 402 -> balance notice")

        conn
        |> relay_headers(headers, request_id)
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(BalanceNotice.completion(instance, model)))

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
  # 429 on a streaming request reaches the bot as that status with the
  # gateway's own envelope, not as an empty 200 event stream. A 402 becomes
  # the balance notice as a one-chunk stream (see BalanceNotice).
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

      {:ok, %{status: 402} = acc} ->
        request_id = request_id(acc.headers)
        log(instance, "chat", request_id, started_at, "HTTP 402 -> balance notice")

        acc.conn
        |> relay_headers(acc.headers, request_id)
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, BalanceNotice.sse(instance, model))

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

  # --- Page fetch ---------------------------------------------------------------

  @doc """
  Firecrawl `/v2/scrape` in, `{success, data: {markdown, metadata}}` out, over
  ruoc `POST /v1/fetch`, which routes back to this node's `/internal/fetch`
  for the actual read. A 402 keeps its status with the localized balance
  notice; every other refusal keeps ruoc's status and message so the SDK
  raises and hermes records a per-URL error.
  """
  def fetch(conn, instance, url) do
    started_at = System.monotonic_time(:millisecond)

    case Client.post("/v1/fetch", instance.ruoc_api_key, Jason.encode!(%{"url" => url}), receive_timeout: @fetch_timeout) do
      {:ok, 200, headers, resp_body} ->
        request_id = request_id(headers)
        page = Jason.decode!(resp_body)
        title = page["title"] || ""
        meter(instance, "fetch", "ruoc-fetch", @no_usage, started_at, nil, title, request_id, url)

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(200, Jason.encode!(%{
          success: true,
          data: %{
            markdown: page["markdown"] || "",
            metadata: %{title: title, sourceURL: page["final_url"] || url, statusCode: page["status_code"] || 200, url: url}
          }
        }))

      {:ok, 402, headers, _resp_body} ->
        request_id = request_id(headers)
        log(instance, "fetch", request_id, started_at, "HTTP 402 -> balance notice")

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(402, Jason.encode!(%{success: false, error: BalanceNotice.text(instance)}))

      {:ok, status, headers, resp_body} ->
        request_id = request_id(headers)
        log(instance, "fetch", request_id, started_at, "HTTP #{status}")

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(status, Jason.encode!(%{success: false, error: error_message(resp_body, "upstream error")}))

      {:error, reason} ->
        Logger.error("[ruoc] #{instance.name} fetch unreachable: #{inspect(reason)}")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(502, Jason.encode!(%{success: false, error: "fetch provider unavailable"}))
    end
  end

  # --- Embeddings ------------------------------------------------------------

  @embed_timeout 30_000
  # ruoc's own limits, checked here so an oversized batch never costs a round trip.
  @embed_max_texts 64
  @embed_max_chars 8_000

  @doc """
  OpenAI `embeddings` in and out, over ruoc `POST /v1/embeddings`. Only
  `model` and `input` travel; the answer comes back unchanged, including a
  402, which Mnemosyne treats as a permanent failure for that batch and
  falls back to FTS recall.
  """
  def embeddings(conn, instance) do
    body = conn.body_params
    started_at = System.monotonic_time(:millisecond)

    case embed_input(body["input"]) do
      :error ->
        json_error(conn, 400, "input must be a non-empty string or list of strings", "invalid_request_error")

      {:error, :too_many_texts} ->
        json_error(conn, 413, "input may hold at most #{@embed_max_texts} texts", "invalid_request_error")

      {:error, :text_too_long} ->
        json_error(conn, 413, "each text may be at most #{@embed_max_chars} characters", "invalid_request_error")

      {:ok, input} ->
        request = %{"model" => body["model"] || "ruoc-embed", "input" => input}

        case Client.post("/v1/embeddings", instance.ruoc_api_key, Jason.encode!(request), receive_timeout: @embed_timeout) do
          {:ok, 200, headers, resp_body} ->
            request_id = request_id(headers)
            meter(instance, "embedding", request["model"], usage_of(resp_body), started_at, nil, nil, request_id, preview_of(input))

            conn |> relay_headers(headers, request_id) |> send_resp(200, resp_body)

          {:ok, status, headers, resp_body} ->
            request_id = request_id(headers)
            log(instance, "embedding", request_id, started_at, "HTTP #{status}")
            conn |> relay_headers(headers, request_id) |> send_resp(status, resp_body)

          {:error, reason} ->
            Logger.error("[ruoc] #{instance.name} embeddings unreachable: #{inspect(reason)}")
            json_error(conn, 502, "embeddings provider unavailable", "server_error")
        end
    end
  end

  defp embed_input(input) when is_binary(input) and input != "", do: embed_limits(input, [input])

  defp embed_input([_ | _] = input) do
    if Enum.all?(input, &is_binary/1), do: embed_limits(input, input), else: :error
  end

  defp embed_input(_), do: :error

  defp embed_limits(input, texts) do
    cond do
      length(texts) > @embed_max_texts -> {:error, :too_many_texts}
      Enum.any?(texts, &(String.length(&1) > @embed_max_chars)) -> {:error, :text_too_long}
      true -> {:ok, input}
    end
  end

  defp preview_of(input) when is_binary(input), do: String.slice(input, 0, 200)
  defp preview_of([first | _]), do: String.slice(first, 0, 200)

  defp usage_of(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"usage" => %{"prompt_tokens" => n}}} when is_integer(n) -> %{prompt_tokens: n, completion_tokens: 0}
      _ -> @no_usage
    end
  end

  # --- Images -----------------------------------------------------------------

  @doc """
  OpenAI `images/generations` in, `{data: [{b64_json}]}` out, over ruoc
  `POST /v1/images`. The client's `model` is ignored (hermes sends OpenAI
  ids); the bot's `image_gen_model` names a ruoc catalogue entry, nil meaning
  ruoc's default. A 402 keeps its status but carries the localized balance
  notice, so hermes's tool error reaches the tenant in the bot's language.
  """
  def generate_image(conn, instance) do
    started_at = System.monotonic_time(:millisecond)
    prompt = conn.body_params["prompt"] || ""

    payload =
      case instance.image_gen_model do
        nil -> %{"prompt" => prompt}
        model -> %{"prompt" => prompt, "model" => model}
      end

    case Client.post("/v1/images", instance.ruoc_api_key, Jason.encode!(payload), receive_timeout: @image_timeout) do
      {:ok, 200, headers, resp_body} ->
        request_id = request_id(headers)
        %{"model" => model, "image" => %{"b64" => b64}} = Jason.decode!(resp_body)
        meter(instance, "image_gen", model, @no_usage, started_at, nil, nil, request_id, prompt)

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(200, Jason.encode!(%{"created" => System.os_time(:second), "data" => [%{"b64_json" => b64}]}))

      {:ok, 402, headers, _resp_body} ->
        request_id = request_id(headers)
        log(instance, "image_gen", request_id, started_at, "HTTP 402 -> balance notice")

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(402, Jason.encode!(%{error: %{message: BalanceNotice.text(instance), type: "insufficient_quota"}}))

      {:ok, status, headers, resp_body} ->
        request_id = request_id(headers)
        log(instance, "image_gen", request_id, started_at, "HTTP #{status}")

        conn
        |> relay_headers(headers, request_id)
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("[ruoc] #{instance.name} image unreachable: #{inspect(reason)}")
        json_error(conn, 502, "Image generation provider unavailable", "server_error")
    end
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
