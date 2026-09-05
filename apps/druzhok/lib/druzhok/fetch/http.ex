defmodule Druzhok.Fetch.HTTP do
  @moduledoc """
  One GET, the way a page reader must do it: connected to the address the
  policy checked (Host and SNI still carry the name), redirects re-checked
  per hop, the body capped while it streams, and one deadline over the whole
  thing. Mint rather than Finch because Finch pools by name and cannot be
  told to dial an address it did not resolve itself.
  """

  alias Druzhok.Fetch.Policy

  @max_redirects 5
  @connect_timeout 10_000
  @deadline_ms 30_000
  @max_body 5 * 1024 * 1024
  @readable ~w(text/html application/xhtml+xml text/plain application/pdf)
  @headers [
    {"user-agent", "Mozilla/5.0 (compatible; Druzhok/1.0; +https://druzhok.oldey.dev)"},
    {"accept", "text/html,application/xhtml+xml,application/pdf,text/plain;q=0.8,*/*;q=0.1"},
    {"accept-language", "ru,en;q=0.8"},
    {"accept-encoding", "identity"}
  ]

  @type page :: %{status: pos_integer, final_url: String.t(), content_type: String.t(), body: binary}
  @type error :: :bad_url | :unsafe_url | :unsupported_type | :too_large | :timeout | :unreachable

  @doc """
  Options: `resolver` (default `Policy.resolve/1`), `allow_private` (tests
  only), `deadline_ms`. The body is read only for a 2xx with a readable
  content type; other statuses come back with an empty body.
  """
  @spec get(String.t(), keyword) :: {:ok, page} | {:error, error}
  def get(url, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :deadline_ms, @deadline_ms)
    follow(url, opts, deadline, 0)
  end

  defp follow(_url, _opts, _deadline, hops) when hops > @max_redirects, do: {:error, :unreachable}

  defp follow(url, opts, deadline, hops) do
    with {:ok, target} <- check(url, opts),
         {:ok, conn} <- connect(target, deadline),
         {:ok, conn, ref} <- request(conn, target),
         {:ok, conn, head} <- read_head(conn, ref, deadline) do
      %{status: status, headers: headers} = head

      cond do
        status in [301, 302, 303, 307, 308] and location(headers) != nil ->
          Mint.HTTP.close(conn)
          next = url |> URI.merge(location(headers)) |> URI.to_string()
          follow(next, opts, deadline, hops + 1)

        status in 200..299 ->
          # No Content-Type at all is read as HTML: that is what such servers send.
          type = content_type(headers)

          if type == "" or type in @readable do
            case read_body(conn, ref, deadline, head.data, head.size, head.done) do
              {:ok, body} -> {:ok, %{status: status, final_url: url, content_type: type, body: body}}
              {:error, _} = error -> error
            end
          else
            Mint.HTTP.close(conn)
            {:error, :unsupported_type}
          end

        true ->
          Mint.HTTP.close(conn)
          {:ok, %{status: status, final_url: url, content_type: content_type(headers), body: ""}}
      end
    end
  end

  defp check(url, opts) do
    resolver = Keyword.get(opts, :resolver, &Policy.resolve/1)
    Policy.check(url, resolver, allow_private: Keyword.get(opts, :allow_private, false))
  end

  defp connect(%{scheme: scheme, ip: ip, host: host, port: port}, deadline) do
    timeout = min(@connect_timeout, remaining(deadline))

    if timeout <= 0 do
      {:error, :timeout}
    else
      transport_opts = [timeout: timeout] ++ tls_opts(scheme, host)

      case Mint.HTTP.connect(scheme, ip, port, hostname: host, mode: :passive, transport_opts: transport_opts) do
        {:ok, conn} -> {:ok, conn}
        {:error, %Mint.TransportError{reason: :timeout}} -> {:error, :timeout}
        {:error, _} -> {:error, :unreachable}
      end
    end
  end

  defp tls_opts(:https, host), do: [server_name_indication: String.to_charlist(host)]
  defp tls_opts(:http, _host), do: []

  defp request(conn, %{path: path}) do
    case Mint.HTTP.request(conn, "GET", path, @headers, nil) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, _conn, _reason} -> {:error, :unreachable}
    end
  end

  @empty_head %{status: nil, headers: [], headers_done: false, data: [], size: 0, done: false}

  # Reads until status and headers are in; body bytes that arrive with them
  # are carried along so read_body starts where this left off.
  defp read_head(conn, ref, deadline, head \\ @empty_head) do
    case recv(conn, deadline) do
      {:ok, conn, responses} ->
        head = Enum.reduce(responses, head, &absorb(&1, ref, &2))

        if head.status != nil and head.headers_done,
          do: {:ok, conn, head},
          else: read_head(conn, ref, deadline, head)

      {:error, _} = error ->
        error
    end
  end

  defp absorb({:status, ref, status}, ref, head), do: %{head | status: status}
  defp absorb({:headers, ref, headers}, ref, head), do: %{head | headers: head.headers ++ headers, headers_done: true}
  defp absorb({:data, ref, data}, ref, head), do: %{head | data: [data | head.data], size: head.size + byte_size(data)}
  defp absorb({:done, ref}, ref, head), do: %{head | done: true}
  defp absorb(_, _ref, head), do: head

  defp read_body(conn, ref, deadline, chunks, size, done?) do
    cond do
      size > @max_body ->
        Mint.HTTP.close(conn)
        {:error, :too_large}

      done? ->
        Mint.HTTP.close(conn)
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      true ->
        case recv(conn, deadline) do
          {:ok, conn, responses} ->
            {chunks, size, done?} =
              Enum.reduce(responses, {chunks, size, false}, fn
                {:data, ^ref, data}, {c, s, d} -> {[data | c], s + byte_size(data), d}
                {:done, ^ref}, {c, s, _} -> {c, s, true}
                _, acc -> acc
              end)

            read_body(conn, ref, deadline, chunks, size, done?)

          {:error, _} = error ->
            error
        end
    end
  end

  defp recv(conn, deadline) do
    timeout = remaining(deadline)

    if timeout <= 0 do
      Mint.HTTP.close(conn)
      {:error, :timeout}
    else
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, responses} ->
          {:ok, conn, responses}

        {:error, conn, %Mint.TransportError{reason: :timeout}, _} ->
          Mint.HTTP.close(conn)
          {:error, :timeout}

        {:error, conn, _reason, _} ->
          Mint.HTTP.close(conn)
          {:error, :unreachable}
      end
    end
  end

  defp remaining(deadline), do: deadline - System.monotonic_time(:millisecond)

  defp location(headers) do
    case List.keyfind(headers, "location", 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp content_type(headers) do
    case List.keyfind(headers, "content-type", 0) do
      {_, value} -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
      nil -> ""
    end
  end
end
