defmodule Druzhok.Fetch do
  @moduledoc """
  Read one web page as markdown: `Fetch.HTTP` gets the bytes to the policy's
  rules, `Fetch.Worker` turns them into text, and this module says whether
  what came back is a page worth returning at all.

  It is the upstream ruoc-gateway's `POST /v1/fetch` routes to, through
  `DruzhokWebWeb.FetchController`; it knows nothing about tenants or money.
  """

  alias Druzhok.Fetch.{HTTP, Worker}

  # Under this much text the page is a shell (script-only, a login wall, an
  # error page) and is reported as no_text rather than sold.
  @min_chars 60

  # The whole read, transfer and extraction together, stays inside ruoc's
  # 45 s call so a slow page plus a slow PDF is a timeout here, not there.
  @budget_ms 40_000
  @extract_min_ms 2_000

  @type page :: %{final_url: String.t(), title: String.t(), markdown: String.t(), status_code: pos_integer, bytes: non_neg_integer}
  @type code :: HTTP.error() | :no_text | :worker_down | :extract_failed

  @doc "Options are `Fetch.HTTP.get/2`'s. `meta` carries `status_code` for `:no_text`."
  @spec fetch(String.t(), keyword) :: {:ok, page} | {:error, code, map}
  def fetch(url, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    case HTTP.get(url, opts) do
      {:ok, %{status: status} = got} when status in 200..299 ->
        extract(got, max(@budget_ms - (System.monotonic_time(:millisecond) - started), @extract_min_ms))

      {:ok, %{status: status}} ->
        {:error, :no_text, %{status_code: status}}

      {:error, code} ->
        {:error, code, %{}}
    end
  end

  defp extract(%{body: body, content_type: type, charset: charset, final_url: final_url, status: status}, timeout) do
    case Worker.extract(kind(type), final_url, body, charset: charset, timeout: timeout) do
      {:ok, %{title: title, markdown: markdown}} ->
        if String.length(String.trim(markdown)) < @min_chars do
          {:error, :no_text, %{status_code: status}}
        else
          {:ok, %{final_url: final_url, title: title, markdown: markdown, status_code: status, bytes: byte_size(body)}}
        end

      {:error, code} ->
        {:error, code, %{}}
    end
  end

  defp kind("application/pdf"), do: :pdf
  defp kind("text/plain"), do: :text
  defp kind(type) when type in ["application/rss+xml", "application/atom+xml", "application/xml", "text/xml"], do: :feed
  defp kind(_), do: :html
end
