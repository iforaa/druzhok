defmodule Druzhok.LogWatcher do
  @moduledoc """
  Tails docker logs for a bot instance, detects unauthorized Telegram users
  from runtime log output, and creates pairing requests.
  """
  use GenServer
  require Logger

  @format_check_interval :timer.hours(6)
  @format_warn_after :timer.hours(24)

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via(name))
  end

  def stop(instance_name) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :log_watcher}) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  defp via(name), do: {:via, Registry, {Druzhok.Registry, {name, :log_watcher}}}

  @impl true
  def init(opts) do
    instance_name = Keyword.fetch!(opts, :name)
    runtime_module = Keyword.fetch!(opts, :runtime)
    bot_token = Keyword.fetch!(opts, :bot_token)
    language = Keyword.get(opts, :language, "ru")
    reject_message = Keyword.get(opts, :reject_message)

    container = Druzhok.BotManager.container_name(instance_name)

    port = Port.open(
      {:spawn_executable, "/usr/bin/env"},
      [
        :binary, :exit_status, :use_stdio, :stderr_to_stdout,
        args: ["docker", "logs", "-f", "--since=5s", container]
      ]
    )

    schedule_format_check()

    {:ok, %{
      instance_name: instance_name,
      runtime: runtime_module,
      bot_token: bot_token,
      language: language,
      reject_message: reject_message,
      port: port,
      buffer: "",
      last_rejection_at: nil,
      started_at: System.monotonic_time(:millisecond),
      format_warned: false
    }}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    {lines, buffer} = split_lines(state.buffer <> data)

    state = Enum.reduce(lines, state, fn line, acc ->
      case acc.runtime.parse_log_rejection(line) do
        {:rejected, user_id} ->
          handle_rejection(acc, user_id)
          %{acc | last_rejection_at: System.monotonic_time(:millisecond)}
        :ignore ->
          acc
      end
    end)

    {:noreply, %{state | buffer: buffer}}
  end

  @impl true
  def handle_info({port, {:exit_status, _code}}, %{port: port} = state) do
    Logger.warning("LogWatcher port exited for #{state.instance_name}, stopping")
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:check_format, state) do
    now = System.monotonic_time(:millisecond)
    uptime = now - state.started_at

    if uptime > @format_warn_after and state.last_rejection_at == nil and not state.format_warned do
      Druzhok.CrashLog.insert(%{
        level: "warning",
        message: "LogWatcher for #{state.instance_name}: no rejection patterns matched in 24h — runtime log format may have changed",
        source: "Druzhok.LogWatcher",
        instance_name: state.instance_name
      })
      schedule_format_check()
      {:noreply, %{state | format_warned: true}}
    else
      schedule_format_check()
      {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if Port.info(state.port), do: Port.close(state.port)
    :ok
  end

  defp handle_rejection(state, user_id) do
    with {uid_int, ""} <- Integer.parse(user_id),
         {:ok, _pairing} <- Druzhok.Pairing.create_request(state.instance_name, uid_int) do
      send_rejection_message(state, user_id)
      Druzhok.Events.broadcast(state.instance_name, %{type: :pairing_request, user_id: user_id})
    else
      {:exists, _} -> :ok
      {:error, reason} -> Logger.warning("LogWatcher: pairing request failed: #{inspect(reason)}")
      _ -> :ok
    end
  end

  defp send_rejection_message(state, user_id) do
    text = if state.reject_message do
      String.replace(state.reject_message, "%{user_id}", user_id)
    else
      Druzhok.I18n.t(:reject_default, state.language, %{user_id: user_id})
    end

    case Druzhok.Telegram.API.send_message(state.bot_token, user_id, text) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("LogWatcher: failed to send rejection message to #{user_id}: #{inspect(reason)}")
    end
  end

  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.slice(parts, 0..-2//1), List.last(parts)}
  end

  defp schedule_format_check do
    Process.send_after(self(), :check_format, @format_check_interval)
  end
end
