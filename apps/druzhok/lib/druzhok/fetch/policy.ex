defmodule Druzhok.Fetch.Policy do
  @moduledoc """
  Decides whether a URL may be fetched, and to which address.

  Pure: the resolver is a function, so the rules are testable with a map and
  production passes `:inet`. The address returned here is the one the
  transport connects to, with the name kept for Host and SNI, so a DNS answer
  that changes between check and connect cannot swap the target.
  """

  @type resolver :: (String.t() -> {:ok, :inet.ip_address()} | :error)
  @type target :: %{scheme: :http | :https, host: String.t(), port: :inet.port_number(), ip: :inet.ip_address(), path: String.t()}

  @doc """
  `{:ok, target}`, `{:error, :bad_url}` for a URL this service never fetches,
  `{:error, :unsafe_url}` for one that points inside, `{:error, :unreachable}`
  when the name does not resolve.
  """
  @spec check(String.t(), resolver, keyword) :: {:ok, target} | {:error, :bad_url | :unsafe_url | :unreachable}
  def check(url, resolver, opts \\ []) when is_binary(url) do
    allow_private = Keyword.get(opts, :allow_private, false)

    with {:ok, uri} <- parse(url),
         {:ok, port} <- port(uri),
         :ok <- name_allowed(uri.host, allow_private),
         {:ok, ip} <- address(uri.host, resolver),
         :ok <- if(allow_private, do: :ok, else: address_allowed(ip)) do
      path = if uri.path in [nil, ""], do: "/", else: uri.path
      path = if uri.query, do: path <> "?" <> uri.query, else: path
      {:ok, %{scheme: String.to_atom(uri.scheme), host: uri.host, port: port, ip: ip, path: path}}
    end
  end

  defp parse(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, uri}

      _ ->
        {:error, :bad_url}
    end
  end

  defp port(%URI{port: nil, scheme: "http"}), do: {:ok, 80}
  defp port(%URI{port: nil, scheme: "https"}), do: {:ok, 443}
  defp port(%URI{port: port}) when port in [80, 443] or port in 1024..65535, do: {:ok, port}
  defp port(_), do: {:error, :bad_url}

  # Names that mean "here" are refused before a lookup, so a resolver that
  # answers for them (mDNS, a hosts file) never gets to decide.
  defp name_allowed(_host, true), do: :ok

  defp name_allowed(host, false) do
    down = String.downcase(host)

    if down == "localhost" or
         String.ends_with?(down, [".localhost", ".local", ".internal"]) do
      {:error, :unsafe_url}
    else
      :ok
    end
  end

  defp address(host, resolver) do
    case :inet.parse_strict_address(String.to_charlist(String.trim(host, "[]"))) do
      {:ok, ip} ->
        {:ok, ip}

      {:error, _} ->
        case resolver.(host) do
          {:ok, ip} -> {:ok, ip}
          _ -> {:error, :unreachable}
        end
    end
  end

  # IPv4-mapped IPv6 is judged as the IPv4 it wraps.
  defp address_allowed({0, 0, 0, 0, 0, 0xFFFF, hi, lo}) do
    address_allowed({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})
  end

  defp address_allowed({a, b, _, _} = ip) when tuple_size(ip) == 4 do
    cond do
      a == 0 -> {:error, :unsafe_url}
      a == 10 -> {:error, :unsafe_url}
      a == 127 -> {:error, :unsafe_url}
      a == 100 and b in 64..127 -> {:error, :unsafe_url}
      a == 169 and b == 254 -> {:error, :unsafe_url}
      a == 172 and b in 16..31 -> {:error, :unsafe_url}
      a == 192 and b == 168 -> {:error, :unsafe_url}
      a >= 224 -> {:error, :unsafe_url}
      true -> :ok
    end
  end

  defp address_allowed({a, _, _, _, _, _, _, _} = ip) do
    cond do
      ip == {0, 0, 0, 0, 0, 0, 0, 0} -> {:error, :unsafe_url}
      ip == {0, 0, 0, 0, 0, 0, 0, 1} -> {:error, :unsafe_url}
      # fc00::/7
      Bitwise.band(a, 0xFE00) == 0xFC00 -> {:error, :unsafe_url}
      # fe80::/10
      Bitwise.band(a, 0xFFC0) == 0xFE80 -> {:error, :unsafe_url}
      # ff00::/8
      Bitwise.band(a, 0xFF00) == 0xFF00 -> {:error, :unsafe_url}
      true -> :ok
    end
  end

  @doc "The production resolver: first A answer, then AAAA."
  @spec resolve(String.t()) :: {:ok, :inet.ip_address()} | :error
  def resolve(host) do
    name = String.to_charlist(host)

    case :inet.getaddr(name, :inet) do
      {:ok, ip} ->
        {:ok, ip}

      _ ->
        case :inet.getaddr(name, :inet6) do
          {:ok, ip} -> {:ok, ip}
          _ -> :error
        end
    end
  end
end
