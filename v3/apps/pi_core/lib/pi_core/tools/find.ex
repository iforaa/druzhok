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
