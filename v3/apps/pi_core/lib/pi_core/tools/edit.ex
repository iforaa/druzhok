defmodule PiCore.Tools.Edit do
  alias PiCore.Tools.Tool

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

  def execute(%{"path" => path, "old_string" => old, "new_string" => new}, %{workspace: workspace}) do
    full_path = Path.join(workspace, path) |> Path.expand()
    workspace_abs = Path.expand(workspace)
    if String.starts_with?(full_path, workspace_abs) do
      case File.read(full_path) do
        {:ok, content} ->
          if String.contains?(content, old) do
            File.write!(full_path, String.replace(content, old, new, global: false))
            {:ok, "Edited: #{path}"}
          else
            {:error, "String not found in #{path}"}
          end
        {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
      end
    else
      {:error, "Access denied: path outside workspace"}
    end
  end
end
