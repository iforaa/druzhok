# The bot's voice: SOUL.md, product rules, no OpenClaw AGENTS.md

Status: draft, 2026-10-25. Batch 2 of the hermes review (batch 1:
`2026-10-25-hermes-config-tuning-design.md`).

## Why

What a druzhok bot is told about itself is mostly OpenClaw leftovers and hermes defaults.

| File | Who writes it | What is in it today |
|---|---|---|
| `<home>/SOUL.md` (hermes identity, replaces "You are Hermes Agent…", agent/system_prompt.py:544) | `ManagerBot.Provisioner.write_soul/2`, once at creation | See below |
| `<home>/workspace/AGENTS.md` (hermes "Project Context", a coding-repo concept) | Seeded once, then `sync_agents_md/2` rewrites four sections on every start | See below |

**SOUL.md** comes in two variants:
- dzharvis, kamochka, medical_assistant: «Тебя зовут <имя>. Ты персональный AI-ассистент… пишешь и
  редактируешь код…» (three lines);
- igorhermes, vilya, vasya: hermes's own default, «You are Hermes Agent, built by Nous Research…»,
  seeded by hermes because druzhok had not written one.

**AGENTS.md** has four druzhok-owned sections:
- «Каждая сессия»;
- «Память», which tells the bot to write `memory/YYYY-MM-DD.md` and TOOLS.md, files that do not exist in
  hermes. Hermes keeps memory in `memories/MEMORY.md` and `USER.md` through the `memory` tool, plus
  Mnemosyne;
- «Стиль», the loop-prevention rules, which are good;
- «Публикация сайтов».

The seed also has three bot-editable sections: «Безопасность», «Групповые чаты», and a footer.

No bot ever edited either file. Hermes never asks it to: its prompt routes user facts to the `memory` tool
and know-how to skills, and treats SOUL.md and AGENTS.md as protected instruction files. Users meet "Hermes"
and a coding assistant; the product is Дружок.

## Goals

1. Every bot has a Russian Дружок identity with its own name, kept current by druzhok.
2. Druzhok's product rules live in one place druzhok owns, outside files the bot may edit.
3. No instruction contradicts how hermes 0.22.2 actually works (memory, skills, files).
4. Nothing an owner or a bot wrote is overwritten or lost.

## Design

### SOUL.md: a druzhok-owned identity

- `Runtime.Hermes.soul_md(instance)` renders the persona.
- **The name** is a new `instances.display_name` column, never a network call on the start path.
  - It is written by the provisioner at creation, from `session[:name]`, which is the name the owner
    typed.
  - **Backfill:** a boot task in druzhok.service, after the catalogue warm-up, takes each instance with a
    nil `display_name` and calls `Panel.profile(inst.telegram_token)`. That is a live getMe, 3 s cap, one
    bot at a time. It is not a `druzhok-run.sh` one-off, whose fresh VM has an empty profile cache. A bot
    whose getMe fails keeps nil and is tried again on the next boot.
  - **Updates** happen at the instance-aware caller (`Panel.bot/1`, panel.ex:63): when the profile title
    differs from `display_name`, it updates the row. `Panel.profile/1` stays token-only and read only; it
    is also called for the manager bot.
  - When `display_name` is nil, `sync_soul` keeps the current SOUL.md. The only exception is a missing
    SOUL.md, which is written with «Дружок». The bot's slug is never used as a name.
- **`ManagerBot.Provisioner.write_soul/2` is removed.** The 'missing' row below covers creation. Update the
  CLAUDE.md layout note («SOUL.md from the provisioner» becomes «SOUL.md from `Runtime.Hermes.sync_soul/2`»).
- **Content (Russian, short):**
  - who it is: a personal assistant in Telegram, part of Дружок;
  - its voice: friendly, plain words, no jargon, short by default;
  - what it is not: no "AI language model" disclaimers, not a coding agent unless asked;
  - **rules that must hold in every run.** Cron runs load SOUL.md but not `agent.system_prompt` (see
    below), so these live here:
    - never talk about "balance", "credits" or providers;
    - when a limit is reached, say so and point to «Кабинет»;
    - private data never leaks.
- The text stays under ~900 characters, because SOUL.md is re-read on every message.

**Ownership and versions** live in two new columns, `instances.soul_sha256` and `instances.soul_version`,
not in a file the bot can write. They record the hash of the last SOUL.md druzhok wrote and the template
version. On every start `sync_soul/2` does one of:

| Current SOUL.md | Action |
|---|---|
| missing | write the rendered persona, record its hash |
| hash equals the recorded one (druzhok's own text) | rewrite if the rendered text changed |
| equals one of the known legacy texts (the old three-line template rendered with any name, or hermes's `DEFAULT_SOUL_MD`) | replace, keep the old file as `SOUL.md.bak-<date>` |
| anything else (owner- or bot-edited) | leave alone, log once |

Legacy texts are compared as full rendered content after trimming, never by size.

**All reads, writes and renames go through `Druzhok.TenantFiles`** (batch 1 adds `TenantFiles.replace/3`:
lstat every component, refuse symlinks, exclusive temp file, chown to the bot uid, rename).
- A symlinked or dangling-symlink SOUL.md is refused and logged, never treated as 'missing'. Otherwise
  `File.write!` would create the link's target anywhere on the host, since druzhok runs with
  CAP_DAC_OVERRIDE.
- `.bak` copies are made the same way.

Owner customisation of the persona (a panel field or a chat command) is a later feature. When it comes, it
writes through druzhok and updates the hash.

### Product rules in `agent.system_prompt`

- `sync_config` writes `agent.system_prompt` rendered from `Runtime.Hermes.product_rules(instance)`.
- **Format:** one line, as a YAML double-quoted scalar. A JSON-encoded string is valid YAML, and `\n`
  carries the line breaks. It is not a block scalar: a blank line inside `agent:` ends
  `sync_yaml_block/3`'s body match (hermes.ex:734), so the keys after it would be invisible, the sync would
  add duplicates, and hermes's ruamel round-trip saves reject duplicate keys.
- The key is replaced by dropping it with its whole body (`drop_owned_keys`) and inserting the new line,
  so a block form left by a hand edit is cleaned up too.
- `platform_hints.telegram.replace` is written the same way.
- Hermes appends it at request time as the last part of the system message
  (gateway/run_config_loaders.py:93, agent/turn_context.py:1345).
- It is replaced when `display.personality`, the env `HERMES_EPHEMERAL_SYSTEM_PROMPT` or a per-channel
  `channel_overrides.system_prompt` is set (hermes_cli/personality.py:121). Druzhok sets none of these and
  removes `display.personality` if present.

**Contents (Russian), built per bot from its settings:**
- **Capabilities:**
  - reminders and scheduled tasks (cronjob);
  - pictures, only when `image_gen_enabled`;
  - voice in and out;
  - photos;
  - web search;
  - sites, only when `website_hosting_enabled`, with the publishing steps from today's «Публикация сайтов».
- **«Кабинет»:** the menu button opens the bot's panel (plan, limits, memory, invites). When a limit is
  reached, the bot says so plainly and points to «Кабинет». It never talks about "balance", "credits" or
  providers.
- **The style rules** from today's «Стиль» section.
- **Safety, from the seed:** private data never leaks; destructive actions only with the owner's
  permission. **Groups:** take part, don't dominate.
- **Memory:** user facts go through the memory tool; never invent files like `memory/YYYY-MM-DD.md`.
- **Older instructions:** if earlier instructions in this conversation mention `memory/YYYY-MM-DD.md`,
  TOOLS.md or AGENTS.md sections, they are out of date; follow these rules. This covers the period
  described under Rollout, when a running session still holds the old stored prompt.

**Cron runs do not get it.** `_construct_cron_agent` (cron/scheduler.py:2468) builds the agent without
`ephemeral_system_prompt`; only gateway agents get it (gateway/run_turn_runner.py:1119).
- Reminders and scheduled tasks see SOUL.md (which carries the always-rules above) and the Telegram hint,
  but not the capability, site and style rules.
- That is accepted for now: a cron run delivers a prepared task and does not publish sites.
- Passing the prompt to cron is fork/upstream work and is listed there.

Hermes's own blocks are left alone here; branding is the fork batch. This covers:
- memory and skill guidance;
- tool-use enforcement and execution guidance;
- the platform hint, which is the next section.

### Telegram formatting hint

`platform_hints.telegram.replace`: a Russian rewrite of `PLATFORM_HINTS["telegram"]`
(agent/prompt_builder.py:690). It keeps, literally:
- the `MEDIA:/absolute/path` attachment syntax;
- the `[[audio_as_voice]]` marker;
- the image-link rule;
- the no-tables rule;
- the Markdown subset Telegram renders.

### AGENTS.md retired

- `sync_agents_md/2`, the seed in `workspace_files/1` and the four section constants are removed.
- **Existing files.** `sync_agents_md` has spliced the four druzhok sections into every file on every
  start since 04814e3, appending missing ones after the seed's footer. So no unedited file equals a past
  seed verbatim. Migration (`migrate_agents_md/1`, on every start, keyed on the file's content rather
  than a column, so it also runs again after a rollback restored a `.bak`). It acts only when AGENTS.md
  holds at least one of the four druzhok-owned headings, and is a no-op otherwise:
  1. Copy the file to `AGENTS.md.bak-<date>` (through `TenantFiles`).
  2. Remove the four druzhok-owned sections («Каждая сессия», «Память», «Стиль», «Публикация сайтов»),
     wherever they sit, footer or not.
  3. Compare the remainder with the non-owned parts of every past seed, normalised for whitespace:
     - the `# AGENTS.md — Персональный ассистент` header;
     - «Безопасность», «Групповые чаты»;
     - the `_Этот файл — стартовая точка…_` footer.
     Only seed parts left (in any order, any subset) → delete AGENTS.md; the `.bak` stays. Hermes then
     loads no Project Context.
  4. Anything else → write the remainder back. It is what the owner or bot added; the `.bak` has the
     original.
- An owner who wants standing rules tells the bot; hermes stores them in memory.

### The 402 notice

`LlmProxy.BalanceNotice` answers an exhausted account with «💳 Баланс бота исчерпан. Пополни счёт…».
Plans have no balance any more.

New texts:
- ru: «Лимит тарифа на сейчас исчерпан. Когда он обновится и как сменить тариф — в «Кабинете».»
- en: «The plan's limit is used up for now. When it resets and how to change plans — in «Кабинет».»

No prompt can change these, because they are deterministic completions. `text/1` also feeds the 402
replies for search and other endpoints (llm_proxy/ruoc.ex:265, 394); those get the same texts.

**Only the main conversation call gets the notice.** Today every 402 on `/v1/chat/completions` becomes a
200 completion carrying the notice. That includes hermes's auxiliary calls (compression summary, photo
description, session title), so on an exhausted plan a summary or a description can become the notice
text (pre-existing).
- **The auxiliary callers pass no tools:** compression, title, vision, query rewrite. The main loop and its
  iteration-summary path do carry tools (chat_completion_helpers.py:2255).
- **Exception:** a cron job created with `enabled_toolsets: []` (tools/cronjob_tools.py:1132,
  cron/scheduler.py:474) is a main conversation call without `tools` (chat_completions.py:387). A real 402
  there produces hermes's "Billing or credits exhausted … /model" text (conversation_loop.py:577), and cron
  delivers it to the owner.
- **The gate therefore recognises the agent's own prompt.** Every agent system prompt, gateway or cron,
  carries hermes's runtime trailer. The exact marker is pinned at implementation by rendering both a
  gateway and a cron prompt: the `Conversation started:` line (agent/system_prompt.py:489) or the
  `# Hermes runtime environment` heading. The aux prompts never carry it.
- **The proxy answers the notice when** the request has non-empty `tools`, or when its first system message
  contains that marker. Otherwise it passes the real 402 through, which hermes's auxiliary client treats as
  a failure.
- If a hermes update moves the marker, the gate falls back to today's behaviour: the notice for every chat
  402. It never falls back to the raw lecture. The `update-hermes` skill gets a check for the marker.
- This needs no fork patch.
- **To check on the canary**, on an exhausted plan:
  - an aux call gets 402 and hermes does not retry it in a loop;
  - a zero-toolset reminder delivers the notice.

## Not in scope

- **Branding inside hermes's own prompt:** "You run on Hermes Agent", the profile line, the
  Model/Provider trailer, the runtime environment block.
- **English failure messages, and the "Hermes" in the shutdown and restart notices** (locales/ru.yaml:838):
  fork/upstream batch.
- **Persona editing by owners.**
- **Passing `agent.system_prompt` to cron agents:** fork/upstream.

## Tests

- **`sync_soul/2`:**
  - every row of its table (missing; own hash; each legacy text with two names; custom text left alone);
  - nil `display_name` keeps the file;
  - a symlinked and a dangling-symlink SOUL.md are refused;
  - idempotence, and the backup written once.
- **`product_rules/1`:**
  - the capability lines follow the settings;
  - `agent.system_prompt` is written as one double-quoted line and is idempotent;
  - a changed prompt between two syncs leaves no old body lines;
  - an `agent:` block that hermes re-dumped with a block-scalar prompt followed by other `agent.*` keys is
    cleaned up with no duplicate keys;
  - `display.personality` is removed.
- **AGENTS.md migration:**
  - a seed with druzhok sections spliced in, some after the footer, is deleted with its `.bak`;
  - in a file with an owner's own section, only druzhok's four sections are removed and the rest stays
    byte for byte;
  - a file without druzhok headings is untouched;
  - migrate → `Rollback.voice()` → migrate again ends in the migrated state.
- **`BalanceNotice`:**
  - both texts;
  - a 402 on a request with `tools` gets the notice;
  - a tool-less request whose system message carries the agent marker (a cron shape) gets the notice;
  - a tool-less aux-shaped request passes through as 402.

## Rollout

**A running conversation keeps its stored system prompt.** Hermes 0.22.2 reuses the prompt saved in the
session DB word for word (`_restore_or_build_system_prompt`, agent/conversation_loop.py:745). It rebuilds
only when:
- the Model or Provider line changes;
- the cwd changes;
- at compaction (agent/conversation_compression.py:3125).

Gateway chats reset only on /new or /reset (hermes_cli/session_reset_retirement.py). So a bot's ongoing DM
keeps the old SOUL.md, AGENTS.md and skills index until its next compaction or /new. Only
`agent.system_prompt`, which is added per request, applies at once.
- This mixed period is accepted. The product rules' «Older instructions» line covers the one real
  conflict, the memory files.
- No one-off forces a rebuild. Doing so would mean editing hermes's session DB.
- Heavy bots compact soon: after batch 1, vilya and dzharvis are above the new 150K trigger on their next
  turn.

Canary igorhermes:
1. send `/new` first, so the prompt is rebuilt;
2. read the rendered system prompt (`agent.log`);
3. hold a few real conversations in Russian:
- a reminder;
- «что ты умеешь»;
- a question at the limit;
- a group chat.

The other bots pick the change up on wake.

**Rollback.** The change ships `Druzhok.Runtime.Hermes.Rollback.voice/0`. For each bot it does three things
through `TenantFiles`:
- removes `agent.system_prompt` and `platform_hints.telegram` from `config.yaml`;
- restores `SOUL.md.bak-*` where druzhok made one;
- restores `AGENTS.md.bak-*` where the migration made one.

The reverted `sync_agents_md` then re-adds its sections to a restored AGENTS.md as before. Without the
key removal, the product rules would apply twice.

**Order matters:** while the new code runs, any start or wake writes the keys back. So the revert takes out
only the sync steps (`sync_soul`, `migrate_agents_md`, the `agent.system_prompt` and `platform_hints` steps)
and keeps `Rollback`. Rollback is:
1. deploy the partial revert;
2. run `Rollback.voice()` through `ops/druzhok-run.sh`;
3. restart the bots;
4. later remove `Rollback` in a cleanup commit.

The new columns are left in place; they are additive.
