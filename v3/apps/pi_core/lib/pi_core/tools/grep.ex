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

  def execute(%{"pattern" => pattern} = args, %{sandbox: %{exec: exec_fn}}) do
    search_path = args["path"] || "."
    sandbox_path = if String.starts_with?(search_path, "/"), do: search_path, else: "/workspace/#{search_path}"

    case exec_fn.("grep -rn --include='*' #{inspect(pattern)} #{sandbox_path} 2>/dev/null | head -50") do
      {:ok, %{exit_code: 0, stdout: stdout}} ->
        lines = stdout
        |> String.split("\n", trim: true)
        |> Enum.map(&String.replace(&1, sandbox_path <> "/", ""))
        |> Enum.take(50)
        |> Enum.join("\n")

        {:ok, lines}

      {:ok, %{exit_code: 1}} ->
        {:ok, "No matches found for: #{pattern}"}

      {:ok, %{exit_code: _, stderr: stderr}} ->
        {:error, "grep error: #{String.slice(stderr, 0, 200)}"}

      {:error, reason} ->
        {:error, "Sandbox error: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
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
