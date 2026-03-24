defmodule PiCore.Skills.Loader do
  @max_skill_size 256_000
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  def load(workspace) do
    skills_dir = Path.join(workspace, "skills")

    if File.dir?(skills_dir) do
      case File.ls(skills_dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(fn dir ->
            Regex.match?(@name_pattern, dir) and File.dir?(Path.join(skills_dir, dir))
          end)
          |> Enum.flat_map(fn dir ->
            path = Path.join([skills_dir, dir, "SKILL.md"])
            relative = "skills/#{dir}/SKILL.md"
            case load_skill(path, relative) do
              {:ok, skill} -> [skill]
              :skip -> []
            end
          end)
          |> Enum.sort_by(fn {name, _, _} -> name end)
        {:error, _} -> []
      end
    else
      []
    end
  end

  defp load_skill(path, relative_path) do
    with {:ok, content} <- File.read(path),
         true <- byte_size(content) <= @max_skill_size,
         {:ok, name, description, enabled, pending} <- parse_frontmatter(content),
         true <- enabled,
         false <- pending do
      {:ok, {name, description, relative_path}}
    else
      _ -> :skip
    end
  end

  def parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, frontmatter] ->
        name = extract_field(frontmatter, "name")
        description = extract_field(frontmatter, "description") || ""
        enabled = extract_bool(frontmatter, "enabled", true)
        pending = extract_bool(frontmatter, "pending_approval", false)
        if name, do: {:ok, name, description, enabled, pending}, else: :error
      nil -> :error
    end
  end

  defp extract_field(text, field) do
    case Regex.run(~r/^#{field}:\s*(.+)$/m, text) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp extract_bool(text, field, default) do
    case extract_field(text, field) do
      "true" -> true
      "false" -> false
      nil -> default
    end
  end
end
