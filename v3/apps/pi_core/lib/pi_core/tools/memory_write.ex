defmodule PiCore.Tools.MemoryWrite do
  alias PiCore.Tools.Tool

  def new(_opts \\ %{}) do
    %Tool{
      name: "memory_write",
      description: "Save a fact, preference, decision, or important context to memory. Written to daily memory file (memory/YYYY-MM-DD.md) by default. Use when the user says 'remember this' or when you learn something worth preserving.",
      parameters: %{
        content: %{type: :string, description: "What to remember (concise, factual)"},
        file: %{type: :string, description: "Target file (optional, defaults to today's daily file). Must be within memory/ directory."}
      },
      execute: fn args, context -> execute(args, context) end
    }
  end

  def execute(%{"content" => content} = args, context) do
    workspace = context[:workspace]
    timezone = context[:timezone] || "UTC"
    file = args["file"] || default_daily_file(timezone)

    unless String.starts_with?(file, "memory/") do
      {:error, "Writes must be within memory/ directory. Got: #{file}"}
    else
      full_path = Path.join(workspace, file)
      resolved = Path.expand(full_path)
      workspace_resolved = Path.expand(workspace)

      unless String.starts_with?(resolved, workspace_resolved) do
        {:error, "Path traversal detected"}
      else
        File.mkdir_p!(Path.dirname(full_path))
        timestamp = now_in_timezone(timezone)
        entry = "\n### #{timestamp}\n\n#{content}\n"
        File.write!(full_path, entry, [:append])
        {:ok, "Saved to #{file}"}
      end
    end
  end

  defp default_daily_file(timezone) do
    date = today_in_timezone(timezone)
    "memory/#{date}.md"
  end

  defp today_in_timezone("UTC"), do: Date.utc_today() |> Date.to_string()
  defp today_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> dt |> DateTime.to_date() |> Date.to_string()
      {:error, _} -> Date.utc_today() |> Date.to_string()
    end
  end

  defp now_in_timezone("UTC"), do: DateTime.utc_now() |> Calendar.strftime("%H:%M")
  defp now_in_timezone(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> Calendar.strftime(dt, "%H:%M")
      {:error, _} -> DateTime.utc_now() |> Calendar.strftime("%H:%M")
    end
  end
end
