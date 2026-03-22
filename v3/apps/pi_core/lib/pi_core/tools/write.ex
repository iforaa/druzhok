defmodule PiCore.Tools.Write do
  alias PiCore.Tools.{Tool, PathGuard}

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
    case PathGuard.resolve(workspace, path) do
      {:ok, full_path} ->
        File.mkdir_p!(Path.dirname(full_path))
        File.write!(full_path, content)
        {:ok, "Written: #{path}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
