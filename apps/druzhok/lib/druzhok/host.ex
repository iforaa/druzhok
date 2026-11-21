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

  @doc "Starts the bot's unit. `prepare/3` has run for this start, with the same env."
  @callback start(name, env :: %{String.t() => String.t()}, data_root :: String.t()) ::
              :ok | {:error, term()}
  @doc """
  Before a start's file work: the bot's user and its tenant dir exist, with
  the env file as given. Safe to repeat.
  """
  @callback prepare(name, env :: %{String.t() => String.t()}, data_root :: String.t()) ::
              :ok | {:error, term()}
  @doc "After `destroy/1`: the bot's tenant dir and all in it are gone."
  @callback wipe(name, data_root :: String.t()) :: :ok | {:error, term()}
  @callback stop(name) :: :ok
  @callback destroy(name) :: :ok | {:error, term()}
  @callback status(name) :: status
  @callback stats(name) :: stats
  @doc "Processes the bot runs right now (1 = hermes alone, at rest); nil if unknown."
  @callback procs(name) :: non_neg_integer() | nil
  @doc "Memory the bot's unit uses now; nil when no unit runs or the read failed. Cheap: no `sudo`, safe per bot per read."
  @callback memory_bytes(name) :: non_neg_integer() | nil
  @doc "The unit's memory ceiling (cgroup `memory.max`); nil when no unit runs, there is none (`max`) or the read failed. Cheap, as `memory_bytes/1`."
  @callback memory_max_bytes(name) :: non_neg_integer() | nil
  @callback exec(name, args :: [String.t()]) :: {String.t(), integer()}

  @doc """
  Every bot unit that holds or may still hold memory, by bot name, from one
  read: `:active`, `:activating` (a start or systemd's restart wait),
  `:reloading` or `:deactivating` (still stopping). `:error` when the read
  failed. Queue mode counts these with the database holders (bot queue spec,
  "Slots").
  """
  @callback holding_units() ::
              {:ok, %{name => :active | :activating | :reloading | :deactivating}} | :error

  @typedoc "One bot user's disk use and hard limits; 0 in a limit field is no limit."
  @type disk :: %{
          used_kb: non_neg_integer(),
          limit_kb: non_neg_integer(),
          files: non_neg_integer(),
          file_limit: non_neg_integer()
        }

  @doc """
  Sets the bot user's hard disk limits (`disk_mb` MB and `files` files), or
  clears them (`:off`). `:ok` also on a host whose quotas are off, where it does
  nothing; `:no_user` when the bot's Linux user does not exist yet (a bot that
  never started: its first start sets the limit, so this is not a failure);
  `:unknown` from a backend that has no quotas at all (`Host.Process`).
  """
  @callback quota(name, disk_mb :: pos_integer() | :off, files :: non_neg_integer()) ::
              :ok | :no_user | :unknown | {:error, term()}

  @doc """
  Whether quotas are on for the tenants' filesystem right now, without reading
  anyone's usage: `:on`, `:off`, `:unknown` from a backend without quotas.
  """
  @callback quotas() :: :on | :off | :unknown | {:error, term()}

  @doc """
  Every bot user's disk use and limits, by bot name, from one read. `:off` when
  quotas are off on this host, `:unknown` from a backend without quotas.
  """
  @callback disk_all() :: {:ok, %{name => disk}} | :off | :unknown | {:error, term()}

  @name_re ~r/^[a-z0-9][a-z0-9_-]{0,30}$/

  def impl, do: Application.get_env(:druzhok, :host, Druzhok.Host.Process)

  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_re, name)
  def valid_name?(_), do: false

  def start(name, env, data_root), do: impl().start(name, env, data_root)
  def prepare(name, env, data_root), do: impl().prepare(name, env, data_root)
  def wipe(name, data_root), do: impl().wipe(name, data_root)
  def stop(name), do: impl().stop(name)
  def destroy(name), do: impl().destroy(name)
  def status(name), do: impl().status(name)
  def stats(name), do: impl().stats(name)
  def procs(name), do: impl().procs(name)
  def memory_bytes(name), do: impl().memory_bytes(name)
  def memory_max_bytes(name), do: impl().memory_max_bytes(name)
  def exec(name, args), do: impl().exec(name, args)
  def holding_units, do: impl().holding_units()
  def quota(name, disk_mb, files), do: impl().quota(name, disk_mb, files)
  def disk_all, do: impl().disk_all()
  def quotas, do: impl().quotas()
end
