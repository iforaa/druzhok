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

  def execute(%{"command" => command}, %{workspace: workspace}) do
    case System.cmd("bash", ["-c", command], cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "Exit code #{code}: #{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
