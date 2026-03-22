defmodule PiCore.Tools.Read do
  alias PiCore.Tools.{Tool, PathGuard}

  def new do
    %Tool{
      name: "read",
      description: "Read a file from the workspace.",
      parameters: %{path: %{type: :string, description: "File path relative to workspace"}},
      execute: &execute/2
    }
  end

  def execute(%{"path" => path}, %{workspace: workspace}) do
    with {:ok, full_path} <- PathGuard.resolve(workspace, path),
         {:ok, content} <- File.read(full_path) do
      {:ok, content}
    else
      {:error, reason} when is_atom(reason) -> {:error, "Cannot read #{path}: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end
end
