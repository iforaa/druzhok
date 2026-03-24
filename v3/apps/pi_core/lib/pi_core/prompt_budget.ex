defmodule PiCore.PromptBudget do
  @moduledoc """
  Budget-aware system prompt construction.
  Allocates space to identity, instructions, and skills within a token budget.
  """

  alias PiCore.TokenEstimator
  alias PiCore.Truncate

  @identity_files ["IDENTITY.md", "SOUL.md"]
  @instruction_files ["AGENTS.md", "USER.md", "BOOTSTRAP.md"]

  def build(workspace, opts) do
    budget_tokens = opts[:budget_tokens] || 5_000
    budget_chars = budget_tokens * 4  # inverse of byte_size/4
    group = opts[:group] || false
    skills = opts[:skills] || []
    read_fn = opts[:read_fn] || (&File.read/1)

    # Phase 1: Identity (highest priority — up to 20% of budget)
    identity_budget = trunc(budget_chars * 0.20)
    identity = load_files(workspace, @identity_files, identity_budget, read_fn)

    remaining = budget_chars - byte_size(identity)

    # Phase 2: Instructions (up to 40% of budget per file)
    instruction_files = if group, do: @instruction_files -- ["USER.md"], else: @instruction_files
    per_file_cap = trunc(budget_chars * 0.40)
    instructions = load_files(workspace, instruction_files, per_file_cap, read_fn)

    remaining = remaining - byte_size(instructions)

    # Phase 3: Skills catalog (remaining space)
    skills_section = if skills != [] and remaining > 100 do
      format_skills(skills, remaining)
    else
      ""
    end

    prompt = [identity, instructions, skills_section]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")

    tokens = TokenEstimator.estimate(prompt)
    {prompt, tokens}
  end

  defp load_files(workspace, files, per_file_cap, read_fn) do
    files
    |> Enum.map(fn file ->
      path = if read_fn == (&File.read/1), do: Path.join(workspace, file), else: file
      case read_fn.(path) do
        {:ok, content} -> Truncate.head_tail(content, per_file_cap)
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp format_skills(skills, remaining_chars) do
    full = format_skills_full(skills)
    if byte_size(full) <= remaining_chars do
      return_skills(full)
    else
      compact = format_skills_compact(skills)
      if byte_size(compact) <= remaining_chars do
        return_skills(compact)
      else
        minimal = format_skills_minimal(skills)
        if byte_size(minimal) <= remaining_chars do
          return_skills(minimal)
        else
          Truncate.head_tail(return_skills(minimal), remaining_chars)
        end
      end
    end
  end

  defp return_skills(body) do
    "## Available Skills\n\nBefore replying, scan the skills below. If one clearly applies, read its SKILL.md at the listed path using `read`, then follow it. If none apply, skip.\n\n#{body}"
  end

  defp format_skills_full(skills) do
    Enum.map_join(skills, "\n", fn {name, desc, path} ->
      "- **#{name}**: #{desc} (`#{path}`)"
    end)
  end

  defp format_skills_compact(skills) do
    Enum.map_join(skills, "\n", fn {name, _desc, path} ->
      "- #{name} (`#{path}`)"
    end)
  end

  defp format_skills_minimal(skills) do
    Enum.map_join(skills, "\n", fn {name, _desc, _path} ->
      "- #{name}"
    end)
  end
end
