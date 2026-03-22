defmodule Druzhok.InstanceWatcher do
  use GenServer
  require Logger

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def watch(instance_name, sup_pid) do
    GenServer.cast(__MODULE__, {:watch, instance_name, sup_pid})
  end

  def init(state), do: {:ok, state}

  def handle_cast({:watch, name, pid}, state) do
    Process.monitor(pid)
    {:noreply, Map.put(state, pid, name)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.pop(state, pid) do
      {nil, state} ->
        {:noreply, state}

      {name, state} ->
        Logger.error("Instance #{name} supervisor crashed: #{inspect(reason)}")

        try do
          Druzhok.Events.broadcast(name, %{type: :instance_crashed, reason: inspect(reason)})
        rescue
          _ -> :ok
        end

        try do
          case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
            nil -> :ok
            inst -> Druzhok.Repo.update(Druzhok.Instance.changeset(inst, %{active: false}))
          end
        rescue
          _ -> :ok
        end

        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
