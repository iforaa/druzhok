defmodule DruzhokWebWeb.LlmProxyController do
  use DruzhokWebWeb, :controller
  alias DruzhokWebWeb.LlmFormat
  alias Druzhok.{Budget, Usage, ModelAccess}
  require Logger

  def chat_completions(conn, _params) do
    instance = conn.assigns.instance
    body = conn.body_params

    requested_model = body["model"] || "default"
    plan = Map.get(instance, :plan) || "free"
    stream = body["stream"] == true

    case Budget.check(instance.id) do
      {:error, :exceeded} ->
        json_error(conn, 429, "Token budget exceeded", "insufficient_quota")

      {:ok, _remaining} ->
        {resolved_model, _} = case ModelAccess.check(plan, requested_model) do
          {:ok, model} -> {model, requested_model}
          {:downgrade, model} ->
            Logger.info("Downgraded #{requested_model} → #{model} for #{instance.tenant_key}")
            {model, requested_model}
        end

        body = Map.put(body, "model", resolved_model)
        provider = LlmFormat.route_provider(resolved_model)
        api_key = LlmFormat.provider_key(provider)
        base_url = LlmFormat.provider_url(provider)
        path = LlmFormat.request_path(provider)
        url = base_url <> path

        provider_body = LlmFormat.build_request(provider, body)
        headers = LlmFormat.request_headers(provider, api_key)
        started_at = System.monotonic_time(:millisecond)

        if stream do
          stream_proxy(conn, instance, url, headers, provider_body, provider, requested_model, resolved_model, started_at)
        else
          sync_proxy(conn, instance, url, headers, provider_body, provider, requested_model, resolved_model, started_at)
        end
    end
  end

  defp sync_proxy(conn, instance, url, headers, body, provider, requested_model, resolved_model, started_at) do
    request = Finch.build(:post, url, headers, Jason.encode!(body))

    case Finch.request(request, Druzhok.Finch, receive_timeout: 120_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        usage = resp_body |> Jason.decode!() |> then(&LlmFormat.extract_usage(provider, &1))
        meter(instance, usage, requested_model, resolved_model, provider, started_at)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)

      {:error, reason} ->
        Logger.error("LLM proxy error: #{inspect(reason)}")
        json_error(conn, 502, "Provider unavailable", "server_error")
    end
  end

  defp stream_proxy(conn, instance, url, headers, body, provider, requested_model, resolved_model, started_at) do
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
                Process.put(usage_ref, LlmFormat.extract_usage(provider, %{"usage" => usage}))
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
    meter(instance, usage, requested_model, resolved_model, provider, started_at)

    case result do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp meter(instance, usage, requested_model, resolved_model, provider, started_at) do
    total = usage.prompt_tokens + usage.completion_tokens
    if total > 0 do
      latency = System.monotonic_time(:millisecond) - started_at
      Budget.deduct(instance.id, total)
      Usage.log(%{
        instance_id: instance.id,
        model: resolved_model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        requested_model: requested_model,
        resolved_model: resolved_model,
        provider: to_string(provider),
        latency_ms: latency,
      })
    end
  end

  defp json_error(conn, status, message, type) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: %{message: message, type: type}}))
  end
end
