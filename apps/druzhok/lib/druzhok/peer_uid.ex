defmodule Druzhok.PeerUid do
  @moduledoc """
  Which bot opened a loopback connection to druzhok, by the socket's owner:
  the kernel's `/proc/net/tcp{,6}` row whose local end is the client's
  address and port and whose remote end is druzhok's, then the uid's name in
  `/etc/passwd`. A bot cannot make a socket that another uid owns, so this
  needs no key (the document converter, `POST /v2/docs/convert`: a bot's
  terminal has no `OPENAI_API_KEY`).

  Linux only. `Druzhok.Telegram.ListenerOwner` reads the same tables for
  listening sockets.
  """

  @established 1
  @tables ["/proc/net/tcp", "/proc/net/tcp6"]

  @type endpoint :: {:inet.ip_address(), :inet.port_number()}

  @doc """
  The bot (its name, without `bot-`) whose socket is the client end of the
  connection from `peer` to `server`; nil when the owner is not a bot user,
  the row is missing or more than one uid claims it.
  """
  @spec bot_name(endpoint, endpoint) :: String.t() | nil
  def bot_name(peer, server) do
    with uid when is_integer(uid) <- uid(peer, server),
         {:ok, passwd} <- File.read(passwd_path()) do
      bot_of(user_name(passwd, uid))
    else
      _ -> nil
    end
  end

  @doc "The uid owning the client end of `peer` → `server`, or nil."
  def uid(peer, server) do
    rows =
      for file <- Application.get_env(:druzhok, :peer_uid_tables, @tables),
          {:ok, text} <- [File.read(file)],
          row <- parse(text),
          do: row

    owner(rows, peer, server)
  end

  @doc false
  def owner(rows, {peer_ip, peer_port}, {server_ip, server_port}) do
    peer = {normalize(peer_ip), peer_port}
    server = {normalize(server_ip), server_port}

    rows
    |> Enum.filter(&(&1.state == @established and &1.local == peer and &1.remote == server))
    |> Enum.map(& &1.uid)
    |> Enum.uniq()
    |> case do
      [uid] -> uid
      _ -> nil
    end
  end

  @doc """
  The rows of a `/proc/net/tcp` or `/proc/net/tcp6` text:
  `%{local: {ip, port}, remote: {ip, port}, state: int, uid: int}`, with
  IPv4-mapped IPv6 addresses as IPv4. Lines that do not parse are skipped.
  """
  def parse(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      with [_sl, local, remote, state, _queues, _timer, _retr, uid | _] <- String.split(line),
           {:ok, local} <- endpoint(local),
           {:ok, remote} <- endpoint(remote),
           {state, ""} <- Integer.parse(state, 16),
           {uid, ""} <- Integer.parse(uid) do
        [%{local: local, remote: remote, state: state, uid: uid}]
      else
        _ -> []
      end
    end)
  end

  defp endpoint(text) do
    with [addr, port] <- String.split(text, ":"),
         {port, ""} <- Integer.parse(port, 16),
         {:ok, ip} <- address(addr) do
      {:ok, {normalize(ip), port}}
    else
      _ -> :error
    end
  end

  # The kernel prints each 32-bit word in host order, little-endian on the box.
  defp address(hex) when byte_size(hex) in [8, 32] do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} ->
        words = for <<w::little-32 <- bytes>>, into: <<>>, do: <<w::big-32>>

        case words do
          <<a, b, c, d>> -> {:ok, {a, b, c, d}}
          <<g1::16, g2::16, g3::16, g4::16, g5::16, g6::16, g7::16, g8::16>> -> {:ok, {g1, g2, g3, g4, g5, g6, g7, g8}}
        end

      :error ->
        :error
    end
  end

  defp address(_), do: :error

  defp normalize({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {Bitwise.bsr(hi, 8), Bitwise.band(hi, 0xFF), Bitwise.bsr(lo, 8), Bitwise.band(lo, 0xFF)}

  defp normalize(ip), do: ip

  @doc false
  def user_name(passwd, uid) do
    target = Integer.to_string(uid)

    passwd
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case String.split(line, ":") do
        [name, _pw, ^target | _] -> name
        _ -> nil
      end
    end)
  end

  @doc false
  def bot_of("bot-" <> name) do
    if Druzhok.Host.valid_name?(name), do: name
  end

  def bot_of(_), do: nil

  defp passwd_path, do: Application.get_env(:druzhok, :peer_uid_passwd, "/etc/passwd")
end
