defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmProxy.Ruoc, as: RuocProxy
  alias Druzhok.Usage
  require Logger

  # Chat, search, transcription, image generation and embeddings are served by
  # ruoc-gateway with the bot's own account (`LlmProxy.Ruoc`). LlmAuth
  # guarantees `ruoc_api_key` is set. TTS still goes to OpenAI directly.
  def chat_completions(conn, _params), do: RuocProxy.chat(conn, conn.assigns.instance)
  def images_generations(conn, _params), do: RuocProxy.generate_image(conn, conn.assigns.instance)

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

  def embeddings(conn, _params), do: RuocProxy.embeddings(conn, conn.assigns.instance)

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
