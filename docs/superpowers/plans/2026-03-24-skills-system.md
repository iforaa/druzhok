# Skills System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a skill system where SKILL.md files in workspace/skills/ are discovered, loaded into the system prompt catalog, and readable by the LLM on demand — with dashboard management and bot self-creation with approval.

**Architecture:** `PiCore.Skills.Loader` scans workspace/skills/ directories, parses frontmatter via regex, returns `{name, desc, path}` tuples. `Session.build_system_prompt` calls the loader and passes skills to `PromptBudget`. A new `SkillsTab` dashboard component provides CRUD for skill files. Bot-created skills require owner approval via `pending_approval` frontmatter flag.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-24-skills-system-design.md`

---

## File Structure

### New files (pi_core)
- `v3/apps/pi_core/lib/pi_core/skills/loader.ex` — scan workspace/skills/, parse frontmatter, return skill tuples
- `v3/apps/pi_core/test/pi_core/skills/loader_test.exs`

### New files (druzhok_web)
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/components/skills_tab.ex` — dashboard skill management

### Modified files
- `v3/apps/pi_core/lib/pi_core/session.ex` — call Loader from build_system_prompt
- `v3/apps/pi_core/lib/pi_core/prompt_budget.ex` — update return_skills preamble
- `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — add skills tab + events
- `v3/workspace-template/AGENTS.md` — add skills creation instructions

---

### Task 1: Skills Loader

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/skills/loader.ex`
- Create: `v3/apps/pi_core/test/pi_core/skills/loader_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
# v3/apps/pi_core/test/pi_core/skills/loader_test.exs
defmodule PiCore.Skills.LoaderTest do
  use ExUnit.Case

  alias PiCore.Skills.Loader

  @workspace System.tmp_dir!() |> Path.join("skills_loader_test_#{:rand.uniform(99999)}")

  setup do
    File.rm_rf!(@workspace)
    File.mkdir_p!(Path.join(@workspace, "skills"))
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  defp create_skill(name, frontmatter, body \\ "# Skill content") do
    dir = Path.join([@workspace, "skills", name])
    File.mkdir_p!(dir)
    content = "---\n#{frontmatter}\n---\n\n#{body}"
    File.write!(Path.join(dir, "SKILL.md"), content)
  end

  test "loads skills from workspace/skills/" do
    create_skill("weather", "name: weather\ndescription: Check weather")
    create_skill("translate", "name: translate\ndescription: Translate text")

    skills = Loader.load(@workspace)
    assert length(skills) == 2
    assert {"translate", "Translate text", "skills/translate/SKILL.md"} in skills
    assert {"weather", "Check weather", "skills/weather/SKILL.md"} in skills
  end

  test "returns empty list when skills/ does not exist" do
    workspace = Path.join(System.tmp_dir!(), "no_skills_#{:rand.uniform(99999)}")
    assert Loader.load(workspace) == []
  end

  test "skips skills without name in frontmatter" do
    create_skill("bad", "description: No name field")
    assert Loader.load(@workspace) == []
  end

  test "skips disabled skills" do
    create_skill("off", "name: off\ndescription: Disabled\nenabled: false")
    assert Loader.load(@workspace) == []
  end

  test "skips pending approval skills" do
    create_skill("pending", "name: pending\ndescription: Waiting\npending_approval: true")
    assert Loader.load(@workspace) == []
  end

  test "includes enabled skills by default" do
    create_skill("active", "name: active\ndescription: Active skill")
    skills = Loader.load(@workspace)
    assert length(skills) == 1
    assert {"active", "Active skill", "skills/active/SKILL.md"} in skills
  end

  test "skips invalid directory names" do
    create_skill("Valid-Name", "name: valid\ndescription: Valid")
    create_skill("UPPERCASE", "name: upper\ndescription: Upper")
    # Valid-Name has uppercase V, should be skipped
    # UPPERCASE should be skipped
    skills = Loader.load(@workspace)
    assert skills == []
  end

  test "accepts valid directory names" do
    create_skill("my-skill", "name: my-skill\ndescription: Dashed")
    create_skill("skill_2", "name: skill_2\ndescription: Underscored")
    skills = Loader.load(@workspace)
    assert length(skills) == 2
  end

  test "skips files over 256KB" do
    big_body = String.duplicate("x", 300_000)
    create_skill("huge", "name: huge\ndescription: Too big", big_body)
    assert Loader.load(@workspace) == []
  end

  test "returns sorted by name" do
    create_skill("zebra", "name: zebra\ndescription: Z")
    create_skill("alpha", "name: alpha\ndescription: A")
    skills = Loader.load(@workspace)
    assert [{"alpha", _, _}, {"zebra", _, _}] = skills
  end

  test "parse_frontmatter extracts fields" do
    content = "---\nname: test\ndescription: A test skill\nenabled: true\npending_approval: false\n---\n\n# Body"
    assert {:ok, "test", "A test skill", true, false} = Loader.parse_frontmatter(content)
  end

  test "parse_frontmatter defaults enabled to true" do
    content = "---\nname: test\ndescription: Desc\n---\n\nBody"
    assert {:ok, "test", "Desc", true, false} = Loader.parse_frontmatter(content)
  end

  test "parse_frontmatter returns error without frontmatter" do
    assert :error = Loader.parse_frontmatter("No frontmatter here")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/skills/loader_test.exs`
Expected: compilation error — `PiCore.Skills.Loader` not found

- [ ] **Step 3: Write the implementation**

```elixir
# v3/apps/pi_core/lib/pi_core/skills/loader.ex
defmodule PiCore.Skills.Loader do
  @moduledoc """
  Discovers and loads skills from workspace/skills/ directories.
  Each skill is a subdirectory containing a SKILL.md file with frontmatter.
  """

  @max_skill_size 256_000
  @name_pattern ~r/^[a-z0-9][a-z0-9_-]*$/

  @doc """
  Load all skills from workspace/skills/ directory.
  Returns a list of `{name, description, relative_path}` tuples.
  """
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

  @doc """
  Parse frontmatter from a SKILL.md file.
  Returns `{:ok, name, description, enabled, pending_approval}` or `:error`.
  """
  def parse_frontmatter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, frontmatter] ->
        name = extract_field(frontmatter, "name")
        description = extract_field(frontmatter, "description") || ""
        enabled = extract_bool(frontmatter, "enabled", true)
        pending = extract_bool(frontmatter, "pending_approval", false)

        if name do
          {:ok, name, description, enabled, pending}
        else
          :error
        end

      nil ->
        :error
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
```

- [ ] **Step 4: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/skills/loader_test.exs`
Expected: all PASS

- [ ] **Step 5: Commit**

Message: `add Skills.Loader for workspace skill discovery`

---

### Task 2: PromptBudget preamble + Session integration

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/prompt_budget.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex`

- [ ] **Step 1: Update PromptBudget return_skills preamble**

In `v3/apps/pi_core/lib/pi_core/prompt_budget.ex`, replace `return_skills/1`:

```elixir
defp return_skills(body) do
  """
  ## Available Skills

  Before replying, scan the skills below. If one clearly applies, read its SKILL.md at the listed path using `read`, then follow it. If none apply, skip.

  #{body}\
  """
end
```

- [ ] **Step 2: Update Session.build_system_prompt to load skills**

In `v3/apps/pi_core/lib/pi_core/session.ex`, update `build_system_prompt/5` (around line 300):

```elixir
defp build_system_prompt(loader, workspace, group, budget, model) do
  skills = PiCore.Skills.Loader.load(workspace)

  {prompt, _tokens} = PiCore.PromptBudget.build(workspace, %{
    budget_tokens: budget.system_prompt,
    group: group,
    skills: skills,
    read_fn: fn path -> File.read(Path.join(workspace, path)) end
  })

  # If PromptBudget returned empty (no workspace files), fall back to loader
  prompt = if prompt == "" do
    loader.load(workspace, %{group: group})
  else
    prompt
  end

  append_model_info(prompt, model)
end
```

- [ ] **Step 3: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/ --exclude slow`
Expected: all PASS

- [ ] **Step 4: Commit**

Message: `wire skills loader into session and prompt budget`

---

### Task 3: Dashboard SkillsTab component

**Files:**
- Create: `v3/apps/druzhok_web/lib/druzhok_web_web/live/components/skills_tab.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Create SkillsTab component**

```elixir
# v3/apps/druzhok_web/lib/druzhok_web_web/live/components/skills_tab.ex
defmodule DruzhokWebWeb.Live.Components.SkillsTab do
  use Phoenix.Component

  attr :skills, :list, default: []
  attr :instance_name, :string, required: true
  attr :editing_skill, :any, default: nil

  def skills_tab(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">Skills</h3>
        <div :if={@skills == []} class="text-sm text-gray-400">
          No skills yet. Create one below or let the bot create its own.
        </div>
        <div :for={skill <- @skills} class="flex items-center justify-between py-2 border-b border-gray-100 last:border-0">
          <div>
            <div class="text-sm font-medium">
              <%= skill.name %>
              <span :if={skill.pending} class="ml-2 text-xs text-amber-600 font-medium">Pending</span>
              <span :if={!skill.enabled} class="ml-2 text-xs text-gray-400 font-medium">Disabled</span>
            </div>
            <div class="text-xs text-gray-400"><%= skill.description %></div>
          </div>
          <div class="flex items-center gap-2">
            <button :if={skill.pending} phx-click="approve_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir}
                    class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-3 py-1 text-xs font-medium transition">
              Approve
            </button>
            <button phx-click="toggle_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir} phx-value-enabled={"#{!skill.enabled}"}
                    class="text-xs text-blue-600 hover:underline">
              <%= if skill.enabled, do: "Disable", else: "Enable" %>
            </button>
            <button phx-click="edit_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir}
                    class="text-xs text-blue-600 hover:underline">Edit</button>
            <button phx-click="delete_skill" phx-value-name={@instance_name} phx-value-skill={skill.dir}
                    data-confirm="Delete this skill?" class="text-xs text-red-600 hover:underline">Delete</button>
          </div>
        </div>
      </div>

      <div class="bg-white rounded-xl border border-gray-200 p-4">
        <h3 class="text-sm font-semibold mb-3">
          <%= if @editing_skill, do: "Edit Skill: #{@editing_skill.dir}", else: "Create Skill" %>
        </h3>
        <form phx-submit="save_skill" class="space-y-3">
          <input type="hidden" name="instance_name" value={@instance_name} />
          <input type="hidden" name="original_dir" value={@editing_skill && @editing_skill.dir} />
          <div class="grid grid-cols-2 gap-3">
            <div>
              <label class="block text-xs text-gray-500 mb-1">Name (lowercase, a-z, 0-9, hyphens)</label>
              <input name="skill_name" value={@editing_skill && @editing_skill.dir}
                     pattern="[a-z0-9][a-z0-9_-]*" required
                     class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono" />
            </div>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Description</label>
              <input name="description" value={@editing_skill && @editing_skill.description}
                     required class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm" />
            </div>
          </div>
          <div>
            <label class="block text-xs text-gray-500 mb-1">SKILL.md Content</label>
            <textarea name="content" rows="10" required
                      class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono resize-y"><%= @editing_skill && @editing_skill.content %></textarea>
          </div>
          <div class="flex items-center gap-3">
            <button type="submit" class="bg-gray-900 hover:bg-gray-800 text-white rounded-lg px-4 py-2 text-sm font-medium transition">
              <%= if @editing_skill, do: "Update", else: "Create" %>
            </button>
            <button :if={@editing_skill} type="button" phx-click="cancel_edit_skill"
                    class="text-sm text-gray-500 hover:text-gray-900">Cancel</button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Add skills tab to DashboardLive**

In `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`:

Add import at top:
```elixir
import DruzhokWebWeb.Live.Components.SkillsTab
```

Update `@valid_tabs`:
```elixir
@valid_tabs %{"logs" => :logs, "files" => :files, "security" => :security, "skills" => :skills}
```

Add to `mount/3` assigns:
```elixir
skills: [],
editing_skill: nil,
```

Add tab button in render (after the security tab button):
```heex
<button phx-click="tab" phx-value-tab="skills"
        class={"text-xs font-medium px-3 py-1.5 rounded-lg transition " <> if(@tab == :skills, do: "bg-gray-900 text-white", else: "text-gray-500 hover:text-gray-900")}>
  Skills
</button>
```

Add tab content panel:
```heex
<div :if={@tab == :skills}>
  <.skills_tab skills={@skills} instance_name={@selected} editing_skill={@editing_skill} />
</div>
```

- [ ] **Step 3: Add skill loading on instance select**

Find where `select_instance` event loads groups/files. Add skill loading there:

```elixir
skills: load_skills(name, socket),
```

And add the helper:
```elixir
defp load_skills(name, socket) do
  workspace = instance_workspace(name)
  skills_dir = Path.join(workspace, "skills")

  if File.dir?(skills_dir) do
    case File.ls(skills_dir) do
      {:ok, dirs} ->
        dirs
        |> Enum.filter(&File.dir?(Path.join(skills_dir, &1)))
        |> Enum.map(fn dir ->
          path = Path.join([skills_dir, dir, "SKILL.md"])
          case File.read(path) do
            {:ok, content} ->
              case PiCore.Skills.Loader.parse_frontmatter(content) do
                {:ok, name, desc, enabled, pending} ->
                  %{dir: dir, name: name, description: desc, enabled: enabled, pending: pending, content: content}
                :error ->
                  %{dir: dir, name: dir, description: "(invalid frontmatter)", enabled: false, pending: false, content: content}
              end
            {:error, _} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.name)

      _ -> []
    end
  else
    []
  end
end
```

- [ ] **Step 4: Add event handlers for skill CRUD**

```elixir
def handle_event("save_skill", params, socket) do
  name = socket.assigns.selected
  skill_name = params["skill_name"]
  description = params["description"]
  content = params["content"]
  original_dir = params["original_dir"]

  # Validate name
  if Regex.match?(~r/^[a-z0-9][a-z0-9_-]*$/, skill_name) do
    workspace = instance_workspace(name)
    dir = Path.join([workspace, "skills", skill_name])
    File.mkdir_p!(dir)

    # Build SKILL.md with frontmatter
    skill_content = "---\nname: #{skill_name}\ndescription: #{description}\n---\n\n#{content}"
    File.write!(Path.join(dir, "SKILL.md"), skill_content)

    # If renamed, delete old directory
    if original_dir && original_dir != "" && original_dir != skill_name do
      old_dir = Path.join([workspace, "skills", original_dir])
      File.rm_rf!(old_dir)
    end

    {:noreply, assign(socket, skills: load_skills(name, socket), editing_skill: nil)}
  else
    {:noreply, socket}
  end
end

def handle_event("edit_skill", %{"name" => name, "skill" => dir}, socket) do
  skill = Enum.find(socket.assigns.skills, &(&1.dir == dir))
  {:noreply, assign(socket, editing_skill: skill)}
end

def handle_event("cancel_edit_skill", _, socket) do
  {:noreply, assign(socket, editing_skill: nil)}
end

def handle_event("delete_skill", %{"name" => name, "skill" => dir}, socket) do
  workspace = instance_workspace(name)
  File.rm_rf!(Path.join([workspace, "skills", dir]))
  {:noreply, assign(socket, skills: load_skills(name, socket), editing_skill: nil)}
end

def handle_event("approve_skill", %{"name" => name, "skill" => dir}, socket) do
  workspace = instance_workspace(name)
  path = Path.join([workspace, "skills", dir, "SKILL.md"])
  case File.read(path) do
    {:ok, content} ->
      updated = String.replace(content, ~r/^pending_approval:\s*true$/m, "pending_approval: false")
      File.write!(path, updated)
    _ -> :ok
  end
  {:noreply, assign(socket, skills: load_skills(name, socket))}
end

def handle_event("toggle_skill", %{"name" => name, "skill" => dir, "enabled" => enabled_str}, socket) do
  workspace = instance_workspace(name)
  path = Path.join([workspace, "skills", dir, "SKILL.md"])
  new_enabled = enabled_str == "true"
  case File.read(path) do
    {:ok, content} ->
      updated = if String.contains?(content, "enabled:") do
        String.replace(content, ~r/^enabled:\s*(true|false)$/m, "enabled: #{new_enabled}")
      else
        String.replace(content, "---\n\n", "enabled: #{new_enabled}\n---\n\n", global: false)
      end
      File.write!(path, updated)
    _ -> :ok
  end
  {:noreply, assign(socket, skills: load_skills(name, socket))}
end
```

- [ ] **Step 5: Compile and verify**

Run: `cd v3 && mix compile`
Expected: clean compilation

- [ ] **Step 6: Commit**

Message: `add SkillsTab dashboard component with CRUD`

---

### Task 4: AGENTS.md template update

**Files:**
- Modify: `v3/workspace-template/AGENTS.md`

- [ ] **Step 1: Add skills section to AGENTS.md template**

Read `v3/workspace-template/AGENTS.md`. Add before the "Красные линии" section:

```markdown
## Навыки (Skills)

Ты можешь создавать навыки — инструкции для себя в будущем.
Создай файл `skills/<name>/SKILL.md` с YAML-заголовком:

```
---
name: имя-навыка
description: Краткое описание
pending_approval: true
---

# Инструкции навыка
...
```

Навык станет активным после одобрения владельцем в дашборде.
```

- [ ] **Step 2: Commit**

Message: `add skills creation instructions to AGENTS.md template`

---

### Task 5: Full test run and cleanup

- [ ] **Step 1: Run full test suite**

Run: `cd v3 && mix test --exclude slow`

- [ ] **Step 2: Check for compiler warnings**

Run: `cd v3 && mix compile --warnings-as-errors 2>&1 | grep "warning:" | grep -v "apps/data\|Reminder\|catch.*rescue\|unused.*data\|never match\|Bcrypt\|telegram_pid\|clauses.*handle_info"`

- [ ] **Step 3: Fix any issues and commit**

Message: `fix warnings from skills system`
