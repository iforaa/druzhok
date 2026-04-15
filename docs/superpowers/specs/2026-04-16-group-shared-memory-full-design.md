# Shared group memory (full)

Date: 2026-04-16
Status: Draft — pending user review

## Problem

Today in a Telegram group chat where the bot is installed:

- Messages that don't @mention the bot (or reply to it, or trigger a regex wake-word) are silently dropped at `_handle_text_message` — they never enter any session transcript.
- Even messages that *do* trigger the bot get split across separate sessions when Telegram assigns different `message_thread_id` values to distinct reply-chains (regular supergroups, no forum topics involved).

Combined, the bot perceives the group as a series of disconnected fragments. If three people are chatting, and then one @mentions the bot asking about what was just said, the bot has none of it.

We already deployed `group_sessions_per_user: false` for Vasya on 2026-04-15, which collapsed per-user isolation. That helps when each user @mentions the bot — their contributions merge into one transcript. It does not help when messages are sent without triggering, and it does not merge reply-chain threads.

This spec productionises two additional downstream patches against hermes-agent that, together, give a group chat a single continuous memory.

## Scope

One per-instance boolean exposed in the druzhok dashboard: **"Shared group memory"** (DB column `group_shared_memory`, yaml key `group_shared_memory`). Default `false`. When enabled:

- **Thread collapse.** In `_build_message_event`, `message_thread_id` is stripped from the message source for group chats. All reply-chain threads in a group funnel into one session key.
- **Silent observer.** In `_handle_text_message`, when `_should_process_message` returns false for a group message, the message is appended to the session transcript as a `role: "user"` entry instead of being dropped. The agent loop is **not** invoked — the bot only speaks when triggered, as before.

Both effects are gated on the single `group_shared_memory` config key. Either both are on or both are off.

The `update-hermes` skill (at `~/.claude/skills/update-hermes/SKILL.md`) is updated with two new Customization sections so the patches re-apply on every upstream pull.

**Explicitly out of scope:**

- Separate toggles for thread collapse vs. silent observer. Bundled by design; the combined behaviour is the coherent one.
- DM behaviour — unchanged.
- Non-Telegram platforms. Both patches live in `gateway/platforms/telegram.py`.
- Upstream PR. May happen later; not in this project.
- UI changes for the existing `ignored_threads` hermes feature. Separate concern.

## Why this is a downstream patch, not upstream

`telegram.py` receives ~300 lines of churn per weekly release, but the specific insertion points we touch are small and localized:

- `_build_message_event` — one modification in the source construction. Has seen one substantive change in the last 6 releases (forum topic skill binding for groups).
- `_handle_text_message` — one 3-line insertion at the existing early-return. Churn in this function has been around batching and null-safety, never the early-return shape itself.
- `_record_passive_group_message` — a fresh helper placed at the end of the `TelegramAdapter` class, detached from the churn zone.

Merge conflicts on these sites, if they occur, are expected to resolve in under a minute. The `update-hermes` skill is the re-apply harness.

## Design

### Hermes source patches

**Patch #3 — `telegram.py:_build_message_event`** (3 additional lines)

Location: at `telegram.py:2666` area, inside `_build_message_event`, just before `source = self.build_source(...)`.

```python
# Druzhok patch: when group_shared_memory is on, collapse Telegram
# reply-chain message_thread_id values for group chats so all messages
# land in one session per group.
effective_thread_id = thread_id_str
if chat_type == "group" and self.config.extra.get("group_shared_memory", False):
    effective_thread_id = None

source = self.build_source(
    chat_id=str(chat.id),
    chat_name=chat.title or (chat.full_name if hasattr(chat, "full_name") else None),
    chat_type=chat_type,
    user_id=str(user.id) if user else None,
    user_name=user.full_name if user else None,
    thread_id=effective_thread_id,
    chat_topic=chat_topic,
)
```

The `chat_topic` value (populated for group forum topics via `group_topics` config) is left untouched — the bot still knows the topic name for skill auto-binding, but session keying ignores the numeric thread id.

**Patch #4 — `telegram.py:_handle_text_message`** (3 additional lines at the early return, plus a new helper)

At `telegram.py:2156`:

```python
async def _handle_text_message(self, update, context):
    if not update.message or not update.message.text:
        return
    if not self._should_process_message(update.message):
        # Druzhok patch: silent observer for group chats — record the
        # message into the session transcript so the bot has context
        # when it IS later addressed. Agent loop is not invoked.
        if self._is_group_chat(update.message) and self.config.extra.get("group_shared_memory", False):
            await self._record_passive_group_message(update.message)
        return

    event = self._build_message_event(update.message, MessageType.TEXT)
    event.text = self._clean_bot_trigger_text(event.text)
    self._enqueue_text_event(event)
```

And a new helper placed at the very end of the `TelegramAdapter` class (after the last existing method):

```python
async def _record_passive_group_message(self, message) -> None:
    """Record an untriggered group message as passive context.

    Builds a MessageEvent as if the bot were going to process the
    message, then appends a `role: "user"` entry to the session
    transcript without invoking the agent loop. Prefix the text with
    the sender's display name so the model can attribute it later.
    """
    try:
        event = self._build_message_event(message, MessageType.TEXT)
        if not event.text:
            return
        user_label = event.source.user_name or event.source.user_id or "user"
        content = f"{user_label}: {event.text}"

        from gateway.session import build_session_key
        session_key = build_session_key(
            event.source,
            group_sessions_per_user=self.config.extra.get("group_sessions_per_user", True),
            thread_sessions_per_user=self.config.extra.get("thread_sessions_per_user", False),
        )
        session_entry = self._session_store.get_or_create_session(
            session_key=session_key,
            source=event.source,
        )
        self._session_store.append_to_transcript(
            session_entry.session_id,
            {"role": "user", "content": content},
        )
    except Exception as exc:
        logger.debug("[%s] Passive record failed: %s", self.name, exc)
```

Error handling: never raise. A passive-record failure must not break message handling for triggered messages; a silently dropped observation is acceptable, crashing the handler is not.

The helper uses the existing `self._session_store` attribute (already populated on the adapter by the gateway runner). Session APIs used are `get_or_create_session` (`session.py:682`) and `append_to_transcript` (`session.py:947`), both long-standing and stable. No new data model.

### Druzhok-side changes

Mirrors the pattern we just shipped for `group_sessions_per_user`:

1. **Migration.** Add column:

   ```elixir
   alter table(:instances) do
     add :group_shared_memory, :boolean, default: false, null: false
   end
   ```

   Default `false` keeps existing bots unchanged.

2. **Schema.** Add field and cast in `apps/druzhok/lib/druzhok/instance.ex`.

3. **Config emission.** Two places in `apps/druzhok/lib/druzhok/runtime/hermes.ex`:
   - `build_config_yaml/1` — emits `group_shared_memory: <bool>` in the generated yaml, same style as `group_sessions_per_user`.
   - `sync_config/2` — new helper `sync_group_shared_memory/2`, appended to the pipeline, idempotent (replaces existing line or appends if absent).

4. **Dashboard.** New checkbox under the existing "Group Chats" section in `settings_tab.ex`, placed below the "Shared group memory" (isolated-per-user) toggle from 2026-04-15. Label: "Record all group messages — bot sees everything, responds only when addressed". `phx-click` event handler mirrors `toggle_group_sessions_per_user`.

   The two toggles are related but independent: `group_sessions_per_user` controls per-user isolation, `group_shared_memory` enables the downstream patches. Help text on the new toggle makes that clear.

### update-hermes skill updates

Add two new Customization sections to `~/.claude/skills/update-hermes/SKILL.md`, following the existing Customization 1 template:

**Customization 3: Collapse group-chat thread_id**
- *Intent.* When `group_shared_memory: true` in config.yaml, make all Telegram group-chat messages share one session regardless of `message_thread_id`. Without this, reply-chains split into separate sessions and the bot loses context across chains.
- *Where.* `gateway/platforms/telegram.py`, inside `_build_message_event`.
- *How to find it.* Search for `self.build_source(` inside `_build_message_event`. There should be exactly one call; it's surrounded by thread-id resolution code.
- *Apply.* The 3-line insertion shown above.
- *Verify.* `grep 'group_shared_memory' gateway/platforms/telegram.py` returns at least 2 hits (this patch + patch #4).
- *Skip condition.* If hermes gains a native `collapse_threads` or similar config, use that and remove this customization.

**Customization 4: Silent observer for group chats**
- *Intent.* When `group_shared_memory: true` in config.yaml, record untriggered group-chat messages into the session transcript without invoking the agent loop, so the bot has conversational context when later addressed.
- *Where.* `gateway/platforms/telegram.py`, inside `_handle_text_message` early return, plus a new helper method `_record_passive_group_message` at the end of the `TelegramAdapter` class.
- *How to find it.* Search for `async def _handle_text_message`. The existing body ends with `if not self._should_process_message(update.message): return`. Insert the 3-line block immediately before that `return`. For the helper, place it as the last method in the class.
- *Apply.* The code shown above.
- *Verify.* `grep -c _record_passive_group_message gateway/platforms/telegram.py` returns 2 (one call site, one definition).
- *Skip condition.* If hermes gains a native "silent observer" or "listen-only" mode, use that.

Both customizations are read by the single config key `group_shared_memory`. The skill notes that they should always be applied together.

## Testing

Unit tests (Elixir, `hermes_test.exs`):

- `build_config_yaml/1` emits `group_shared_memory: true` and `false` correctly; defaults to `false` when the key is missing on the instance map.
- `sync_config/2` appends the key when absent, replaces without duplicating when present.

Manual smoke test on the remote, toggling the dashboard checkbox for a non-production bot (or Vasya with explicit user consent):

1. Three group messages without @mention → verify they show up in Vasya's session transcript as `role: "user"` entries with the sender name prefix.
2. One message @mentioning Vasya referencing the prior chat → verify Vasya has context from all three prior messages.
3. Turn the toggle off → verify untriggered messages are no longer recorded (new messages after toggle-off only).

Hermes tests: none. The two patches are additive and don't have upstream test coverage we'd need to update. If we decide to upstream later, we'll add `tests/gateway/test_telegram_passive_record.py` style tests then.

## Operational notes

- Feature flag defaults to off. Nothing changes for Vasya or Рун until the dashboard toggle is flipped.
- Toggling triggers a container restart via `BotManager.restart`, same as existing toggles.
- Toggling OFF does not retroactively scrub previously-recorded passive messages from the transcript. They remain as context. If you want them gone, use "Clear History" or edit the session files.
- Every hermes pull will pass through `update-hermes`, which re-applies customizations 3 and 4. Watch the skill's output for `grep` verification lines.

## Open questions

None at spec time.
