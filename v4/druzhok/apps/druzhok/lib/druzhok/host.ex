defmodule Druzhok.Host do
  @moduledoc """
  Process-control backend for bots. `Druzhok.Host.Systemd` in production
  (one systemd unit + Linux user per bot via `druzhok-ctl`), `Druzhok.Host.Process`
  for local development and tests (plain OS process, no isolation).

  `BotManager` owns *what* to run (env, config files, DB state); `Host` owns
  *how* it runs.
  """

  @type name :: String.t()
  @type status :: :active | :activating | :inactive | :failed | :unknown
  @type stats :: %{mem_bytes: non_neg_integer(), cpu_usec: non_neg_integer()} | nil

  @callback start(name, env :: %{String.t() => String.t()}, data_root :: String.t()) ::
              :ok | {:error, term()}
  @callback stop(name) :: :ok
  @callback destroy(name) :: :ok
  @callback status(name) :: status
  @callback stats(name) :: stats
  @callback exec(name, args :: [String.t()]) :: {String.t(), integer()}
  @callback logs(name, lines :: pos_integer()) :: String.t()

  @name_re ~r/^[a-z0-9][a-z0-9-]{0,30}$/

  def impl, do: Application.get_env(:druzhok, :host, Druzhok.Host.Process)

  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_re, name)
  def valid_name?(_), do: false

  def start(name, env, data_root), do: impl().start(name, env, data_root)
  def stop(name), do: impl().stop(name)
  def destroy(name), do: impl().destroy(name)
  def status(name), do: impl().status(name)
  def stats(name), do: impl().stats(name)
  def exec(name, args), do: impl().exec(name, args)
  def logs(name, lines \\ 200), do: impl().logs(name, lines)
end
