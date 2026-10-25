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
- The **name** comes from the bot's Telegram display name (`Panel.profile/1` title), else the instance's
  stored name, else «Дружок».
- **Content (Russian, short):**
  - who it is: a personal assistant in Telegram, part of Дружок;
  - its voice: friendly, plain words, no jargon, short by default;
  - what it is not: no "AI language model" disclaimers, not a coding agent unless asked.
- The text stays under ~800 characters, because SOUL.md is re-read on every message.

**Ownership and versions.** Druzhok writes `<home>/.druzhok/soul.sha256`: the hash of the last SOUL.md it
wrote, plus a template version. On every start `sync_soul/2` does one of:

| Current SOUL.md | Action |
|---|---|
| missing | write the rendered persona, record its hash |
| hash equals the recorded one (druzhok's own text) | rewrite if the rendered text changed |
| equals one of the known legacy texts (the old three-line template rendered with any name, or hermes's `DEFAULT_SOUL_MD`) | replace, keep the old file as `SOUL.md.bak-<date>` |
| anything else (owner- or bot-edited) | leave alone, log once |

Legacy texts are compared as full rendered content after trimming, never by size.

Owner customisation of the persona (a panel field or a chat command) is a later feature. When it comes, it
writes through druzhok and updates the hash.

### Product rules in `agent.system_prompt`

- `sync_config` writes `agent.system_prompt` as a YAML block scalar rendered from
  `Runtime.Hermes.product_rules(instance)`.
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
- **Existing files:**
  - equal to a known template (rendered seed of any past version, compared as full text) → renamed to
    `AGENTS.md.bak-<date>`, so hermes stops loading it;
  - otherwise the owner or bot edited it → only the «Память» section is removed (it is wrong).
    «Каждая сессия», «Стиль» and «Публикация сайтов» are removed too, since they now live in
    `agent.system_prompt`. Everything else stays.
- An owner who wants standing rules tells the bot; hermes stores them in memory.

### The 402 notice

`LlmProxy.BalanceNotice` answers an exhausted account with «💳 Баланс бота исчерпан. Пополни счёт…».
Plans have no balance any more.

New text (ru): «Лимит тарифа на сейчас исчерпан. Когда он обновится и как сменить тариф — в «Кабинете».»
No prompt can change it, because it is a deterministic completion. A check is needed that compression
never takes this notice for a summary when an aux call hits 402:
`context_compressor` must treat a summary equal to the notice as a failure.

## Not in scope

- **Branding inside hermes's own prompt:** "You run on Hermes Agent", the profile line, the
  Model/Provider trailer, the runtime environment block.
- **English failure messages, and the "Hermes" in the shutdown and restart notices** (locales/ru.yaml:838):
  fork/upstream batch.
- **Persona editing by owners.**

## Tests

- `sync_soul/2`: every row of its table (missing; own hash; each legacy text with two names; custom text
  left alone), idempotence, and the backup written once.
- `product_rules/1`: the capability lines follow the settings; the `agent.system_prompt` block is written
  and is idempotent; `display.personality` is removed.
- AGENTS.md migration: a template file is renamed; in an edited file only druzhok's sections are removed
  and the rest stays byte for byte.
- `BalanceNotice` text.

## Rollout

Same as batch 1: canary igorhermes, read the rendered system prompt (`agent.log`), then a few real
conversations in Russian:
- a reminder;
- «что ты умеешь»;
- a question at the limit;
- a group chat.

The other bots pick the change up on wake.

**Rollback:** restore `SOUL.md.bak-*` and `AGENTS.md.bak-*` and revert the commit.
