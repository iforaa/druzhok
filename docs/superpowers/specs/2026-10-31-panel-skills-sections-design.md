# Panel: my skills and system skills

Date: 2026-10-31. Status: draft for review. Repo: druzhok. No migration, no new flag.

## Goal

The owner asked for skills split into theirs and the ones provided by the system, theirs first. Today the panel lists
only the bot's own skills and gives system ones as a count («встроенные: 40»).

## Decisions

| Item | Decision |
|---|---|
| What is "system" | A skill whose front-matter `name` is in `skills/.bundled_manifest`, the rule `Panel.skills_scan/1` already uses |
| What is "mine" | Everything else below `skills/`: written by the bot, or installed |
| Order | «Мои» first, then «Системные». Each sorted as now, by category then name |
| Opening | Both can be opened and read. Today `Panel.skill/2` finds only own skills |
| Editing | Only «Мои» (see the editable pages spec). System skills stay read-only |
| A system skill the bot changed | Stays under «Системные»: it is still in the manifest |
| No own skills | «Мои» says «Бот пока ничего не добавил. Попросите его научиться чему-нибудь» |

## Server (`Druzhok.Panel`, `PanelController`)

- `skills_scan/1` keeps full entries for both groups, each capped at `@max_skills`. Today it reduces system ones to names.
- `GET /app/api/skills` becomes `{"skills": [...own], "system": [...bundled]}`. `skills` keeps its meaning, so a page
  already open keeps working during a deploy.
- `GET /app/api/skills/:name` and `/:category/:name` look in both groups.
- `GET /app/api/files` keeps `skills: {own, bundled}`.

## Page (`memory.tsx`, `api.ts`)

- The Навыки row opens whenever `own + bundled > 0`. Its line stays `добавленные: N · встроенные: M`, reworded
  `мои: N · системные: M`.
- The screen shows the two sections with labels «Мои» and «Системные». The hint saying built-in ones are not shown goes.

## Tests

`panel_test.exs` and `panel_api_test.exs`: both groups returned and in order, a bundled skill opens, a path outside both
groups is 404, the `skills` key is unchanged.

## Not doing

Turning system skills off, searching or collapsing the list, per-category grouping beyond today's subtitle.
