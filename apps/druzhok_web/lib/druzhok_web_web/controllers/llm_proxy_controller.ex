defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmFormat
  alias Druzhok.{Budget, Usage, ModelCatalog}
  require Logger

  @default_image_model ModelCatalog.default_image_model()
  @default_image_gen_model ModelCatalog.default_image_gen_model()

  def chat_completions(conn, _params) do
    instance = conn.assigns.instance
    body = conn.body_params
    model = body["model"] || "default"
    stream = body["stream"] == true

    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        json_error(conn, 429, budget_exceeded_message(instance), "budget_exceeded")

      {:ok, _remaining} ->
        url = LlmFormat.request_url()
        headers = LlmFormat.request_headers(conn.req_headers)
        body = LlmFormat.prepare_body(body)
        started_at = System.monotonic_time(:millisecond)

        cond do
          stream and broken_streaming?(model) ->
            fake_stream_proxy(conn, instance, url, headers, body, model, started_at)

          stream ->
            stream_proxy(conn, instance, url, headers, body, model, started_at)

          true ->
            sync_proxy(conn, instance, url, headers, body, model, started_at)
        end
    end
  end

  # Only the original mimo-v2-pro emitted malformed streaming SSE; v2.5-pro and
  # later stream cleanly with reasoning disabled (LlmFormat.apply_reasoning_override).
  defp broken_streaming?(model), do: String.starts_with?(model || "", "xiaomi/mimo-v2-pro")

  defp fake_stream_proxy(conn, instance, url, headers, body, model, started_at) do
    sync_body = body |> Map.put("stream", false) |> Map.delete("stream_options")
    request = Finch.build(:post, url, headers, Jason.encode!(sync_body))

    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> send_chunked(200)

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        decoded = Jason.decode!(resp_body)
        usage = LlmFormat.extract_usage(decoded)
        content = get_in(decoded, ["choices", Access.at(0), "message", "content"]) || ""
        tool_calls = get_in(decoded, ["choices", Access.at(0), "message", "tool_calls"])
        finish_reason = get_in(decoded, ["choices", Access.at(0), "finish_reason"]) || "stop"
        model_id = decoded["model"] || model
        response_id = decoded["id"] || "chatcmpl-fake"

        conn = emit_fake_stream(conn, response_id, model_id, content, tool_calls, finish_reason, usage, body["stream_options"])
        cost_cents = LlmFormat.extract_cost_cents(decoded, model)
        meter(instance, usage, model, started_at, body, content, cost_cents)
        conn

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.warning("fake_stream_proxy upstream #{status}")
        conn |> chunk_raw("data: #{resp_body}\n\n") |> chunk_raw("data: [DONE]\n\n")

      {:error, reason} ->
        Logger.error("fake_stream_proxy error: #{inspect(reason)}")
        conn |> chunk_raw(~s(data: {"error":"upstream failed"}\n\n)) |> chunk_raw("data: [DONE]\n\n")
    end
  end

  defp emit_fake_stream(conn, id, model, content, tool_calls, finish_reason, usage, stream_options) do
    delta = if tool_calls, do: %{"tool_calls" => tool_calls}, else: %{"role" => "assistant", "content" => content}

    content_chunk = %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => nil}]
    }

    final_chunk = %{
      "id" => id,
      "object" => "chat.completion.chunk",
      "model" => model,
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => finish_reason}]
    }

    conn = chunk_sse(conn, content_chunk)
    conn = chunk_sse(conn, final_chunk)

    conn =
      if is_map(stream_options) and stream_options["include_usage"] do
        usage_chunk = %{
          "id" => id,
          "object" => "chat.completion.chunk",
          "model" => model,
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => usage.prompt_tokens,
            "completion_tokens" => usage.completion_tokens,
            "total_tokens" => usage.prompt_tokens + usage.completion_tokens
          }
        }

        chunk_sse(conn, usage_chunk)
      else
        conn
      end

    chunk_raw(conn, "data: [DONE]\n\n")
  end

  defp chunk_sse(conn, payload), do: chunk_raw(conn, "data: #{Jason.encode!(payload)}\n\n")

  # Thread the conn through so test adapters (and anything else that records
  # chunks on the struct) see every chunk; a closed client is not an error.
  defp chunk_raw(conn, data) do
    case Plug.Conn.chunk(conn, data) do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp sync_proxy(conn, instance, url, headers, body, model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        decoded = Jason.decode!(resp_body)
        usage = LlmFormat.extract_usage(decoded)
        response_preview = get_in(decoded, ["choices", Access.at(0), "message", "content"])
        cost_cents = LlmFormat.extract_cost_cents(decoded, model)
        meter(instance, usage, model, started_at, body, response_preview, cost_cents)

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
              {:ok, %{"usage" => usage} = chunk} when is_map(usage) ->
                Process.put(usage_ref, LlmFormat.extract_usage(%{"usage" => usage}))
                Process.put({usage_ref, :cost}, LlmFormat.extract_cost_cents(chunk, model))
              _ -> :ok
            end
          end
        end

        chunk_raw(conn, data)
    end, receive_timeout: 120_000)

    usage = Process.get(usage_ref, %{prompt_tokens: 0, completion_tokens: 0})
    cost_cents = Process.get({usage_ref, :cost}, 0)
    meter(instance, usage, model, started_at, body, nil, cost_cents)

    # Finch.stream/5 returns the accumulator (our conn) alongside the error;
    # the 200 is already committed, so relay whatever was streamed.
    case result do
      {:ok, conn} -> conn
      {:error, reason, conn} ->
        Logger.error("LLM stream proxy error: #{inspect(reason)}")
        conn
    end
  end

  defp meter(instance, usage, model, started_at, request_body, response_preview, cost_cents) do
    total = usage.prompt_tokens + usage.completion_tokens

    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Budget.deduct(instance.id, cost_cents)

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
        cost_cents: cost_cents,
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

  # Default model for OpenRouter-backed transcription. Gemini Flash accepts
  # audio input (wav/mp3/ogg/opus) and transcribes it cheaply; this is what
  # lets us bill voice notes against the OpenRouter account instead of needing
  # a separately-funded OpenAI Whisper account.
  @transcription_default_model "google/gemini-2.5-flash"

  @transcribe_prompt """
  You are a speech-to-text engine. Transcribe the audio VERBATIM in its \
  original spoken language. Output ONLY the transcript text — no commentary, \
  no labels, no quotation marks, no translation. If there is no intelligible \
  speech, output an empty string.\
  """

  def audio_transcriptions(conn, _params) do
    or_key = LlmFormat.provider_key()

    if is_nil(or_key) do
      json_error(conn, 503, "Audio transcription not configured", "server_error")
    else
      instance = conn.assigns.instance

      case Budget.check(instance.id) do
        {:error, :exceeded} ->
          json_error(conn, 429, budget_exceeded_message(instance), "budget_exceeded")

        {:ok, _} ->
          do_audio_transcription(conn, or_key, instance)
      end
    end
  end

  # Transcribe via OpenRouter: feed the uploaded audio to a multimodal chat
  # model as an `input_audio` part and return the reply reshaped into the
  # Whisper response the caller (hermes) expects. hermes is none the wiser.
  defp do_audio_transcription(conn, or_key, instance) do
    started_at = System.monotonic_time(:millisecond)
    params = conn.body_params

    case params["file"] do
      %Plug.Upload{path: path, filename: filename} ->
        audio_b64 = path |> File.read!() |> Base.encode64()
        format = audio_format(filename)
        model = Druzhok.Settings.get("transcription_model") || @transcription_default_model

        payload = %{
          "model" => model,
          "messages" => [
            %{
              "role" => "user",
              "content" => [
                %{"type" => "text", "text" => @transcribe_prompt},
                %{"type" => "input_audio", "input_audio" => %{"data" => audio_b64, "format" => format}}
              ]
            }
          ]
        }

        url = LlmFormat.provider_url() <> "/chat/completions"
        headers = [
          {"authorization", "Bearer #{or_key}"},
          {"content-type", "application/json"}
        ]
        request = Finch.build(:post, url, headers, Jason.encode!(payload))

        case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
          {:ok, %Finch.Response{status: 200, body: resp_body}} ->
            latency = System.monotonic_time(:millisecond) - started_at
            transcript = extract_chat_transcript(resp_body)
            Logger.info("[audio] transcription via #{model} #{latency}ms (#{String.length(transcript)} chars)")
            meter_transcription(instance, resp_body, latency, model)
            send_transcription(conn, transcript, params["response_format"])

          {:ok, %Finch.Response{status: status, body: resp_body}} ->
            Logger.error("Audio transcription OpenRouter error #{status}: #{String.slice(resp_body, 0, 300)}")
            conn |> put_resp_content_type("application/json") |> send_resp(status, resp_body)

          {:error, reason} ->
            Logger.error("Audio transcription proxy error: #{inspect(reason)}")
            json_error(conn, 502, "Transcription provider unavailable", "server_error")
        end

      _ ->
        json_error(conn, 400, "No audio file provided", "invalid_request")
    end
  end

  # Map an uploaded filename's extension to an OpenRouter `input_audio` format.
  # Telegram voice notes arrive as ogg/opus (.oga/.ogg); Gemini accepts them.
  defp audio_format(filename) do
    case filename |> to_string() |> Path.extname() |> String.downcase() |> String.trim_leading(".") do
      ext when ext in ["ogg", "oga", "opus"] -> "ogg"
      ext when ext in ["mp3", "mpga", "mpeg"] -> "mp3"
      "m4a" -> "m4a"
      "mp4" -> "mp4"
      "wav" -> "wav"
      "webm" -> "webm"
      "flac" -> "flac"
      "" -> "mp3"
      other -> other
    end
  end

  defp extract_chat_transcript(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, decoded} ->
        (get_in(decoded, ["choices", Access.at(0), "message", "content"]) || "")
        |> to_string()
        |> String.trim()

      _ ->
        ""
    end
  end

  # hermes asks Whisper for response_format="text" (plain string) for whisper-1
  # and "json" ({"text": ...}) otherwise. Honor whichever it sent.
  defp send_transcription(conn, transcript, response_format)
       when response_format in ["text", "srt", "vtt"] do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, transcript)
  end

  defp send_transcription(conn, transcript, _response_format) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{text: transcript}))
  end

  defp meter_transcription(nil, _resp_body, _latency, _model), do: :ok
  defp meter_transcription(instance, resp_body, latency, model) do
    case Jason.decode(resp_body) do
      {:ok, decoded} ->
        usage = LlmFormat.extract_usage(decoded)
        total = usage.prompt_tokens + usage.completion_tokens
        cost_cents = LlmFormat.extract_cost_cents(decoded, model)
        Budget.deduct(instance.id, cost_cents)

        Usage.log(%{
          instance_id: instance.id,
          model: model,
          prompt_tokens: usage.prompt_tokens,
          completion_tokens: usage.completion_tokens,
          total_tokens: total,
          cost_cents: cost_cents,
          request_type: "audio",
          requested_model: model,
          resolved_model: model,
          provider: "openrouter",
          latency_ms: latency
        })

      _ ->
        :ok
    end
  end

  def audio_speech(conn, _params) do
    openai_key = Druzhok.Settings.get("openai_api_key")

    if is_nil(openai_key) do
      json_error(conn, 503, "Text-to-speech not configured", "server_error")
    else
      instance = conn.assigns.instance

      case Budget.check(instance.id) do
        {:error, :exceeded} ->
          json_error(conn, 429, budget_exceeded_message(instance), "budget_exceeded")

        {:ok, _} ->
          do_audio_speech(conn, openai_key, instance)
      end
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
    Budget.deduct(instance.id, cost_cents)

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

  @search_model "perplexity/sonar"
  @search_system_prompt ~s"""
  You are a web search API. Given a user query, perform a web search and \
  respond with ONLY a JSON array of results. No markdown, no commentary, \
  no preamble, just a raw JSON array.

  Each result must have exactly these fields:
    - "title": the page title (string)
    - "url": the page URL (string)
    - "description": a 1-2 sentence summary of the page relevance to the \
      query (string)

  Return at most the number of results requested by the user. If there are \
  no relevant results, return an empty array `[]`.
  """

  def firecrawl_search(conn, _params) do
    body = conn.body_params
    query = body["query"] || ""
    limit = Map.get(body, "limit", 5) |> normalize_limit()

    cond do
      query == "" ->
        send_resp(conn, 400, Jason.encode!(%{success: false, error: "query is required"}))

      true ->
        instance = conn.assigns.instance

        case Budget.check(instance.id) do
          {:error, :exceeded} ->
            send_resp(conn, 429, Jason.encode!(%{success: false, error: "Token budget exceeded"}))

          {:ok, _} ->
            do_firecrawl_search(conn, instance, query, limit)
        end
    end
  end

  defp do_firecrawl_search(conn, instance, query, limit) do
    started_at = System.monotonic_time(:millisecond)

    chat_body = %{
      "model" => @search_model,
      "messages" => [
        %{"role" => "system", "content" => @search_system_prompt},
        %{"role" => "user", "content" => "#{query}\n\nReturn up to #{limit} results as a JSON array."}
      ],
      "usage" => %{"include" => true}
    }

    url = LlmFormat.request_url()
    headers = LlmFormat.request_headers(conn.req_headers)
    request = Finch.build(:post, url, headers, Jason.encode!(chat_body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: 200, body: resp_body}} ->
        case Jason.decode(String.trim(resp_body)) do
          {:ok, decoded} ->
            results = parse_search_results(decoded, limit)
            meter_search(instance, decoded, query, started_at)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{success: true, data: %{web: results}}))

          _ ->
            send_resp(conn, 502, Jason.encode!(%{success: false, error: "invalid upstream response"}))
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        Logger.error("Search proxy upstream #{status}: #{String.slice(resp_body, 0, 200)}")
        send_resp(conn, status, Jason.encode!(%{success: false, error: "upstream error"}))

      {:error, reason} ->
        Logger.error("Search proxy network error: #{inspect(reason)}")
        send_resp(conn, 502, Jason.encode!(%{success: false, error: "search provider unavailable"}))
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

  defp parse_search_results(decoded, limit) do
    content = get_in(decoded, ["choices", Access.at(0), "message", "content"]) || ""

    parsed =
      case Jason.decode(String.trim(content)) do
        {:ok, list} when is_list(list) -> list
        {:ok, %{"results" => list}} when is_list(list) -> list
        {:ok, %{"web" => list}} when is_list(list) -> list
        _ -> extract_json_array(content)
      end

    parsed
    |> Enum.take(limit)
    |> Enum.with_index(1)
    |> Enum.map(fn {item, pos} ->
      %{
        "title" => Map.get(item, "title", ""),
        "url" => Map.get(item, "url", ""),
        "description" => Map.get(item, "description") || Map.get(item, "snippet") || "",
        "position" => pos
      }
    end)
  end

  defp meter_search(nil, _decoded, _query, _started_at), do: :ok

  defp meter_search(instance, decoded, query, started_at) do
    usage = LlmFormat.extract_usage(decoded)
    total = usage.prompt_tokens + usage.completion_tokens
    cost_cents = LlmFormat.extract_cost_cents(decoded, @search_model)
    Budget.deduct(instance.id, cost_cents)

    Usage.log(%{
      instance_id: instance.id,
      model: @search_model,
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      total_tokens: total,
      cost_cents: cost_cents,
      request_type: "search",
      requested_model: @search_model,
      resolved_model: @search_model,
      provider: "openrouter",
      latency_ms: System.monotonic_time(:millisecond) - started_at,
      prompt_preview: String.slice(query, 0, 500)
    })
  end

  # Fallback when the LLM wraps the array in stray text.
  defp extract_json_array(content) do
    case Regex.run(~r/\[\s*\{.*\}\s*\]/s, content) do
      [match] ->
        case Jason.decode(match) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end

      _ ->
        []
    end
  end

  defp meter_image(nil, _usage, _model, _started_at, _cost_cents), do: :ok
  defp meter_image(instance, usage, image_model, started_at, cost_cents) do
    total = usage.prompt_tokens + usage.completion_tokens
    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Budget.deduct(instance.id, cost_cents)
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

  # The request body's `model` is ignored — clients (e.g. hermes' OpenAI
  # plugin) hardcode OpenAI model IDs that OpenRouter doesn't recognize.
  # Per-bot model lives in `instance.image_gen_model`.
  def images_generations(conn, _params) do
    instance = conn.assigns.instance
    prompt = conn.body_params["prompt"] || ""
    model = instance.image_gen_model || @default_image_gen_model

    with {:ok, _} <- Budget.check(instance.id) do
      started_at = System.monotonic_time(:millisecond)

      upstream_body =
        Jason.encode!(%{
          "model" => model,
          "modalities" => image_modalities(model),
          "messages" => [%{"role" => "user", "content" => prompt}],
          "usage" => %{"include" => true}
        })

      request =
        Finch.build(
          :post,
          LlmFormat.request_url(),
          LlmFormat.request_headers(conn.req_headers),
          upstream_body
        )

      case Finch.request(request, Druzhok.Finch, receive_timeout: 180_000) do
        {:ok, %Finch.Response{status: 200, body: resp_body}} ->
          decoded = Jason.decode!(String.trim(resp_body))
          cost_cents = LlmFormat.extract_cost_cents(decoded, model)
          latency = System.monotonic_time(:millisecond) - started_at
          meter_image_gen(instance, model, cost_cents, latency)

          payload =
            Jason.encode!(%{
              "created" => System.os_time(:second),
              "data" => Enum.map(extract_images(decoded), &%{"b64_json" => &1})
            })

          conn |> put_resp_content_type("application/json") |> send_resp(200, payload)

        {:ok, %Finch.Response{status: status, body: resp_body}} ->
          Logger.warning("images_generations upstream #{status}: #{String.slice(resp_body, 0, 200)}")
          conn |> put_resp_content_type("application/json") |> send_resp(status, resp_body)

        {:error, reason} ->
          Logger.error("images_generations error: #{inspect(reason)}")
          json_error(conn, 502, "Image generation provider unavailable", "server_error")
      end
    else
      {:error, :exceeded} ->
        json_error(conn, 429, budget_exceeded_message(instance), "budget_exceeded")
    end
  end

  # OpenRouter splits image-gen models by output modality:
  #   text+image (Gemini) → ["image", "text"]
  #   image-only (FLUX, Seedream, Sourceful) → ["image"]
  defp image_modalities("google/" <> _), do: ["image", "text"]
  defp image_modalities(_), do: ["image"]

  # OpenRouter image-gen response shape:
  #   choices[0].message.images = [%{"type" => "image_url",
  #                                   "image_url" => %{"url" => "data:image/png;base64,..."}}]
  defp extract_images(decoded) do
    case get_in(decoded, ["choices", Access.at(0), "message", "images"]) do
      images when is_list(images) ->
        Enum.flat_map(images, fn img ->
          case get_in(img, ["image_url", "url"]) do
            "data:" <> _ = data_url ->
              [data_url |> String.split(",", parts: 2) |> List.last()]
            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp meter_image_gen(instance, model, cost_cents, latency) do
    Budget.deduct(instance.id, cost_cents)

    Usage.log(%{
      instance_id: instance.id,
      model: model,
      prompt_tokens: 0,
      completion_tokens: 0,
      total_tokens: 0,
      cost_cents: cost_cents,
      request_type: "image_gen",
      requested_model: model,
      resolved_model: model,
      provider: "openrouter",
      latency_ms: latency
    })
  end

  def responses_proxy(conn, _params) do
    # OpenAI Responses API → convert to chat/completions format for OpenRouter
    body = conn.body_params
    instance = conn.assigns.instance
    image_model = instance.image_model || @default_image_model

    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        json_error(conn, 429, "Token budget exceeded", "insufficient_quota")

      {:ok, _} ->
        do_responses_proxy(conn, body, image_model, instance)
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

  defp budget_exceeded_message(instance) do
    limit_dollars = Budget.cents_to_dollars(instance.daily_budget_cents || 0)
    tz = instance.timezone || "UTC"

    reset_clock =
      case DateTime.now(tz) do
        {:ok, dt} ->
          tomorrow = Date.add(DateTime.to_date(dt), 1)
          reset_dt = DateTime.new!(tomorrow, ~T[00:00:00], tz)
          diff_min = div(DateTime.diff(reset_dt, dt, :second), 60)
          hours = div(diff_min, 60)
          mins = rem(diff_min, 60)
          "через #{hours}ч #{mins}м"

        _ ->
          "в 00:00 UTC"
      end

    "Бюджет на сегодня исчерпан. Лимит $#{limit_dollars}. Сбросится #{reset_clock}."
  end
end
