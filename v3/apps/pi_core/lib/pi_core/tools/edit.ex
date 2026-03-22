defmodule PiCore.Tools.Edit do
  alias PiCore.Tools.{Tool, PathGuard}

  def new do
    %Tool{
      name: "edit",
      description: "Find and replace text in a file.",
      parameters: %{
        path: %{type: :string, description: "File path"},
        old_string: %{type: :string, description: "Text to find"},
        new_string: %{type: :string, description: "Replacement text"}
      },
      execute: &execute/2
    }
  end

  def execute(
        %{"path" => path, "old_string" => old, "new_string" => new},
        %{sandbox: %{read_file: read_fn, write_file: write_fn}}
      ) do
    sandbox_path = sandbox_path(path)

    case read_fn.(sandbox_path) do
      {:ok, content} ->
        if String.contains?(content, old) do
          case write_fn.(sandbox_path, String.replace(content, old, new, global: false)) do
            :ok -> {:ok, "Edited: #{path}"}
            {:error, reason} -> {:error, "Cannot write #{path}: #{reason}"}
          end
        else
          {:error, "String not found in #{path}"}
        end

      {:error, reason} ->
        {:error, "Cannot read #{path}: #{reason}"}
    end
  end

  def execute(%{"path" => path, "old_string" => old, "new_string" => new}, %{workspace: workspace}) do
    with {:ok, full_path} <- PathGuard.resolve(workspace, path),
         {:ok, content} <- File.read(full_path) do
      if String.contains?(content, old) do
        File.write!(full_path, String.replace(content, old, new, global: false))
        {:ok, "Edited: #{path}"}
      else
        {:error, "String not found in #{path}"}
      end
    else
      {:error, reason} when is_atom(reason) -> {:error, "Cannot read #{path}: #{reason}"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sandbox_path(path), do: PiCore.Tools.PathGuard.sandbox_path(path)
end
