# Skills System for Druzhok v3

## Context

Druzhok v3 has a prompt budget system with 3-tier skill formatting (full → compact → minimal) but no actual skill loading, discovery, or management. OpenClaw has a mature skill system based on SKILL.md files with YAML frontmatter. This design adds a minimal skill system following the same pattern.

## Design Principles

- **Pure filesystem** — no DB tables for skills. SKILL.md files are the single source of truth.
- **Frontmatter for metadata** — enabled/disabled, pending approval, all controlled via YAML in the file.
- **Lazy loading** — only skill catalog (name + description + path) in system prompt. LLM reads full SKILL.md on demand via existing `read` tool.
- **Dashboard as file editor** — creates/edits/deletes SKILL.md files on disk. No special storage layer.

## 1. Skill Format

Each skill is a subdirectory of `workspace/skills/` containing a `SKILL.md` file:

```
workspace/skills/
├── weather/
│   └── SKILL.md
├── code-review/
│   └── SKILL.md
└── summarize/
    └── SKILL.md
```

### SKILL.md frontmatter

```yaml
---
name: weather
description: Check weather for any city using wttr.in
enabled: true
pending_approval: false
---

# Weather Skill

When the user asks about weather, use curl to fetch from wttr.in:

```bash
curl -s "wttr.in/CityName?format=3"
```

Report the result naturally.
```

**Fields**:

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `name` | string | required | Skill identifier, used in catalog |
| `description` | string | required | Shown to LLM in catalog |
| `enabled` | boolean | `true` | Loader skips if `false` |
| `pending_approval` | boolean | `false` | Loader skips if `true` (bot-created, awaiting approval) |

Max file size: 256KB.

## 2. Skill Loader

**Module**: `PiCore.Skills.Loader`

**Function**: `load(workspace) :: [{name, description, relative_path}]`

Scans `workspace/skills/` for subdirectories containing `SKILL.md`. Parses frontmatter using regex (no YAML library — frontmatter is flat key-value pairs only). Returns tuples.

**Path format**: Always `skills/<name>/SKILL.md` (no leading `./`). This format works with both the local `read` tool (via `PathGuard.resolve`) and Docker sandbox mode.

**Name validation**: Directory names must match `^[a-z0-9][a-z0-9_-]*$`. Directories that don't match are skipped.

**Rules**:
- Skip if directory name fails validation
- Skip if no `name` in frontmatter
- Skip if `enabled: false`
- Skip if `pending_approval: true`
- Skip if file > 256KB
- If `workspace/skills/` does not exist, return `[]`
- Sort by name for deterministic ordering

**Frontmatter parsing**: Regex-based, no YAML dependency. Simple `key: value` extraction for the 4 supported fields. Boolean values parsed from `true`/`false` strings.

**Called from `build_system_prompt`** (not just init) — this ensures skills are refreshed on model change and any system prompt rebuild. `build_system_prompt` already exists in Session and is called from both `init/1` and `handle_cast({:set_model, ...})`.

### System prompt integration

Skills appear in the system prompt via `PromptBudget`:

```
## Available Skills

Before replying, scan the skills below. If one applies, read its SKILL.md file, then follow it.

- **weather**: Check weather for any city (`skills/weather/SKILL.md`)
- **code-review**: Review code for quality issues (`skills/code-review/SKILL.md`)
```

The LLM reads the full SKILL.md on demand using the existing `read` tool. No new tools needed.

## 3. Dashboard — SkillsTab

A new LiveView component in the dashboard for managing skills.

**Features**:
- **List**: Show all skills in `workspace/skills/` with name, description, status (enabled/disabled/pending)
- **Create**: Name + description + content textarea → writes `workspace/skills/<name>/SKILL.md`
- **Edit**: Load SKILL.md into textarea, save back to disk
- **Enable/Disable**: Toggle `enabled:` field in frontmatter
- **Approve**: Set `pending_approval: false` in frontmatter (for bot-created skills)
- **Delete**: Remove the skill directory

Dashboard reads/writes files via the instance workspace path. For Docker sandbox instances, file operations must go through the sandbox module (same pattern as the existing FileBrowser component). No DB involvement.

**Validation**: Skill name must match `^[a-z0-9][a-z0-9_-]*$`. Content must be under 256KB. Dashboard enforces both on create/edit.

## 4. Bot Skill Creation

The bot creates skills using the existing `write` tool. It writes `workspace/skills/<name>/SKILL.md` with `pending_approval: true` in the frontmatter.

The skill is invisible to the LLM until the owner approves in the dashboard (which sets `pending_approval: false`).

**AGENTS.md addition**:
```
## Навыки (Skills)

Ты можешь создавать навыки — инструкции для себя в будущем.
Создай файл `skills/<name>/SKILL.md` с YAML-заголовком:
- name, description, pending_approval: true
Навык станет активным после одобрения владельцем в дашборде.
```

## 5. PromptBudget Integration

`PromptBudget.build/2` already accepts `skills` as `[{name, desc, path}]` tuples and formats them with the 3-tier budget system. Update `return_skills/1` to include a preamble instruction between the header and the skill list:

```
## Available Skills

Before replying, scan the skills below. If one clearly applies, read its SKILL.md at the listed path using `read`, then follow it. If none apply, skip.

- **weather**: Check weather for any city (`skills/weather/SKILL.md`)
- **code-review**: Review code for quality issues (`skills/code-review/SKILL.md`)
```

## New Modules

| Module | App | Purpose |
|--------|-----|---------|
| `PiCore.Skills.Loader` | pi_core | Scan workspace/skills/, parse frontmatter, return skill tuples |
| `DruzhokWebWeb.Live.Components.SkillsTab` | druzhok_web | Dashboard component for skill CRUD |

## Modified Modules

| Module | Changes |
|--------|---------|
| `PiCore.Session` | Call `Skills.Loader.load/1` inside `build_system_prompt`, pass to PromptBudget |
| `PiCore.PromptBudget` | Add preamble instruction to skills section |
| `DruzhokWebWeb.DashboardLive` | Add SkillsTab to dashboard tabs, handle skill events |
| Workspace template `AGENTS.md` | Add skills creation instructions |
