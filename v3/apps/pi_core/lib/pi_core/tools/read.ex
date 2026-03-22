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

  def execute(%{"path" => path}, %{sandbox: %{read_file: read_fn}}) do
    sandbox_path = sandbox_path(path)

    case read_fn.(sandbox_path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
    end
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

  defp sandbox_path("/" <> _ = path), do: path
  defp sandbox_path(path), do: "/workspace/#{path}"
end
