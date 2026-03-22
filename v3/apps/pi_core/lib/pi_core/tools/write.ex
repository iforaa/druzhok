defmodule PiCore.Tools.Write do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "write",
      description: "Write content to a file. Creates directories if needed.",
      parameters: %{
        path: %{type: :string, description: "File path relative to workspace"},
        content: %{type: :string, description: "Content to write"}
      },
      execute: &execute/2
    }
  end

  def execute(%{"path" => path, "content" => content}, %{workspace: workspace}) do
    full_path = Path.join(workspace, path) |> Path.expand()
    workspace_abs = Path.expand(workspace)
    if String.starts_with?(full_path, workspace_abs) do
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
      {:ok, "Written: #{path}"}
    else
      {:error, "Access denied: path outside workspace"}
    end
  end
end
