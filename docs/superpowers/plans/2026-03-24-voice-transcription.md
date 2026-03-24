# Voice Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user sends a voice or audio message in Telegram, the bot transcribes it via OpenRouter and processes the text as a normal message.

**Architecture:** New `Druzhok.Telegram.API.fetch_file_by_id/2` wraps existing `get_file` + `download_file`. New `PiCore.Transcription` module sends audio bytes to OpenRouter's Gemini Flash Lite for transcription. `Druzhok.Agent.Telegram` detects voice/audio messages and transcribes before dispatching to the session.

**Tech Stack:** Elixir, Finch (HTTP), OpenRouter API (input_audio content type)

**Spec:** `docs/superpowers/specs/2026-03-24-openrouter-multimodal-design.md` (Spec 2 section)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `v3/apps/druzhok/lib/druzhok/telegram/api.ex` | Add `fetch_file_by_id/2` wrapper |
| Create | `v3/apps/pi_core/lib/pi_core/transcription.ex` | Audio→text via OpenRouter |
| Modify | `v3/apps/druzhok/lib/druzhok/agent/telegram.ex` | Detect voice, transcribe before dispatch |
| Modify | `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex` | Add transcription settings |
| Create | `v3/apps/pi_core/test/pi_core/transcription_test.exs` | Unit tests for transcription |

---

### Task 1: Add fetch_file_by_id to Telegram API

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/telegram/api.ex`

- [ ] **Step 1: Add the function**

In `v3/apps/druzhok/lib/druzhok/telegram/api.ex`, after the existing `download_file/2` function (after line 57), add:

```elixir
def fetch_file_by_id(token, file_id) do
  with {:ok, %{"file_path" => path}} <- get_file(token, file_id),
       {:ok, bytes} <- download_file(token, path) do
    {:ok, bytes}
  end
end
```

- [ ] **Step 2: Verify compilation**

Run (from `v3/` directory): `mix compile`

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/druzhok/lib/druzhok/telegram/api.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add fetch_file_by_id to Telegram API"
```

---

### Task 2: Implement PiCore.Transcription module

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/transcription.ex`
- Create: `v3/apps/pi_core/test/pi_core/transcription_test.exs`

- [ ] **Step 1: Write failing test**

Create `v3/apps/pi_core/test/pi_core/transcription_test.exs`:

```elixir
defmodule PiCore.TranscriptionTest do
  use ExUnit.Case

  test "transcribe returns text from LLM response" do
    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{content: "Hello world", tool_calls: [], reasoning: ""}}
    end

    audio_bytes = <<0, 1, 2, 3>>  # fake audio
    result = PiCore.Transcription.transcribe(audio_bytes, format: "ogg", llm_fn: mock_llm)
    assert {:ok, "Hello world"} = result
  end

  test "transcribe returns error when LLM fails" do
    mock_llm = fn _opts -> {:error, "API error"} end

    audio_bytes = <<0, 1, 2, 3>>
    result = PiCore.Transcription.transcribe(audio_bytes, format: "ogg", llm_fn: mock_llm)
    assert {:error, _} = result
  end

  test "transcribe returns error for empty transcription" do
    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{content: "", tool_calls: [], reasoning: ""}}
    end

    audio_bytes = <<0, 1, 2, 3>>
    result = PiCore.Transcription.transcribe(audio_bytes, format: "ogg", llm_fn: mock_llm)
    assert {:error, "Empty transcription"} = result
  end

  test "build_request creates correct message structure" do
    audio_bytes = <<0, 1, 2, 3>>
    request = PiCore.Transcription.build_request(audio_bytes, "ogg")

    assert length(request.messages) == 1
    [msg] = request.messages
    assert msg.role == "user"
    assert is_list(msg.content)

    audio_part = Enum.find(msg.content, & &1["type"] == "input_audio")
    assert audio_part != nil
    assert audio_part["input_audio"]["format"] == "ogg"
    assert audio_part["input_audio"]["data"] == Base.encode64(audio_bytes)

    text_part = Enum.find(msg.content, & &1["type"] == "text")
    assert text_part != nil
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `v3/` directory): `mix test apps/pi_core/test/pi_core/transcription_test.exs`

Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement the module**

Create `v3/apps/pi_core/lib/pi_core/transcription.ex`:

```elixir
defmodule PiCore.Transcription do
  @moduledoc """
  Transcribes audio to text using an LLM with audio input support (e.g., Gemini Flash Lite via OpenRouter).
  """

  alias PiCore.LLM.Client.Result

  @default_model "google/gemini-2.0-flash-lite-001"
  @system_prompt "You are a transcription assistant. Transcribe the audio to text exactly as spoken. Return only the transcription, nothing else. If the audio is in Russian, transcribe in Russian. If in English, transcribe in English."

  def transcribe(audio_bytes, opts \\ []) do
    format = Keyword.get(opts, :format, "ogg")
    request = build_request(audio_bytes, format)

    llm_fn = Keyword.get(opts, :llm_fn) || build_default_llm_fn(opts)

    case llm_fn.(request) do
      {:ok, %Result{content: content}} when content != "" ->
        {:ok, String.trim(content)}

      {:ok, %Result{content: ""}} ->
        {:error, "Empty transcription"}

      {:ok, %Result{content: nil}} ->
        {:error, "Empty transcription"}

      {:error, reason} ->
        {:error, "Transcription failed: #{inspect(reason)}"}
    end
  end

  def build_request(audio_bytes, format) do
    base64_audio = Base.encode64(audio_bytes)

    %{
      system_prompt: @system_prompt,
      messages: [
        %{
          role: "user",
          content: [
            %{"type" => "input_audio", "input_audio" => %{"data" => base64_audio, "format" => format}},
            %{"type" => "text", "text" => "Transcribe this audio."}
          ]
        }
      ],
      tools: [],
      max_tokens: 4096,
      stream: false,
      on_delta: nil,
      on_event: nil
    }
  end

  defp build_default_llm_fn(opts) do
    model = Keyword.get(opts, :model, @default_model)
    api_url = Keyword.get(opts, :api_url)
    api_key = Keyword.get(opts, :api_key)

    fn request ->
      PiCore.LLM.OpenAI.completion(Map.merge(request, %{
        model: model,
        provider: :openrouter,
        api_url: api_url,
        api_key: api_key
      }))
    end
  end
end
```

**Key design:** The module accepts an optional `llm_fn` for testing (dependency injection). In production, it builds an OpenAI-compatible request with `input_audio` content type and sends to OpenRouter.

- [ ] **Step 4: Run tests**

Run (from `v3/` directory): `mix test apps/pi_core/test/pi_core/transcription_test.exs`

Expected: All 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/pi_core/lib/pi_core/transcription.ex v3/apps/pi_core/test/pi_core/transcription_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add PiCore.Transcription module for audio→text"
```

---

### Task 3: Integrate transcription into Telegram handler

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

This is the core integration. When a voice/audio message arrives, transcribe it before dispatching.

- [ ] **Step 1: Add transcription helper function**

In `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`, add a private function near the bottom (before the existing `strip_artifacts` at line 613):

```elixir
# Voice/audio transcription — downloads file, sends to OpenRouter, returns text
defp maybe_transcribe_voice(file, state) do
  if file && file.name in ["voice.ogg"] do
    transcription_enabled = Druzhok.Settings.get("transcription_enabled") != "false"

    if transcription_enabled do
      # Check file size (voice metadata not always available, so just try)
      case API.fetch_file_by_id(state.token, file.file_id) do
        {:ok, bytes} when byte_size(bytes) <= 10_000_000 ->
          api_key = Druzhok.Settings.api_key("openrouter")
          api_url = Druzhok.Settings.api_url("openrouter")
          model = Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001"

          if api_key do
            case PiCore.Transcription.transcribe(bytes,
              format: "ogg",
              model: model,
              api_url: api_url,
              api_key: api_key
            ) do
              {:ok, text} -> {:transcribed, text}
              {:error, _reason} -> :skip
            end
          else
            :skip
          end

        {:ok, _too_large} -> :skip
        {:error, _} -> :skip
      end
    else
      :disabled
    end
  else
    :not_voice
  end
end
```

- [ ] **Step 2: Modify process_owner_message to use transcription**

In `process_owner_message/6` (line 517), the current flow is:
1. `save_incoming_file` saves the file
2. `build_prompt` creates text like "[User attached a file: inbox/voice.ogg]"

Change it to check for voice transcription first. Replace the function (lines 517-546):

```elixir
defp process_owner_message(chat_id, text, sender_id, sender_name, file, is_group, state) do
  is_owner = state.owner_telegram_id == sender_id

  case Router.parse_command(text) do
    {:command, "start"} ->
      dispatch_prompt("User #{sender_name} just started the bot. Introduce yourself.", chat_id, is_group, state)
      state

    {:command, cmd} when cmd in ["reset", "abort"] and is_group and not is_owner ->
      state

    {:command, "reset"} ->
      dispatch_session(chat_id, state, &PiCore.Session.reset/1)
      API.send_message(state.token, chat_id, "Session reset!")
      state

    {:command, "abort"} ->
      dispatch_session(chat_id, state, &PiCore.Session.abort/1)
      API.send_message(state.token, chat_id, "Aborted.")
      state

    :text ->
      # Try voice transcription first
      prompt_text = case maybe_transcribe_voice(file, state) do
        {:transcribed, transcribed} ->
          caption = if text != "", do: " #{text}", else: ""
          "[голосовое сообщение]:#{caption} #{transcribed}"

        _ ->
          # Normal file handling
          saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
          build_prompt(text, sender_name, saved_file)
      end

      emit(state, :user_message, %{text: prompt_text, sender: sender_name, chat_id: chat_id})
      API.send_chat_action(state.token, chat_id)
      dispatch_prompt(prompt_text, chat_id, is_group, state)
      state
  end
end
```

- [ ] **Step 3: Also handle voice in group messages**

In `process_group_message_always/6` (line 414) and `process_group_message_buffer/7` (line 428), voice messages also need transcription. The simplest approach: add a helper that either transcribes or falls back to normal file handling.

Add after `maybe_transcribe_voice`:

```elixir
defp resolve_voice_or_file(text, file, chat_id, state) do
  case maybe_transcribe_voice(file, state) do
    {:transcribed, transcribed} ->
      caption = if text != "", do: " #{text}", else: ""
      {"[голосовое сообщение]:#{caption} #{transcribed}", nil}

    _ ->
      saved = if file, do: save_incoming_file(file, chat_id, state), else: nil
      {text, saved}
  end
end
```

Then update `process_group_message_always` to use it:

```elixir
defp process_group_message_always(chat_id, text, sender_name, file, is_triggered, chat, state) do
  {resolved_text, saved_file} = resolve_voice_or_file(text, file, chat_id, state)
  base_prompt = build_group_prompt(resolved_text, sender_name, saved_file, is_triggered)
  prompt = group_intro("always", chat) <> base_prompt
  emit(state, :user_message, %{text: base_prompt, sender: sender_name, chat_id: chat_id})

  if is_triggered do
    API.send_chat_action(state.token, chat_id)
  end

  dispatch_prompt(prompt, chat_id, true, state)
  state
end
```

And `process_group_message_buffer` similarly — only in the triggered branch:

```elixir
defp process_group_message_buffer(chat_id, text, sender_name, file, is_triggered, buffer_size, chat, state) do
  if is_triggered do
    {resolved_text, saved_file} = resolve_voice_or_file(text, file, chat_id, state)
    buffered = Druzhok.GroupBuffer.flush(state.instance_name, chat_id)
    current_prompt = build_group_prompt(resolved_text, sender_name, saved_file, true)
    prompt = group_intro("buffer", chat) <> Druzhok.GroupBuffer.format_context(buffered, current_prompt)

    emit(state, :user_message, %{text: current_prompt, sender: sender_name, chat_id: chat_id})
    API.send_chat_action(state.token, chat_id)
    dispatch_prompt(prompt, chat_id, true, state)
    state
  else
    file_ref = if file, do: "[#{file.name || "file"}]", else: nil
    Druzhok.GroupBuffer.push(state.instance_name, chat_id, %{
      sender: sender_name,
      text: text,
      timestamp: System.os_time(:millisecond),
      file: file_ref
    }, buffer_size)

    emit(state, :user_message, %{text: "[#{sender_name}]: #{text}", sender: sender_name, chat_id: chat_id})
    state
  end
end
```

- [ ] **Step 4: Verify compilation**

Run (from `v3/` directory): `mix compile`

Expected: Compiles with no errors.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/druzhok/lib/druzhok/agent/telegram.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "integrate voice transcription into Telegram handler"
```

---

### Task 4: Add transcription settings to dashboard

**Files:**
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Add assigns in mount**

In `settings_live.ex`, inside the `assign(socket, ...)` block in `mount/3`, add:

```elixir
transcription_enabled: Druzhok.Settings.get("transcription_enabled") || "true",
transcription_model: Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001",
```

- [ ] **Step 2: Add save handler**

In `handle_event("save", ...)`, add:

```elixir
if val = non_empty(params["transcription_enabled"]) do
  Druzhok.Settings.set("transcription_enabled", val)
end
if val = non_empty(params["transcription_model"]) do
  Druzhok.Settings.set("transcription_model", val)
end
```

- [ ] **Step 3: Add re-assign after save**

```elixir
transcription_enabled: Druzhok.Settings.get("transcription_enabled") || "true",
transcription_model: Druzhok.Settings.get("transcription_model") || "google/gemini-2.0-flash-lite-001",
```

- [ ] **Step 4: Add UI section**

After the OpenRouter section in the template, add:

```heex
<div class="bg-white rounded-xl border border-gray-200 p-6">
  <h2 class="text-sm font-semibold mb-4">Voice Transcription</h2>
  <p class="text-xs text-gray-500 mb-4">Uses OpenRouter to transcribe voice messages to text. Requires OpenRouter API key.</p>
  <div class="space-y-3">
    <div>
      <label class="block text-xs text-gray-500 mb-1">Enabled</label>
      <select name="transcription_enabled"
              class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
        <option value="true" selected={@transcription_enabled == "true"}>Yes</option>
        <option value="false" selected={@transcription_enabled == "false"}>No</option>
      </select>
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Model</label>
      <input name="transcription_model" value={@transcription_model}
             class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
    </div>
  </div>
</div>
```

- [ ] **Step 5: Verify compilation**

Run (from `v3/` directory): `mix compile`

- [ ] **Step 6: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add voice transcription settings to dashboard"
```

---

### Task 5: Full test suite and verification

- [ ] **Step 1: Run full test suite**

Run (from `v3/` directory): `mix test`

Expected: All existing tests pass, no regressions. The pre-existing `system_prompt` failures are expected.

- [ ] **Step 2: Update AGENTS.md template**

In `workspace-template/AGENTS.md`, the tool list already mentions `web_fetch`. Verify voice transcription is documented by checking that the tool description mentions voice messages are automatically transcribed. If not, no change needed — transcription is transparent to the bot (it just sees text).

Actually, no AGENTS.md change needed — transcription happens before the message reaches the session. The bot never sees voice files, only transcribed text. The feature is invisible to the agent.
