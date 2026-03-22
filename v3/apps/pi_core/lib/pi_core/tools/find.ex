defmodule PiCore.Tools.Find do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "find",
      description: "Find files matching a glob pattern in the workspace. Returns file paths.",
      parameters: %{
        pattern: %{type: :string, description: "Glob pattern (e.g. '**/*.py', 'src/**/*.ex')"}
      },
      execute: &execute/2
    }
  end

  def execute(%{"pattern" => pattern}, %{sandbox: %{exec: exec_fn}}) do
    case exec_fn.("find /workspace -path '#{pattern}' -type f 2>/dev/null | head -100") do
      {:ok, %{exit_code: _, stdout: stdout}} ->
        results = stdout
        |> String.split("\n", trim: true)
        |> Enum.map(&String.replace_leading(&1, "/workspace/", ""))
        |> Enum.sort()

        if results == [] do
          {:ok, "No files found matching: #{pattern}"}
        else
          {:ok, Enum.join(results, "\n")}
        end

      {:error, reason} ->
        {:error, "Sandbox error: #{reason}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def execute(%{"pattern" => pattern}, %{workspace: workspace}) do
    full_pattern = Path.join(workspace, pattern)

    results = Path.wildcard(full_pattern)
    |> Enum.map(&Path.relative_to(&1, workspace))
    |> Enum.sort()
    |> Enum.take(100)

    if results == [] do
      {:ok, "No files found matching: #{pattern}"}
    else
      {:ok, Enum.join(results, "\n")}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
