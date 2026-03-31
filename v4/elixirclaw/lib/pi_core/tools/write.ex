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

  def execute(%{"path" => path, "content" => content}, %{sandbox: %{write_file: write_fn}}) do
    sandbox_path = sandbox_path(path)

    case write_fn.(sandbox_path, content) do
      :ok -> {:ok, "Written: #{path}"}
      {:ok, _} -> {:ok, "Written: #{path}"}
      {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
    end
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

  defp sandbox_path(path), do: PiCore.Tools.PathGuard.sandbox_path(path)
end
