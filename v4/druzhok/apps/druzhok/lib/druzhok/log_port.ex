defmodule Druzhok.LogPort do
  @moduledoc """
  Shared `docker logs -f` tailing primitive used by LogWatcher.

  Owns a Port, buffers split lines, strips ANSI escapes, and hands complete
  lines back to the caller. Reconnect-on-exit is handled by the parent
  GenServer (which knows what to do when the underlying container is gone).

  Usage from a GenServer:

      def init(_) do
        log_port = LogPort.open(container)
        {:ok, %{log_port: log_port, ...}}
      end

      def handle_info({port, {:data, data}}, %{log_port: %{port: port}} = state) do
        {lines, log_port} = LogPort.handle_data(state.log_port, data)
        Enum.each(lines, &process_line(&1, state))
        {:noreply, %{state | log_port: log_port}}
      end

      def handle_info({port, {:exit_status, _}}, %{log_port: %{port: port}} = state) do
        Process.send_after(self(), :reconnect, 5_000)
        {:noreply, state}
      end

      def handle_info(:reconnect, state) do
        {:noreply, %{state | log_port: LogPort.reopen(state.log_port)}}
      end

      def terminate(_, state), do: LogPort.close(state.log_port)
  """

  defstruct [:container, :port, buffer: ""]

  @ansi_pattern ~r/\x1b\[[0-9;]*m/

  def open(container) when is_binary(container) do
    %__MODULE__{container: container, port: spawn_port(container)}
  end

  def reopen(%__MODULE__{container: container}), do: open(container)

  def close(%__MODULE__{port: port}) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Feed a chunk of bytes from the port. Returns `{complete_lines, updated_struct}`
  with ANSI escapes stripped from each line.
  """
  def handle_data(%__MODULE__{} = lp, data) do
    binary = lp.buffer <> to_binary(data)
    parts = String.split(binary, "\n")
    {complete, [partial]} = Enum.split(parts, -1)
    {Enum.map(complete, &strip_ansi/1), %{lp | buffer: partial}}
  end

  defp to_binary(data) when is_binary(data), do: data
  defp to_binary(data), do: to_string(data)

  defp strip_ansi(line), do: Regex.replace(@ansi_pattern, line, "")

  defp spawn_port(container) do
    Port.open(
      {:spawn_executable, "/usr/bin/env"},
      [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        args: ["docker", "logs", "-f", "--since=5s", container]
      ]
    )
  end
end
