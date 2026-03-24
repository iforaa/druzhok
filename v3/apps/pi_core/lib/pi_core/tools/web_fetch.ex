defmodule PiCore.Tools.WebFetch do
  alias PiCore.Tools.Tool

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  @max_body_bytes 2_000_000
  @timeout_ms 10_000
  @max_redirects 3

  def new do
    %Tool{
      name: "web_fetch",
      description: "Fetch a URL and extract readable text content. Returns clean text from web pages (HTML→text via Readability), or raw content for RSS/JSON/plain text. Use this instead of curl for reading web content.",
      parameters: %{url: %{type: :string, description: "URL to fetch (http or https)"}},
      execute: &execute/2
    }
  end

  def execute(%{"url" => url}, _context) do
    with :ok <- validate_url(url),
         {:ok, host} <- extract_host(url),
         {:ok, ip} <- resolve_host(host),
         :ok <- check_ip(ip),
         {:ok, status, headers, body} <- http_get(url, @max_redirects),
         :ok <- check_status(status, url) do
      media_type = parse_media_type(get_header(headers, "content-type"))
      process_body(body, media_type)
    end
  end

  def validate_url(url) when is_binary(url) do
    uri = URI.parse(url)
    cond do
      uri.scheme not in ["http", "https"] -> {:error, "Invalid URL: must be http or https"}
      is_nil(uri.host) or uri.host == "" -> {:error, "Invalid URL: missing host"}
      true -> :ok
    end
  end
  def validate_url(_), do: {:error, "Invalid URL"}

  # IPv4 SSRF protection
  def check_ip({127, _, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({10, _, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({192, 168, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({172, b, _, _}) when b >= 16 and b <= 31, do: {:error, "Blocked: private/internal address"}
  def check_ip({169, 254, _, _}), do: {:error, "Blocked: private/internal address"}
  def check_ip({0, 0, 0, 0}), do: {:error, "Blocked: private/internal address"}
  # Note: resolve_host uses :inet (IPv4 only). IPv6-only hosts fail DNS resolution.
  # If IPv6 support is added later, add clauses for ::1, fe80::/10, fc00::/7.
  def check_ip(_), do: :ok

  def parse_media_type(nil), do: "application/octet-stream"
  def parse_media_type(ct) do
    ct |> String.split(";") |> hd() |> String.trim() |> String.downcase()
  end

  defp extract_host(url) do
    case URI.parse(url) do
      %{host: host} when is_binary(host) and host != "" -> {:ok, host}
      _ -> {:error, "Invalid URL: cannot extract host"}
    end
  end

  defp resolve_host(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> {:error, "DNS resolution failed for #{host}"}
    end
  end

  defp check_status(status, _url) when status >= 200 and status < 300, do: :ok
  defp check_status(status, url), do: {:error, "HTTP #{status}: #{url}"}

  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @html_types ["text/html"]
  @passthrough_types ["application/xml", "text/xml", "application/rss+xml",
                      "application/atom+xml", "application/json", "text/plain"]

  defp process_body(body, media_type) when media_type in @html_types do
    # Ensure UTF-8 — most sites are, but legacy Russian sites may use windows-1251
    body = ensure_utf8(body)
    case PiCore.Native.Readability.extract(body) do
      {:ok, %{"title" => title, "text" => text}} when text != "" ->
        {:ok, "# #{title}\n\n#{text}"}
      _ ->
        # Fallback: strip tags
        {:ok, PiCore.Native.Readability.strip_tags(body)}
    end
  end
  defp process_body(body, media_type) when media_type in @passthrough_types do
    {:ok, body}
  end
  defp process_body(_body, media_type) do
    {:error, "Unsupported content type: #{media_type}"}
  end

  # Encoding normalization — attempt UTF-8, pass through if already valid
  defp ensure_utf8(body) do
    case :unicode.characters_to_binary(body, :utf8) do
      {:error, _, _} ->
        # Try latin1 (covers windows-1251 partially)
        case :unicode.characters_to_binary(body, :latin1) do
          {:error, _, _} -> body  # Give up, pass as-is
          result when is_binary(result) -> result
          _ -> body
        end
      {:incomplete, _, _} -> body
      result when is_binary(result) -> result
      _ -> body
    end
  end

  # HTTP GET with manual redirect following and body size limit
  defp http_get(url, redirects_left) when redirects_left <= 0 do
    {:error, "Too many redirects for #{url}"}
  end
  defp http_get(url, redirects_left) do
    headers = [
      {"user-agent", @user_agent},
      {"accept-language", "ru,en;q=0.9"},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    ]

    req = Finch.build(:get, url, headers)

    case stream_body(req) do
      {:ok, status, resp_headers, body} when status in [301, 302, 303, 307, 308] ->
        case get_header(resp_headers, "location") do
          nil -> {:error, "Redirect with no Location header"}
          location ->
            redirect_url = URI.merge(URI.parse(url), location) |> to_string()
            with :ok <- validate_url(redirect_url),
                 {:ok, host} <- extract_host(redirect_url),
                 {:ok, ip} <- resolve_host(host),
                 :ok <- check_ip(ip) do
              http_get(redirect_url, redirects_left - 1)
            end
        end

      {:ok, status, resp_headers, body} ->
        {:ok, status, resp_headers, body}

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  end

  defp stream_body(req) do
    ref = make_ref()

    try do
      Finch.stream(req, PiCore.Finch, {nil, [], <<>>}, fn
        {:status, status}, {_, headers, body} ->
          {status, headers, body}

        {:headers, new_headers}, {status, headers, body} ->
          normalized = Enum.map(new_headers, fn {k, v} -> {String.downcase(k), v} end)
          {status, headers ++ normalized, body}

        {:data, data}, {status, headers, body} ->
          new_body = body <> data
          if byte_size(new_body) > @max_body_bytes do
            throw({ref, :body_too_large})
          end
          {status, headers, new_body}
      end, receive_timeout: @timeout_ms)
      |> case do
        {:ok, {status, headers, body}} -> {:ok, status, headers, body}
        {:error, reason} -> {:error, reason}
      end
    catch
      {^ref, :body_too_large} -> {:error, "Response body exceeds 2 MB limit"}
    end
  end
end
