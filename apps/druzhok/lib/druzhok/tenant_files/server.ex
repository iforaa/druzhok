defmodule Druzhok.TenantFiles.Server do
  @moduledoc """
  One `tenant-fs --serve` process kept open, so a file call costs a message
  and not a sudo and a Python start each time (`Druzhok.TenantFiles`).

  The helper is started on the first request and again after it died; it ends
  by itself when this process does (its stdin closes). One request at a time
  per server; `Druzhok.TenantFiles` spreads callers over a few of them and
  falls back to a one-off helper run when a server cannot answer.
  """
  use GenServer
  require Logger

  # A job in the helper is cut off after 60 s; several may be in one request.
  @call_timeout 150_000
  @size 3

  def child_specs do
    for i <- 0..(@size - 1),
        do: Supervisor.child_spec({__MODULE__, i}, id: {__MODULE__, i})
  end

  def start_link(i), do: GenServer.start_link(__MODULE__, nil, name: name(i))

  defp name(i), do: :"#{__MODULE__}.#{i}"

  @doc """
  The helper's answer to `request` (both JSON binaries), or `:error` when no
  server runs or its helper did not answer. `cmd` is the helper's command line.
  """
  def request(cmd, request) do
    server = name(:erlang.phash2(self(), @size))

    if Process.whereis(server) do
      try do
        GenServer.call(server, {:request, cmd, request}, @call_timeout + 5_000)
      catch
        :exit, _ -> :error
      end
    else
      :error
    end
  end

  @impl true
  def init(nil), do: {:ok, %{port: nil, cmd: nil}}

  @impl true
  def handle_call({:request, cmd, request}, _from, state) do
    state = open(state, cmd)

    if is_port(state.port) and send_request(state.port, request) do
      port = state.port

      receive do
        {^port, {:data, answer}} ->
          {:reply, {:ok, answer}, state}

        {^port, {:exit_status, status}} ->
          Logger.warning("[tenant-fs] the helper exited #{status}")
          {:reply, :error, %{state | port: nil}}
      after
        @call_timeout ->
          Logger.warning("[tenant-fs] the helper did not answer; starting another")
          {:reply, :error, close(state)}
      end
    else
      {:reply, :error, close(state)}
    end
  end

  # The helper died between two requests, or sent something nobody asked for.
  @impl true
  def handle_info({port, {:exit_status, _}}, %{port: port} = state),
    do: {:noreply, %{state | port: nil}}

  def handle_info({port, {:data, _}}, %{port: port} = state), do: {:noreply, close(state)}
  def handle_info(_other, state), do: {:noreply, state}

  # False when the port has just closed.
  defp send_request(port, request) do
    Port.command(port, request)
  rescue
    ArgumentError -> false
  end

  # A changed command (tests set their own) gets a helper of its own.
  defp open(%{port: port, cmd: cmd} = state, cmd) when is_port(port), do: state

  defp open(state, [bin | args] = cmd) do
    state = close(state)

    case System.find_executable(bin) do
      nil ->
        %{state | cmd: cmd}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            {:packet, 4},
            args: args ++ ["--serve"]
          ])

        %{state | port: port, cmd: cmd}
    end
  rescue
    e ->
      Logger.warning("[tenant-fs] cannot start the helper: #{Exception.message(e)}")
      %{state | port: nil, cmd: cmd}
  end

  defp close(%{port: port} = state) when is_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    %{state | port: nil}
  end

  defp close(state), do: state
end
