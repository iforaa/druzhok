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
        fn -> %{units: %{}, calls: [], start: :ok, procs: 1, hooks: %{}, pauses: []} end,
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
  def set_procs(n), do: Agent.update(__MODULE__, &%{&1 | procs: n})
  @doc "Run `fun.(name)` inside the next `stop/1` or `start/3` (`op` = :stop | :start), once."
  def hook(op, fun), do: Agent.update(__MODULE__, &put_in(&1, [:hooks, op], fun))
  @doc "The relay pause each `stop/1` found in place, in order."
  def pauses_at_stop, do: Agent.get(__MODULE__, &Enum.reverse(&1.pauses))
  def calls, do: Agent.get(__MODULE__, &Enum.reverse(&1.calls))
  def calls(op), do: for({^op, name} <- calls(), do: name)

  defp run_hook(op, name) do
    case Agent.get_and_update(__MODULE__, &{&1.hooks[op], put_in(&1, [:hooks, op], nil)}) do
      nil -> :ok
      fun -> fun.(name)
    end
  end

  defp record(op, name), do: Agent.update(__MODULE__, &%{&1 | calls: [{op, name} | &1.calls]})

  @impl true
  def start(name, _env, _root) do
    record(:start, name)
    run_hook(:start, name)
    result = Agent.get(__MODULE__, & &1.start)
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
    Agent.update(__MODULE__, &%{&1 | units: Map.delete(&1.units, name)})
    :ok
  end

  @impl true
  def status(name), do: Agent.get(__MODULE__, &Map.get(&1.units, name, :inactive))

  @impl true
  def procs(name) do
    if status(name) == :active, do: Agent.get(__MODULE__, & &1.procs), else: 0
  end

  @impl true
  def stats(_name), do: %{mem_bytes: 230 * 1024 * 1024, cpu_usec: 0}
  @impl true
  def exec(_name, _args), do: {"", 0}
  @impl true
  def logs(_name, _lines), do: ""
  @impl true
  def egress_check(_name), do: :unenforced
end
