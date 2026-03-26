defmodule PiCore.Tools.WebFetch do
  alias PiCore.Tools.Tool

  @user_agent "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
  @max_body_bytes 2_000_000
  @preview_max_bytes 2_000
  @timeout_ms 10_000
  @max_redirects 3

  def new do
    %Tool{
      name: "web_fetch",
      description: "Fetch a URL and extract readable text content. Returns clean text from web pages (HTML→text via Readability), or raw content for RSS/JSON/plain text. Use this instead of curl for reading web content. Set direct=true to bypass VPN for Russian services (Yandex, 2GIS, etc.) that block foreign IPs.",
      parameters: %{
        url: %{type: :string, description: "URL to fetch (http or https)"},
        direct: %{type: :boolean, description: "Bypass VPN for Russian services (default: false)", required: false}
      },
      execute: &execute/2
    }
  end

  def execute(%{"url" => url, "direct" => true}, _context) do
    execute_direct(url)
  end

  def execute(%{"url" => url}, _context) do
    with {:ok, uri} <- parse_and_validate(url),
         {:ok, ip} <- resolve_and_check(uri.host),
         {:ok, _status, headers, body} <- http_get(url, ip, @max_redirects) do
      media_type = parse_media_type(get_header(headers, "content-type"))
      case process_body(body, media_type) do
        {:ok, content} -> {:ok, maybe_preview(content, media_type)}
        error -> error
      end
    end
  end

  # Parse URL once and validate scheme + host
  defp parse_and_validate(url) when is_binary(url) do
    uri = URI.parse(url)
    cond do
      uri.scheme not in ["http", "https"] -> {:error, "Invalid URL: must be http or https"}
      is_nil(uri.host) or uri.host == "" -> {:error, "Invalid URL: missing host"}
      true -> {:ok, uri}
    end
  end
  defp parse_and_validate(_), do: {:error, "Invalid URL"}

  # Resolve hostname and check against SSRF blocklist
  defp resolve_and_check(host) do
    case :inet.getaddr(String.to_charlist(host), :inet) do
      {:ok, ip} -> check_ip(ip)
      {:error, _} -> {:error, "DNS resolution failed for #{host}"}
    end
  end

  # IPv4 SSRF protection
  # resolve_and_check uses :inet (IPv4 only). IPv6-only hosts fail DNS resolution.
  defp check_ip({127, _, _, _}), do: {:error, "Blocked: private/internal address"}
  defp check_ip({10, _, _, _}), do: {:error, "Blocked: private/internal address"}
  defp check_ip({192, 168, _, _}), do: {:error, "Blocked: private/internal address"}
  defp check_ip({172, b, _, _}) when b >= 16 and b <= 31, do: {:error, "Blocked: private/internal address"}
  defp check_ip({169, 254, _, _}), do: {:error, "Blocked: private/internal address"}
  defp check_ip({0, 0, 0, 0}), do: {:error, "Blocked: private/internal address"}
  defp check_ip(ip), do: {:ok, ip}

  defp parse_media_type(nil), do: "application/octet-stream"
  defp parse_media_type(ct) do
    ct |> String.split(";") |> hd() |> String.trim() |> String.downcase()
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
    body = ensure_utf8(body)
    case PiCore.Native.Readability.extract(body) do
      {:ok, %{"title" => title, "text" => text}} when text != "" ->
        {:ok, "# #{title}\n\n#{text}"}
      _ ->
        {:ok, PiCore.Native.Readability.strip_tags(body)}
    end
  end
  defp process_body(body, media_type) when media_type in @passthrough_types do
    {:ok, body}
  end
  defp process_body(_body, media_type) do
    {:error, "Unsupported content type: #{media_type}"}
  end

  defp maybe_preview(content, media_type) do
    if byte_size(content) > @preview_max_bytes do
      preview = String.slice(content, 0, @preview_max_bytes)
      preview <> "\n---\n[Content truncated: #{byte_size(content)} bytes total, type: #{media_type}]"
    else
      content
    end
  end

  defp ensure_utf8(body) do
    if String.valid?(body) do
      body
    else
      case :unicode.characters_to_binary(body, :latin1) do
        result when is_binary(result) -> result
        _ -> body
      end
    end
  end

  defp http_get(url, _resolved_ip, redirects_left) when redirects_left <= 0 do
    {:error, "Too many redirects for #{url}"}
  end
  defp http_get(url, _resolved_ip, redirects_left) do
    headers = [
      {"user-agent", @user_agent},
      {"accept-language", "ru,en;q=0.9"},
      {"accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}
    ]

    encoded_url = encode_url(url)
    req = Finch.build(:get, encoded_url, headers)

    case stream_body(req) do
      {:ok, status, resp_headers, _body} when status in [301, 302, 303, 307, 308] ->
        case get_header(resp_headers, "location") do
          nil -> {:error, "Redirect with no Location header"}
          location ->
            redirect_url = URI.merge(URI.parse(url), location) |> to_string()
            with {:ok, uri} <- parse_and_validate(redirect_url),
                 {:ok, ip} <- resolve_and_check(uri.host) do
              http_get(redirect_url, ip, redirects_left - 1)
            end
        end

      {:ok, status, resp_headers, body} ->
        with :ok <- check_status(status, url) do
          {:ok, status, resp_headers, body}
        end

      {:error, reason} ->
        {:error, "Fetch failed: #{inspect(reason)}"}
    end
  end

  # Direct fetch bypassing VPN — uses su nobody to avoid iptables redirect
  defp execute_direct(url) do
    with {:ok, uri} <- parse_and_validate(url),
         {:ok, _ip} <- resolve_and_check(uri.host) do
      # Use single-quoted URL in shell to prevent injection
      escaped_url = url |> String.replace("'", "'\\''")
      cmd = ~s(su -s /bin/sh nobody -c 'curl -sL --max-time 10 -A "Mozilla/5.0" -H "Accept-Language: ru,en;q=0.9" '\\''#{escaped_url}'\\''')

      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
        {body, 0} ->
          body = if byte_size(body) > @max_body_bytes, do: binary_part(body, 0, @max_body_bytes), else: body
          if byte_size(body) == 0 do
            {:ok, "(empty response)"}
          else
            media_type = guess_media_type(url, body)
            case process_body(body, media_type) do
              {:ok, content} -> {:ok, maybe_preview(content, media_type)}
              error -> error
            end
          end

        {error, _} ->
          {:error, "Direct fetch failed: #{String.slice(error, 0, 200)}"}
      end
    end
  end

  defp guess_media_type(url, body) do
    cond do
      String.ends_with?(url, ".json") -> "application/json"
      String.ends_with?(url, ".xml") or String.ends_with?(url, ".rss") -> "application/xml"
      String.starts_with?(body, "<?xml") or String.starts_with?(body, "<rss") -> "application/xml"
      String.starts_with?(body, "{") or String.starts_with?(body, "[") -> "application/json"
      String.contains?(body, "<html") or String.contains?(body, "<!DOCTYPE") -> "text/html"
      true -> "text/plain"
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
        {:error, reason, _acc} -> {:error, reason}
      end
    catch
      {^ref, :body_too_large} -> {:error, "Response body exceeds 2 MB limit"}
    end
  end

  # Encode non-ASCII characters in URL (Cyrillic, etc.) without double-encoding
  defp encode_url(url) do
    uri = URI.parse(url)
    path = if uri.path, do: encode_component_keep_slashes(uri.path), else: nil
    query = if uri.query, do: encode_component_keep_special(uri.query), else: nil
    %{uri | path: path, query: query} |> URI.to_string()
  end

  defp encode_component_keep_slashes(path) do
    path
    |> String.split("/")
    |> Enum.map(&URI.encode/1)
    |> Enum.join("/")
  end

  defp encode_component_keep_special(query) do
    query
    |> String.split("&")
    |> Enum.map(fn part ->
      case String.split(part, "=", parts: 2) do
        [k, v] -> URI.encode(k) <> "=" <> URI.encode(v)
        [k] -> URI.encode(k)
      end
    end)
    |> Enum.join("&")
  end
end
