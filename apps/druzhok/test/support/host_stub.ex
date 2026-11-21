defmodule Druzhok.HostStub do
  @moduledoc """
  A `Druzhok.Host` whose unit states the test sets, for the lifecycle states
  `Host.Process` cannot produce (systemd's restart loop, a drain, a start
  that hangs). Records every call. `use/0` installs it for one test.
  """
  @behaviour Druzhok.Host

  import ExUnit.Callbacks, only: [on_exit: 1]

  def use do
    prev = Application.get_env(:druzhok, :host)

    {:ok, _} =
      Agent.start(
        fn ->
          %{
            units: %{},
            calls: [],
            start: :ok,
            destroy: :ok,
            start_for: %{},
            procs: 1,
            hooks: %{},
            pauses: [],
            list: :ok,
            quotas: [],
            quota: :ok,
            disk_all: :unknown
          }
        end,
        name: __MODULE__
      )

    Application.put_env(:druzhok, :host, __MODULE__)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:druzhok, :host, prev),
        else: Application.delete_env(:druzhok, :host)

      if Process.whereis(__MODULE__), do: Agent.stop(__MODULE__)
    end)

    :ok
  end

  def set_unit(name, status), do: Agent.update(__MODULE__, &put_in(&1, [:units, name], status))

  @doc "What the next `start/3` returns and leaves the unit in: `:ok` (active) or `{:error, r}` (failed)."
  def on_start(result), do: Agent.update(__MODULE__, &%{&1 | start: result})
  @doc "What starts of `name` alone return, until changed again."
  def on_start(name, result),
    do: Agent.update(__MODULE__, &put_in(&1, [:start_for, name], result))

  @doc "What `destroy/1` returns from now on: `:ok` or `{:error, r}` (the unit and user stay)."
  def on_destroy(result), do: Agent.update(__MODULE__, &%{&1 | destroy: result})

  def set_procs(n), do: Agent.update(__MODULE__, &%{&1 | procs: n})
  @doc "Make `holding_units/0` fail (`:error`) or work again (`:ok`)."
  def set_list(result), do: Agent.update(__MODULE__, &%{&1 | list: result})
  @doc "Run `fun.(name)` inside the next `stop/1` or `start/3` (`op` = :stop | :start), once."
  def hook(op, fun), do: Agent.update(__MODULE__, &put_in(&1, [:hooks, op], fun))
  @doc "The relay pause each `stop/1` found in place, in order."
  def pauses_at_stop, do: Agent.get(__MODULE__, &Enum.reverse(&1.pauses))
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def units, do: Agent.get(__MODULE__, & &1.units)
  def calls(op), do: for({^op, name} <- calls(), do: name)

  defp run_hook(op, name) do
    case Agent.get_and_update(__MODULE__, &{&1.hooks[op], put_in(&1, [:hooks, op], nil)}) do
      nil -> :ok
      fun -> fun.(name)
    end
  end

  defp record(op, name), do: Agent.update(__MODULE__, &%{&1 | calls: [{op, name} | &1.calls]})

  # Not recorded: the tests count starts, stops and destroys.
  @impl true
  def prepare(_name, _env, data_root) do
    File.mkdir_p!(data_root)
    :ok
  end

  @impl true
  def wipe(_name, data_root) do
    File.rm_rf(data_root)
    :ok
  end

  @impl true
  def start(name, _env, _root) do
    record(:start, name)
    run_hook(:start, name)
    result = Agent.get(__MODULE__, &Map.get(&1.start_for, name, &1.start))
    set_unit(name, if(result == :ok, do: :active, else: :failed))
    result
  end

  @impl true
  def stop(name) do
    record(:stop, name)

    pause =
      case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
        nil -> nil
        inst -> with {reason, _} <- Druzhok.Telegram.Webhook.paused(inst), do: reason
      end

    Agent.update(__MODULE__, &%{&1 | pauses: [pause | &1.pauses]})
    run_hook(:stop, name)
    set_unit(name, :inactive)
    :ok
  end

  @impl true
  def destroy(name) do
    record(:destroy, name)

    with :ok <- Agent.get(__MODULE__, & &1.destroy) do
      Agent.update(__MODULE__, &%{&1 | units: Map.delete(&1.units, name)})
    end
  end

  @impl true
  def status(name) do
    record(:status, name)
    Agent.get(__MODULE__, &Map.get(&1.units, name, :inactive))
  end

  @impl true
  # `set_procs([1, 2])` answers 1, then 2, then 2 again.
  def procs(name) do
    if status(name) == :active do
      Agent.get_and_update(__MODULE__, fn
        %{procs: [n]} = s -> {n, s}
        %{procs: [n | rest]} = s -> {n, %{s | procs: rest}}
        %{procs: n} = s -> {n, s}
      end)
    else
      0
    end
  end

  @impl true
  def stats(_name), do: %{mem_bytes: 230 * 1024 * 1024, cpu_usec: 0}
  @impl true
  def memory_bytes(name) do
    if Agent.get(__MODULE__, &Map.get(&1.units, name, :inactive)) == :active,
      do: stats(name).mem_bytes
  end

  @doc "What `memory_max_bytes/1` answers for a running unit (default 800 MiB; nil = `max`)."
  def set_memory_max(bytes), do: Agent.update(__MODULE__, &Map.put(&1, :memory_max, bytes))

  @impl true
  def memory_max_bytes(name) do
    Agent.get(__MODULE__, fn s ->
      if Map.get(s.units, name, :inactive) == :active,
        do: Map.get(s, :memory_max, 800 * 1024 * 1024)
    end)
  end

  @impl true
  def exec(_name, _args), do: {"", 0}

  # systemd's view of the unit states the test set: a restart loop waits in
  # activating, a stop drains in deactivating.
  @impl true
  def holding_units do
    Agent.get_and_update(__MODULE__, fn s ->
      s = %{s | calls: [{:holding_units, nil} | s.calls]}

      if s.list == :ok do
        units =
          for {name, unit} <- s.units,
              state = holding(unit),
              into: %{},
              do: {name, state}

        {{:ok, units}, s}
      else
        {:error, s}
      end
    end)
  end

  # Kept apart from `calls/0`, which the lifecycle tests compare whole.
  @impl true
  def quota(name, disk_mb, files) do
    Agent.get_and_update(
      __MODULE__,
      &{&1.quota, %{&1 | quotas: [{name, disk_mb, files} | &1.quotas]}}
    )
  end

  @doc "Every `quota/3` call as `{name, disk_mb | :off, files}`, in order."
  def quota_calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.quotas))
  @doc "What `quota/3` answers from now on."
  def on_quota(result), do: Agent.update(__MODULE__, &%{&1 | quota: result})

  @impl true
  def quotas, do: Agent.get(__MODULE__, &Map.get(&1, :quotas_state, :unknown))
  @doc "What `quotas/0` answers from now on."
  def set_quotas(state), do: Agent.update(__MODULE__, &Map.put(&1, :quotas_state, state))

  @impl true
  def disk_all, do: Agent.get(__MODULE__, & &1.disk_all)
  @doc "What `disk_all/0` answers from now on: `{:ok, map}`, `:off`, `:unknown` or `{:error, r}`."
  def set_disk_all(result), do: Agent.update(__MODULE__, &%{&1 | disk_all: result})

  defp holding(:active), do: :active
  defp holding(:activating), do: :activating
  defp holding(:restarting), do: :activating
  defp holding(:stopping), do: :deactivating
  defp holding(_), do: nil
end
