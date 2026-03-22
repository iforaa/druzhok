defmodule PiCore.Tools.Grep do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "grep",
      description: "Search for a pattern in files. Returns matching lines with file paths and line numbers.",
      parameters: %{
        pattern: %{type: :string, description: "Search pattern (regex supported)"},
        path: %{type: :string, description: "File or directory to search in (relative to workspace). Default: '.'"}
      },
      execute: &execute/2
    }
  end

  def execute(%{"pattern" => pattern} = args, %{workspace: workspace}) do
    search_path = Path.join(workspace, args["path"] || ".")
    workspace_abs = Path.expand(workspace)
    search_abs = Path.expand(search_path)

    if not String.starts_with?(search_abs, workspace_abs) do
      {:error, "Access denied: path outside workspace"}
    else
      case System.cmd("grep", ["-rn", "--include=*", pattern, search_abs],
             stderr_to_stdout: true, env: [{"LC_ALL", "C"}]) do
        {output, 0} ->
          # Make paths relative to workspace
          lines = output
          |> String.split("\n", trim: true)
          |> Enum.map(&String.replace(&1, search_abs <> "/", ""))
          |> Enum.take(50)
          |> Enum.join("\n")
          {:ok, lines}

        {_, 1} ->
          {:ok, "No matches found for: #{pattern}"}

        {output, _} ->
          {:error, "grep error: #{String.slice(output, 0, 200)}"}
      end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
