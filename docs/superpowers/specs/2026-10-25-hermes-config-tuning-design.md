# Hermes config tuning: context window, tools, skills, turn budget, dead keys

Status: draft, 2026-10-25. Batch 1 of the hermes review (batch 2, the bot's voice:
`2026-10-25-bot-voice-design.md`). Reviewed as a list by gpt-6-astra and gpt-6.1-sol before this spec.

## Why

Druzhok writes each bot's `config.yaml` on every start and wake (`Runtime.Hermes.sync_config/2`, called from
`BotManager.prepare_start/1`). Most of what it writes still dates from hermes 0.14–0.17 and the OpenClaw era.
On hermes 0.22.2 three things cost money or correctness every day:

- **Context window.** ruoc's `GET /v1/models` returns `limit: {context: 200000, output: 32768}` for
  `ruoc-deepseek-flash` and `ruoc-flash`, but `Ruoc.to_model/1` drops `limit`. Hermes cannot probe our proxy
  ("Could not detect context length … probe-down") and falls back to its hardcoded table: 1,000,000 for
  "deepseek-flash". Compression then fires at 0.5 × 1M (agent/context_compressor.py:1151: the 0.75 floor
  applies only below 512K). Last 7 days of chat calls (`usage_logs`): vilya 473 calls, average 233K input
  tokens, max 418K; dzharvis 148 calls, average 242K, max 345K.
- **Tool schemas.** The `hermes-telegram` default gives 21 tools, about 41K characters of schemas per call,
  among them a browser (bots have no internet and no browser binary), computer use (no display), OAuth
  connectors and subagent delegation.
- **Turn budget.** `agent.max_turns` defaults to unlimited and `agent.run_budget_seconds` to off
  (hermes_cli/config_defaults.py:78–86). A looping turn can spend a whole plan.

## Decisions already taken (operator, 2026-10-25)

- **Keep skill creation:** the `skills` toolset and `skill_manage`. Bots create skills (vilya: `auto/car-*`;
  others: `utility-bill-disputes`, `resume-optimization`, `film-recommendations`).
- **Keep the 10-turn background review** (`auxiliary.background_review`, `memory.nudge_interval`).
- **Keep tool-use enforcement and execution guidance.** "deepseek" matches both auto lists
  (agent/prompt_builder.py:365, 379). The blocks make the model use tools for arithmetic and read back
  external writes, which matters for reminders and sites.
- **Keep the fork's Telegram DM guard.** `dm_policy`/`group_policy` do not replace it: Telegram does not use
  that authorization path (gateway/authz_mixin.py:652), and the startup check at gateway/run.py:2225 does
  not cover Telegram.

## Changes

All live in `apps/druzhok/lib/druzhok/runtime/hermes.ex` (writes) and `apps/druzhok/lib/druzhok/ruoc.ex`
(catalogue), each as a `sync_*` step that is idempotent: a second run over its own output changes nothing,
so the `updated != content` write guard keeps holding.

**How owned keys are written.** `upsert_indented_line/3` is flat: it replaces the first `key:` line at any
depth and inserts a missing key at indent 2. That is right only for scalar keys directly under a top-level
block (`model.context_length`, `model.supports_vision`, `agent.image_input_mode`, `agent.max_turns`,
`agent.budget_warning_ratio`, `agent.run_budget_seconds`, `terminal.cwd`).

Nested and list keys go through the path `sync_telegram_extra` already uses: `yaml_block` +
`drop_owned_keys` (the key with its whole indented body, blank lines included) + a fresh render. This covers:
- `auxiliary.vision`, `auxiliary.compression`;
- `agent.disabled_toolsets`, `skills.disabled`.

Lists are rendered as one-line flow lists (`[a, b]`). Hermes keeps unchanged nodes on its own round-trip
saves (utils.py:529), so a flow list stays one line.

**The symlink exposure is pre-existing, and this change closes it for its own files.** druzhok.service has
CAP_DAC_OVERRIDE, CAP_DAC_READ_SEARCH, CAP_CHOWN and CAP_FOWNER, and the bot owns its tenant dir, so the bot
can replace any path there with a symlink. Today's config.yaml and AGENTS.md writes follow such links.

From here on, every druzhok read or write of a tenant file goes through `Druzhok.TenantFiles`:
- `config.yaml`, `skills/.bundled_manifest`, and batch 2's SOUL.md and AGENTS.md.
- **Reads** already refuse a symlink anywhere below the tenant dir and verify the descriptor.
- **Writes, new `TenantFiles.replace/3`:**
  1. lstat every path component below the tenant dir and refuse any symlink;
  2. write a temp file in the same directory with `:exclusive` (O_CREAT|O_EXCL does not follow a link);
  3. chown it to the bot's uid;
  4. `rename(2)` it over the target. A rename replaces a link instead of following it.
- **Residual race:** the bot can swap a directory component between the lstat and the rename. Only files
  directly in `<home>` and `<home>/workspace` are written, and the check runs right before the rename.

### 1. Model facts from ruoc's catalogue

`Ruoc.to_model/1` keeps `limit.context` and `limit.output` as `limits: %{context, output}`.

A new `Ruoc.model_facts(id)` replaces `sees_images?/1`. It reads `cached_models/0` (never waits on ruoc)
and returns one of:

| Result | Meaning |
|---|---|
| `{:ok, %{sees_images: bool, context: int \| nil}}` | the model is in the catalogue |
| `:unknown_model` | the catalogue is loaded but does not list the model |
| `:no_catalogue` | the cached list is empty: never fetched, or the first fetch failed (`Ruoc.models/0` stores `{now, []}` on failure, ruoc.ex:357) |

`prepare_start/1` puts the result on the instance map as `:model_facts`; `sync_config` reads it.

| Facts | `model.context_length` | `model.supports_vision` | `agent.image_input_mode` |
|---|---|---|---|
| `{:ok, …}` with context | written | `true`/`false` | `native`/`auto` |
| `{:ok, …}` without context | removed | `true`/`false` | `native`/`auto` |
| `:unknown_model` | removed | removed | `auto` |
| `:no_catalogue` | unchanged | unchanged | unchanged |

Druzhok owns these three keys: owners have no access to `config.yaml`. Removing them on `:unknown_model`
lets hermes fall back to its own detection instead of keeping the previous model's numbers.

- `model.context_length` is hermes's first lookup (agent/model_metadata.py:2240).
- The gateway does not set `max_tokens`, so the compression trigger is 0.75 × 200K = 150K
  (`_effective_input_window`, context_compressor.py:2762).
- If a later change sets an output reservation, the trigger drops to 0.75 × (200K − reservation).

`Druzhok.Application` already warms the catalogue at boot (commit `9ba23e5`). A change in ruoc reaches a bot on
its next start or wake; `cached_models` refreshes within 60 s.

### 2. Merge the `auxiliary:` block instead of replacing it

`sync_auxiliary_vision/3` replaces the whole `auxiliary:` block on every start (hermes.ex:640, regex up
to the next top-level key). Any other `auxiliary.*` setting is erased: `background_review`,
`title_generation`, and anything hermes writes there.

Rewrite it so that only two subsections are dropped (each with its body) and re-rendered:
- `auxiliary.vision` (`provider`, `base_url`, `api_key`, `model`);
- `auxiliary.compression` (`reasoning_effort`). Other keys hermes may keep there are carried over.

Every other subsection is left byte for byte: `background_review`, `title_generation`, and any `model:` /
`provider:` lines inside them.

This is a prerequisite for any later aux setting; no aux setting changes in this batch.

### 3. Switch off toolsets that cannot work

`agent.disabled_toolsets: [browser, computer_use, connections, delegation]`.
- This is the global suppression list, applied last (hermes_cli/tools_config.py:626).
- It is a block list, not a `platform_toolsets` allow list, so toolsets added by later hermes versions are
  not lost silently. Each hermes update (the `update-hermes` skill) reviews new toolsets.
- `kanban` is off by default already.
- Kept: web, vision, image_gen, tts, memory, session_search, cronjob, clarify, todo, skills, file, terminal,
  code_execution (dzharvis runs Python in its workspace).
- Hermes's own guard keeps `web_search` when only the browser is suppressed (toolsets.py:108).

Druzhok owns `agent.disabled_toolsets`; the list is written as a whole.

### 4. Switch off bundled skills that cannot run

Each bot carries about 60–90 bundled skills (`<home>/skills`, listed with hashes in
`skills/.bundled_manifest`). The skills index in the system prompt lists all of them (~7K characters), and
some tell the model to use tools a bot does not have.

Druzhok keeps a fixed list `@disabled_skills` of bundled names that need a Mac, GitHub, an external API or
a coding environment:
- `claude-code`, `codex`, `opencode`, `computer-use`, `merge-reconciler`;
- `apple-notes`, `apple-reminders`, `findmy`, `imessage`;
- `github`, `github-auth`, `github-code-review`, `github-issues`, `github-issue-to-pr`,
  `github-pr-workflow`, `github-repo-management`, `codebase-inspection`, `dogfood`;
- `huggingface-hub`, `serving-llms-vllm`, `llama-cpp`, `weights-and-biases`, `evaluating-llms-harness`;
- `sdlc-review`, `openhue`, `xurl`, `himalaya`, `comfyui`, `touchdesigner-mcp`;
- `airtable`, `box`, `google-workspace`, `notion`, `teams-meeting-pipeline`.

Obsidian stays: it works on plain files.

**Skills are disabled by name** (`skills.disabled`, agent/skill_utils.py:261), so a bot-created skill with
the same name would be hidden too. The written list is
`@disabled_skills ∩ names in skills/.bundled_manifest`. A name the bot created is not in the manifest, so
it is never disabled. If the manifest is missing, unreadable, or a symlink (read through `TenantFiles`),
nothing is disabled: `skills.disabled` is removed.

`hermes-agent` is essential and cannot be disabled (skill_utils.py:258). The list is regenerated on every
start; druzhok owns `skills.disabled`.

The final names are taken from a live inventory at implementation time (`find <home>/skills -name
SKILL.md`), not from the hermes source tree. Several names differ between the two, for example the mlops
sub-skills.

### 5. Turn budget

- `agent.max_turns: 30`: tool iterations per reply.
- `agent.budget_warning_ratio: 0.75`: the model is told once that it is near the cap, so it answers instead
  of being cut mid-task. Hermes's own comment warns that bare caps truncated silently (config_defaults.py:76).
- `agent.run_budget_seconds: 300`: a wrap-up notice at 80 %.

Values are a first guess, to be checked against the canary's real turns: count tool iterations per reply in
`agent.log` before rollout.

### 6. Dead and outdated keys

- **Delete `messaging.enabled_platforms`** from `build_config_yaml/1` and from existing files; nothing in
  0.22.2 reads it. Telegram stays enabled by `platforms.telegram.enabled`.
- **Delete env `HERMES_MODEL`, `HERMES_INFERENCE_PROVIDER` and `HERMES_QUIET`.** The `model:` block supplies
  provider and model, and the gateway forces quiet mode itself (gateway/run.py:2147). Cron preflight reads
  `HERMES_MODEL` (cron/scheduler_preflight.py:100), so the canary must run a reminder.
- **Write `terminal.cwd: <home>/workspace`** (canonical, gateway/run.py:2152). Keep `MESSAGING_CWD` with the
  same value for one release for rollback, then drop it.
- **Fix comments:**
  - The Mnemosyne prefixes are kept for gemini on eval evidence (1.00 vs 0.99), not because "e5 needs"
    them.
  - `stt.openai.model: whisper-1` is ignored: the proxy sends audio to ruoc.
  - The compression `reasoning_effort: low` note stays as GLM history; bots are on DeepSeek now.

## Not in this batch

- **Background-review writes to Mnemosyne.** The review fork runs with `skip_memory=True`
  (agent/background_review.py:915), so external memory providers are not loaded there.
  `extra_tools: [mnemosyne_remember]` would offer a tool with no provider behind it. The review keeps
  writing builtin MEMORY.md/USER.md and skills; Mnemosyne learns from its own per-turn sync. Revisit only
  if memories are seen missing.
- **Title generation and the background review cadence:** unchanged.
- **The bot's voice** (SOUL.md, `agent.system_prompt`, AGENTS.md, the Telegram hint, the 402 notice): batch 2.

## Tests

`apps/druzhok/test/druzhok/runtime/hermes_test.exs`, one `describe` per change:
- every row of the table in 1;
- the aux merge keeps unrelated `auxiliary.*` keys and nested siblings;
- the disabled toolsets are written;
- the skills list is intersected with a fixture manifest, a bot-created namesake survives, and a missing
  manifest disables nothing;
- the turn-budget keys;
- `messaging` is removed;
- `terminal.cwd`;
- the env map no longer carries the three variables.

More tests:
- **Idempotence:** each sync step synced over its own output changes nothing.
- **A changed value between two syncs:**
  - lists shorter and longer than before;
  - a new context length;
  - a changed vision model.
  No old `- item` or body lines may be left behind.
- **Aux merge:** an `auxiliary:` block with another subsection carrying `model:` placed before `vision:`.
- **`Ruoc.model_facts/1`:** its three results, including a failed first fetch (`:no_catalogue`).
- **`TenantFiles.replace/3`:**
  - a symlinked target, a dangling symlink target and a symlinked directory component are refused;
  - the written file belongs to the bot's uid.

## Rollout

1. Merge, deploy (CLAUDE.md → Server).
2. Canary igorhermes:
   - restart it;
   - read `config.yaml` and the rendered system prompt (`agent.log`);
   - check 24 h of `usage_logs`: input tokens per user request (not per call), compression events, cost;
   - send a reminder, a photo and a voice note, and publish a site, across one sleep/wake.
3. The other bots pick the change up on their next wake, or restart them one at a time with
   `sudo ops/druzhok restart <bot>`.

**Rollback.** Reverting the code is not enough. The old `sync_config` never writes or removes these keys,
and `config.yaml` is seeded only when absent, so they would stay in force:
- `model.context_length`, `model.supports_vision`;
- `agent.max_turns`, `agent.budget_warning_ratio`, `agent.run_budget_seconds`, `agent.disabled_toolsets`;
- `skills.disabled`, `terminal.cwd`.

The change ships `Druzhok.Runtime.Hermes.Rollback.tuning/0`, which removes exactly those keys from every
bot's `config.yaml` through `TenantFiles.replace/3`. `agent.image_input_mode` stays, being already live.
Rollback is:
1. `sudo ops/druzhok-run.sh 'Druzhok.Runtime.Hermes.Rollback.tuning()'`;
2. deploy the revert;
3. restart the bots one at a time.

The `auxiliary:` merge and the removed `messaging` block need nothing: the old code rewrites `auxiliary:`
wholesale, and nothing reads `messaging`.
