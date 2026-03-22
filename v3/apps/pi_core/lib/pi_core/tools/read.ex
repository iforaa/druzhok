defmodule PiCore.Tools.Read do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "read",
      description: "Read a file from the workspace.",
      parameters: %{path: %{type: :string, description: "File path relative to workspace"}},
      execute: &execute/2
    }
  end

  def execute(%{"path" => path}, %{workspace: workspace}) do
    full_path = Path.join(workspace, path) |> Path.expand()
    workspace_abs = Path.expand(workspace)
    if String.starts_with?(full_path, workspace_abs) do
      case File.read(full_path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
      end
    else
      {:error, "Access denied: path outside workspace"}
    end
  end
end
