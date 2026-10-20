defmodule Druzhok.Telegram.ListenerOwner do
  @moduledoc """
  Who is listening on a bot's webhook port. The relay hands a bot its
  private chats and its secret only after this says the listener belongs to
  `bot-<name>`, the in-process layer of the port isolation in the spec.

  Reads `/proc/net/tcp` and `/proc/net/tcp6` on Linux. Under
  `Druzhok.Host.Process` (dev, tests) bots are plain processes of the
  developer's own user and there is nothing to check.
  """

  @listen "0A"

  @doc "`:ok`, `{:error, :no_listener}` or `{:error, {:wrong_owner, uids}}`."
  def check(name, port) do
    if Druzhok.Host.impl() == Druzhok.Host.Systemd do
      with {:ok, uid} <- bot_uid(name) do
        verify(listeners(port), uid)
      end
    else
      :ok
    end
  end

  @doc false
  def verify([], _uid), do: {:error, :no_listener}

  def verify(uids, uid) do
    case Enum.reject(uids, &(&1 == uid)) do
      [] -> :ok
      others -> {:error, {:wrong_owner, Enum.uniq(others)}}
    end
  end

  defp listeners(port) do
    for file <- ["/proc/net/tcp", "/proc/net/tcp6"],
        {:ok, text} <- [File.read(file)],
        uid <- parse(text, port),
        do: uid
  end

  @doc """
  Uids of the sockets listening on `port`, on any address: a socket on
  0.0.0.0 or [::] would take loopback connections as well.
  """
  def parse(text, port) do
    hex_port = port |> Integer.to_string(16) |> String.pad_leading(4, "0")

    text
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_sl, local, _remote, @listen, _queues, _timer, _retr, uid | _] ->
          if local |> String.split(":") |> List.last() |> String.upcase() == hex_port,
            do: [String.to_integer(uid)],
            else: []

        _ ->
          []
      end
    end)
  end

  defp bot_uid(name) do
    case System.cmd("id", ["-u", "bot-" <> name], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out |> String.trim() |> String.to_integer()}
      _ -> {:error, :no_bot_user}
    end
  end
end
