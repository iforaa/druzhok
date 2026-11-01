defmodule Druzhok.Host do
  @moduledoc """
  Process-control backend for bots. `Druzhok.Host.Systemd` in production
  (one systemd unit + Linux user per bot via `druzhok-ctl`), `Druzhok.Host.Process`
  for local development and tests (plain OS process, no isolation).

  `BotManager` owns *what* to run (env, config files, DB state); `Host` owns
  *how* it runs.
  """

  @type name :: String.t()
  @type status ::
          :active | :activating | :restarting | :stopping | :inactive | :failed | :unknown
  @type stats :: %{mem_bytes: non_neg_integer(), cpu_usec: non_neg_integer()} | nil

  @callback start(name, env :: %{String.t() => String.t()}, data_root :: String.t()) ::
              :ok | {:error, term()}
  @callback stop(name) :: :ok
  @callback destroy(name) :: :ok
  @callback status(name) :: status
  @callback stats(name) :: stats
  @doc "Processes the bot runs right now (1 = hermes alone, at rest); nil if unknown."
  @callback procs(name) :: non_neg_integer() | nil
  @doc "Memory the bot's unit uses now; nil when no unit runs or the read failed. Cheap: no `sudo`, safe per bot per read."
  @callback memory_bytes(name) :: non_neg_integer() | nil
  @callback exec(name, args :: [String.t()]) :: {String.t(), integer()}

  @name_re ~r/^[a-z0-9][a-z0-9_-]{0,30}$/

  def impl, do: Application.get_env(:druzhok, :host, Druzhok.Host.Process)

  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_re, name)
  def valid_name?(_), do: false

  def start(name, env, data_root), do: impl().start(name, env, data_root)
  def stop(name), do: impl().stop(name)
  def destroy(name), do: impl().destroy(name)
  def status(name), do: impl().status(name)
  def stats(name), do: impl().stats(name)
  def procs(name), do: impl().procs(name)
  def memory_bytes(name), do: impl().memory_bytes(name)
  def exec(name, args), do: impl().exec(name, args)
end
