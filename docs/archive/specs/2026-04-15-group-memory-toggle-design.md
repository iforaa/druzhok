# Dashboard toggle: shared group memory

Date: 2026-04-15
Status: Draft — pending user review

## Problem

In a Telegram group chat, the hermes bot keeps a separate session per participant when no forum topic is involved. With four users in Vasya's group ("Себаса Поскорей", chat_id `-1002273542926`), the bot currently has four disjoint transcripts. When Victor addresses the bot after Igor has just written several messages, the bot has zero context about Igor's messages — they live in a different session. Observed symptom: "bot constantly losing context; if somebody starts a conversation, it doesn't know what I said a few minutes ago."

Root cause: hermes's `group_sessions_per_user` flag defaults to `true`. Upstream chose this as a "secure default" (isolation of context, cost, and interrupts). For Igor's small group of trusted people, the isolation is a bug, not a feature.

Manual workaround already applied on 2026-04-15: appended `group_sessions_per_user: false` to Vasya's `config.yaml` on the remote and restarted her container. This spec productionises the knob so future bots can be toggled from the dashboard, and so the manual edit on Vasya is replaced by a DB-backed value.

## Scope

Expose a single per-instance boolean in the druzhok dashboard. The toggle flips the hermes config key `group_sessions_per_user` between `true` (per-user isolation, the hermes default) and `false` (shared "room brain"). Nothing else changes. Only Telegram behaviour is affected today; the flag applies to every platform adapter hermes ships, but we do not expose platform-specific overrides.

Explicitly in scope:
- New boolean column on `instances`
- Ecto schema + changeset cast
- Emission into the generated `config.yaml` via `sync_config/2`
- UI toggle in the per-instance `settings_tab.ex`, grouped with `mention_only` in a new "Group behavior" subsection
- Deploy steps that replace Vasya's manual yaml append with a DB-backed value without a behaviour flicker

Explicitly out of scope (deferred to separate projects):
- "Silent observer" mode (bot sees untriggered messages but only responds when addressed). Requires a hermes source patch inside `_handle_text_message`, which lives in a churn-prone area of `telegram.py`.
- A dashboard control for the newly-landed `ignored_threads` hermes feature.
- A combined "memory mode" selector with presets (per-user / shared / per-topic). YAGNI until a second requirement appears.
- Exposing `thread_sessions_per_user`.

## Why this is safe

`group_sessions_per_user` is a stable public hermes config key that has existed since v2026.3.17. It is read by `gateway/config.py` and consumed by `gateway/session.py:build_session_key`. We do not patch any hermes source. We emit one additional yaml key. If upstream ever renames or removes the key, the fix is a one-line change in `hermes.ex` plus a dashboard label tweak.

Rollback is a down-migration dropping the column. With the key absent from the yaml, hermes falls back to its own `true` default — i.e. pre-change behaviour.

## Design

### Data model

Migration (new file under `apps/druzhok/priv/repo/migrations/`):

```elixir
alter table(:instances) do
  add :group_sessions_per_user, :boolean, default: true, null: false
end
```

Default `true` preserves current behaviour for every existing bot. `null: false` keeps the column non-nullable so `sync_config` can rely on a boolean value without tri-state handling.

Schema update in `apps/druzhok/lib/druzhok/instance.ex`:
- Add `field :group_sessions_per_user, :boolean, default: true`
- Add `:group_sessions_per_user` to the `cast/3` whitelist used by the changeset

### Config emission

In `apps/druzhok/lib/druzhok/runtime/hermes.ex`, the `sync_config/2` function (or whichever function writes per-instance yaml keys) writes:

```yaml
group_sessions_per_user: <true | false>
```

at the top level of the generated yaml. The key appears exactly once per generation. Matching code structure already used for booleans on this module.

### UI

In `apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex`, add a new "Group behavior" subsection placed near the existing `mention_only` control. The subsection contains two rows:
- Existing: "Mention only" (unchanged)
- New: "Shared group memory" — a toggle styled to match `mention_only`. On = "one shared conversation per group". Off = "isolated per user" (hermes default).

Wiring:
- `phx-change` event handler `toggle_shared_group_memory` (or re-use the generic `settings_changed` event if one exists) calls `update_instance(name, %{group_sessions_per_user: <bool>})`.
- `update_instance/2` uses `Instance.changeset/2` + `Repo.update/1` (existing helper).
- On successful update, restart the bot with async `BotManager.restart(name)` — same pattern as `toggle_mention_only`.

Help text under the toggle:
> Off: each user in a group chat has a private conversation with the bot (hermes default). On: everyone in the group shares one conversation — the bot sees context from all participants. Use "On" for small, trusted groups.

### Deploy order

The Vasya instance has a manual `group_sessions_per_user: false` appended to its yaml. Once `sync_config` also emits the key, both lines will coexist in the generated yaml. YAML's "last key wins" rule means whichever gets written last is effective. To avoid ambiguity and a behaviour flicker, the rollout follows this order:

1. Merge and deploy the druzhok code + migration.
2. Before the first bot restart under the new code, run:
   ```sql
   UPDATE instances SET group_sessions_per_user = false WHERE name = 'igorhermes';
   ```
3. Remove the manual `group_sessions_per_user: false` line from
   `/home/igor/druzhok-data/v4-instances/igorhermes/config.yaml`.
4. Restart druzhok service. `sync_config` regenerates Vasya's yaml with `group_sessions_per_user: false` from the DB. Рун (hermes3) gets `true` from the default and behaves exactly as before.

Rollback: down-migrate + remove the yaml emission call. Bots next restart with hermes falling back to its own `true` default.

## Testing

- Unit: changeset accepts `group_sessions_per_user: true|false` and rejects non-boolean.
- Unit: `sync_config` for an instance emits the expected yaml key and value in both states.
- Manual smoke test on Vasya after deploy:
  1. Verify Vasya's generated yaml contains `group_sessions_per_user: false` exactly once.
  2. Verify Рун's generated yaml either omits the key or emits `true` (both mean "per-user").
  3. In Vasya's group, have Igor write a message, then Victor asks the bot a question that depends on Igor's recent message. Bot should have it in context.
  4. In Рун (if possible), verify behaviour is unchanged.
- UI smoke: toggle the setting in the dashboard for a non-production bot, confirm DB updates, container restarts, and new yaml contents match.

## Open questions

None at spec time.

## Out-of-scope for later consideration

- **Silent observer mode**: capture untriggered group messages into the session transcript without running the agent loop. Best implemented upstream in hermes; a downstream patch would sit in `_handle_text_message`, which churns every release.
- **Ignored threads**: expose the upstream `ignored_threads` list as per-instance config; useful for mute-by-topic.
- **Memory mode selector**: if a third use case appears, collapse `group_sessions_per_user`, `thread_sessions_per_user`, and any silent-observer flag behind a single preset.
