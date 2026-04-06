defmodule Druzhok.PoolObserver do
  @moduledoc """
  Tails pool container logs and captures tool events and errors.
  Stores them in crash_logs for the dashboard to display.
  """
  use GenServer
  require Logger

  def start_link(opts) do
    container = Keyword.fetch!(opts, :container)
    pool_name = Keyword.fetch!(opts, :pool_name)
    GenServer.start_link(__MODULE__, %{container: container, pool_name: pool_name},
      name: via(pool_name))
  end

  def stop(pool_name) do
    case Registry.lookup(Druzhok.Registry, {:pool_observer, pool_name}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp via(pool_name), do: {:via, Registry, {Druzhok.Registry, {:pool_observer, pool_name}}}

  @impl true
  def init(state) do
    port = open_log_port(state.container)
    {:ok, Map.merge(state, %{port: port, buffer: ""})}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = String.split(state.buffer <> to_string(data), "\n")
    {complete, [partial]} = Enum.split(lines, -1)

    for line <- complete do
      cleaned = String.replace(line, ~r/\e\[[0-9;]*m/, "")
      process_line(cleaned, state)
    end

    {:noreply, %{state | buffer: partial}}
  end

  def handle_info({port, {:exit_status, _}}, %{port: port} = state) do
    Process.send_after(self(), :reconnect, 5_000)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    port = open_log_port(state.container)
    {:noreply, %{state | port: port, buffer: ""}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  defp open_log_port(container) do
    Port.open(
      {:spawn_executable, "/usr/bin/env"},
      [:binary, :exit_status, :use_stdio, :stderr_to_stdout,
       args: ["docker", "logs", "-f", "--since=5s", container]]
    )
  end

  # Tool failures
  defp process_line("[tools] " <> rest = line, state) when byte_size(rest) > 0 do
    if String.contains?(line, "failed") do
      log_error(state, line, "tool_failure")
    end
  end

  # Image understanding failures
  defp process_line(line, state) do
    cond do
      String.contains?(line, "image failed:") ->
        log_error(state, line, "image_error")

      String.contains?(line, "audio understanding failed:") ->
        log_error(state, line, "audio_error")

      String.contains?(line, "Embedded agent failed") ->
        log_error(state, line, "agent_error")

      String.contains?(line, "Config invalid") ->
        log_error(state, line, "config_error")

      String.contains?(line, "Unhandled promise rejection") ->
        log_error(state, line, "unhandled_rejection")

      String.contains?(line, "getUpdates conflict") ->
        log_error(state, line, "telegram_conflict")

      true -> :ok
    end
  end

  defp log_error(state, message, source) do
    # Find which instance this error belongs to (parse agent ID from log line)
    instance_name = extract_instance_name(message) || state.pool_name

    Druzhok.CrashLog.insert(%{
      message: String.slice(message, 0, 2000),
      level: "error",
      source: source,
      instance_name: instance_name
    })
  end

  defp extract_instance_name(line) do
    case Regex.run(~r/agent[:-](\w+)/, line) do
      [_, name] -> name
      _ -> nil
    end
  end
end
