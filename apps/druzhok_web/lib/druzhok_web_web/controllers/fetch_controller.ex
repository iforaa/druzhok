defmodule DruzhokWebWeb.FetchController do
  @moduledoc """
  `POST /internal/fetch {url}`: the page reader ruoc-gateway routes
  `POST /v1/fetch` to. Druzhok owns the network and the safety rules here;
  ruoc owns the price and the ledger. No usage row: the tenant-facing
  `/v2/scrape` records the read.
  """

  use DruzhokWebWeb, :controller
  require Logger

  @statuses %{
    bad_url: 400, unsafe_url: 400, unsupported_type: 400,
    no_text: 422,
    timeout: 504,
    unreachable: 502, too_large: 502, worker_down: 502, extract_failed: 502
  }

  def fetch(conn, params) do
    started = System.monotonic_time(:millisecond)
    url = params["url"]

    result =
      if is_binary(url) and String.trim(url) != "",
        do: fetch_module().fetch(String.trim(url)),
        else: {:error, :bad_url, %{}}

    case result do
      {:ok, page} ->
        log(url, 200, started, page.bytes)
        json(conn, Map.take(page, [:final_url, :title, :markdown, :status_code, :bytes]))

      {:error, code, meta} ->
        status = Map.get(@statuses, code, 502)
        log(url, status, started, 0, code)
        body = %{error: to_string(code)}
        body = if code == :no_text and meta[:status_code], do: Map.put(body, :status_code, meta.status_code), else: body

        conn |> put_status(status) |> json(body)
    end
  end

  defp fetch_module, do: Application.get_env(:druzhok_web, :fetch_module, Druzhok.Fetch)

  defp log(url, status, started, bytes, code \\ nil) do
    host = with u when is_binary(u) <- url, %URI{host: h} when is_binary(h) <- URI.parse(u), do: h, else: (_ -> "-")
    latency = System.monotonic_time(:millisecond) - started
    Logger.info("[fetch] #{host} #{status}#{if code, do: " " <> to_string(code)} #{latency}ms #{bytes}b")
  end
end
