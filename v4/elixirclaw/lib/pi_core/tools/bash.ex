defmodule PiCore.Tools.Bash do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "bash",
      description: "Run a bash command.",
      parameters: %{command: %{type: :string, description: "Bash command to execute"}},
      execute: &execute/2
    }
  end

  def execute(%{"command" => command}, context) do
    timeout = Map.get(context, :bash_timeout_ms, PiCore.Config.bash_timeout_ms())

    case context do
      %{sandbox: %{exec: exec_fn}} ->
        run_with_timeout(fn -> run_sandbox(command, exec_fn) end, timeout)

      %{workspace: workspace} ->
        run_with_timeout(fn -> run_local(command, workspace) end, timeout)
    end
  end

  defp run_sandbox(command, exec_fn) do
    case exec_fn.(command) do
      {:ok, %{exit_code: 0, stdout: stdout}} -> {:ok, stdout}
      {:ok, %{exit_code: code, stderr: stderr}} -> {:error, "Exit code #{code}: #{stderr}"}
      {:error, reason} -> {:error, "Sandbox error: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_local(command, workspace) do
    case System.cmd("bash", ["-c", command], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "Exit code #{code}: #{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp run_with_timeout(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, "Command timed out after #{div(timeout, 1000)}s"}
    end
  end
end
