# Vision Input Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user sends a photo in Telegram, the bot "sees" it — the image is passed to the LLM as multimodal content so it can describe, analyze, or respond to visual information.

**Architecture:** Telegram handler downloads the photo, encodes as base64 data URI, builds a multimodal content array (`[image_url, text]`), and passes to the session. Both LLM clients (Anthropic and OpenAI) are updated to handle content arrays. Compaction/serialization strips base64 images to prevent memory bloat.

**Tech Stack:** Elixir, Telegram Bot API, Anthropic Messages API (image content blocks), OpenAI-compatible API (image_url content)

**Spec:** `docs/superpowers/specs/2026-03-24-openrouter-multimodal-design.md` (Spec 4 section)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `v3/apps/pi_core/lib/pi_core/llm/anthropic.ex` | Handle content arrays in convert_message |
| Modify | `v3/apps/pi_core/lib/pi_core/llm/openai.ex` | Pass content arrays through |
| Create | `v3/apps/pi_core/lib/pi_core/multimodal.ex` | Content normalization helpers |
| Modify | `v3/apps/druzhok/lib/druzhok/agent/telegram.ex` | Download photo, build multimodal message |
| Create | `v3/apps/pi_core/test/pi_core/multimodal_test.exs` | Unit tests |

---

### Task 1: Create PiCore.Multimodal helpers

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/multimodal.ex`
- Create: `v3/apps/pi_core/test/pi_core/multimodal_test.exs`

- [ ] **Step 1: Write tests**

Create `v3/apps/pi_core/test/pi_core/multimodal_test.exs`:

```elixir
defmodule PiCore.MultimodalTest do
  use ExUnit.Case

  alias PiCore.Multimodal

  test "to_text converts string content to itself" do
    assert Multimodal.to_text("hello") == "hello"
  end

  test "to_text converts content array to text with image placeholder" do
    content = [
      %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,abc123"}},
      %{"type" => "text", "text" => "What is this?"}
    ]
    result = Multimodal.to_text(content)
    assert result =~ "[изображение]"
    assert result =~ "What is this?"
    refute result =~ "base64"
  end

  test "to_text handles nil" do
    assert Multimodal.to_text(nil) == ""
  end

  test "to_anthropic_content converts image_url to anthropic format" do
    content = [
      %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,/9j/abc"}},
      %{"type" => "text", "text" => "Describe this"}
    ]
    result = Multimodal.to_anthropic_content(content)

    image_block = Enum.find(result, & &1[:type] == "image")
    assert image_block.source.type == "base64"
    assert image_block.source.media_type == "image/jpeg"
    assert image_block.source.data == "/9j/abc"

    text_block = Enum.find(result, & &1[:type] == "text")
    assert text_block.text == "Describe this"
  end

  test "to_anthropic_content handles png" do
    content = [
      %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,iVBOR"}}
    ]
    [block] = Multimodal.to_anthropic_content(content)
    assert block.source.media_type == "image/png"
  end

  test "is_multimodal? returns true for list content" do
    assert Multimodal.is_multimodal?([%{"type" => "text"}])
  end

  test "is_multimodal? returns false for string content" do
    refute Multimodal.is_multimodal?("hello")
  end

  test "is_multimodal? returns false for nil" do
    refute Multimodal.is_multimodal?(nil)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `v3/`): `mix test apps/pi_core/test/pi_core/multimodal_test.exs`

- [ ] **Step 3: Implement the module**

Create `v3/apps/pi_core/lib/pi_core/multimodal.ex`:

```elixir
defmodule PiCore.Multimodal do
  @moduledoc """
  Helpers for multimodal content (images in messages).
  Content can be a string (text only) or a list of content parts (multimodal).
  """

  def is_multimodal?(content) when is_list(content), do: true
  def is_multimodal?(_), do: false

  @doc "Convert content (string or list) to plain text, replacing images with placeholders."
  def to_text(nil), do: ""
  def to_text(content) when is_binary(content), do: content
  def to_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} -> text
      %{"type" => "image_url"} -> "[изображение]"
      %{"type" => "input_audio"} -> "[аудио]"
      _ -> ""
    end)
    |> Enum.reject(& &1 == "")
    |> Enum.join("\n")
  end

  @doc "Convert OpenAI-format content array to Anthropic content blocks."
  def to_anthropic_content(content) when is_list(content) do
    Enum.map(content, fn
      %{"type" => "text", "text" => text} ->
        %{type: "text", text: text}

      %{"type" => "image_url", "image_url" => %{"url" => url}} ->
        {media_type, data} = parse_data_url(url)
        %{type: "image", source: %{type: "base64", media_type: media_type, data: data}}

      other ->
        %{type: "text", text: inspect(other)}
    end)
  end

  defp parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [media_type, data] -> {media_type, data}
      _ -> {"application/octet-stream", rest}
    end
  end
  defp parse_data_url(url), do: {"image/jpeg", url}
end
```

- [ ] **Step 4: Run tests**

Run (from `v3/`): `mix test apps/pi_core/test/pi_core/multimodal_test.exs`

Expected: All 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/pi_core/lib/pi_core/multimodal.ex v3/apps/pi_core/test/pi_core/multimodal_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add PiCore.Multimodal helpers for content conversion"
```

---

### Task 2: Update Anthropic client to handle multimodal content

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/llm/anthropic.ex`

- [ ] **Step 1: Update convert_message to handle content arrays**

Read `v3/apps/pi_core/lib/pi_core/llm/anthropic.ex`. Find the `convert_message/1` function that handles non-tool messages (the one with `role = m[:role]`, around line 203).

Currently it does:
```elixir
content = m[:content] || m["content"] || ""
```

And later builds `%{role: role, content: content}` (for text) or `%{role: role, content: blocks}` (for tool calls).

Update the function to handle multimodal content. When `content` is a list, convert it using `PiCore.Multimodal.to_anthropic_content/1`:

Replace the entire `convert_message(m)` function (the non-tool one) with:

```elixir
defp convert_message(m) do
  role = m[:role] || m["role"]
  content = m[:content] || m["content"] || ""
  tool_calls = m[:tool_calls] || m["tool_calls"]

  if tool_calls && tool_calls != [] do
    blocks = if is_binary(content) && content != "", do: [%{type: "text", text: content}], else: []
    blocks = blocks ++ Enum.map(tool_calls, fn tc ->
      args = get_in(tc, ["function", "arguments"]) || "{}"
      %{
        type: "tool_use",
        id: tc["id"],
        name: get_in(tc, ["function", "name"]),
        input: case Jason.decode(args) do
          {:ok, parsed} -> parsed
          _ -> %{}
        end
      }
    end)
    %{role: role, content: blocks}
  else
    if PiCore.Multimodal.is_multimodal?(content) do
      %{role: role, content: PiCore.Multimodal.to_anthropic_content(content)}
    else
      %{role: role, content: content}
    end
  end
end
```

- [ ] **Step 2: Verify compilation**

Run (from `v3/`): `mix compile`

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/pi_core/lib/pi_core/llm/anthropic.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "handle multimodal content in Anthropic client"
```

---

### Task 3: Update OpenAI client to pass through multimodal content

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/llm/openai.ex`

- [ ] **Step 1: Update build_request to preserve content arrays**

Read `v3/apps/pi_core/lib/pi_core/llm/openai.ex`. The `build_request/1` function builds messages as `[%{role: "system", content: ...} | opts.messages]`. The OpenAI API natively supports `image_url` content type, so content arrays just need to pass through without being stringified.

Currently messages are constructed as:
```elixir
messages = [%{role: "system", content: opts.system_prompt} | opts.messages]
```

This already works — if a message's `content` is a list, it stays a list when encoded to JSON. No change needed to `build_request`.

However, verify that `Jason.encode!` handles mixed content (string and list) correctly. It does — Elixir lists encode to JSON arrays.

**Actually, no code change needed for the OpenAI client.** The existing code already passes content through as-is, and `Jason.encode!` handles both strings and lists.

- [ ] **Step 2: Verify with a quick test**

Run (from `v3/`):
```
mix run -e '
  msg = %{role: "user", content: [%{"type" => "text", "text" => "hi"}, %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,abc"}}]}
  IO.puts(Jason.encode!(%{messages: [msg]}, pretty: true))
'
```

Expected: JSON with content as an array, not a string.

- [ ] **Step 3: Commit (no-op, just verify)**

No commit needed — OpenAI client already handles multimodal content.

---

### Task 4: Update compaction and serialization to strip images

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/loop.ex`

- [ ] **Step 1: Check where content is used as string**

Read `v3/apps/pi_core/lib/pi_core/loop.ex`. Several places assume `content` is a string:

Line 63: `result = %{result | content: PiCore.Sanitize.strip_artifacts(result.content || "")}`
— This is for assistant responses, which are always strings. OK.

Line 35: `base = %{role: m.role, content: m.content || ""}`
— This constructs LLM messages. If content is a list, `m.content || ""` passes the list (truthy). OK.

The main concern is `Compaction` and `SessionStore` which may call `String.slice/3` on content. Read those files to check.

- [ ] **Step 2: Add content normalization in the message transformation**

In `loop.ex`, the message transformation at lines 30-48 builds `llm_messages`. Content arrays should pass through here. Check if any transformation forces strings.

Looking at the code: `base = %{role: m.role, content: m.content || ""}` — when content is a list, this passes the list. When content is nil, it becomes "". This is correct.

The issue is in `Compaction` and `SessionStore`. Add a guard: before any operation that assumes string content, normalize multimodal content to text.

In `v3/apps/pi_core/lib/pi_core/loop.ex`, find the `truncate_output` function and add nearby a content normalization helper that other modules can use. Actually, `PiCore.Multimodal.to_text/1` already handles this.

The safest fix: in `SessionStore.save/2`, normalize content before writing. And in `Compaction`, normalize before measuring token length.

Read `v3/apps/pi_core/lib/pi_core/session_store.ex` and `v3/apps/pi_core/lib/pi_core/compaction.ex` to find where they access `content`.

- [ ] **Step 3: Patch SessionStore to normalize multimodal on save**

Read `v3/apps/pi_core/lib/pi_core/session_store.ex`. Find where it serializes messages. Add `PiCore.Multimodal.to_text/1` normalization for content that is a list, so base64 images are never persisted.

In the serialization path, before writing a message to JSONL, normalize:

```elixir
content = if PiCore.Multimodal.is_multimodal?(msg.content) do
  PiCore.Multimodal.to_text(msg.content)
else
  msg.content
end
```

- [ ] **Step 4: Patch Compaction to handle multimodal content**

Read `v3/apps/pi_core/lib/pi_core/compaction.ex`. Find where it measures content length or calls `String.slice/3` on content. Add the same normalization guard.

- [ ] **Step 5: Verify compilation and tests**

Run (from `v3/`): `mix compile && mix test`

- [ ] **Step 6: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/pi_core/lib/pi_core/session_store.ex v3/apps/pi_core/lib/pi_core/compaction.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "normalize multimodal content in compaction and session store"
```

---

### Task 5: Integrate photo handling in Telegram handler

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`

- [ ] **Step 1: Add photo detection and download helper**

Read `v3/apps/druzhok/lib/druzhok/agent/telegram.ex`. Add a helper near the existing `maybe_transcribe_voice`:

```elixir
defp maybe_build_image_content(file, text, state) do
  if file && file.name == "photo.jpg" do
    case API.fetch_file_by_id(state.token, file.file_id) do
      {:ok, bytes} when byte_size(bytes) <= 5_000_000 ->
        base64 = Base.encode64(bytes)
        caption = if text != "", do: text, else: "Пользователь отправил изображение"
        content = [
          %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,#{base64}"}},
          %{"type" => "text", "text" => caption}
        ]
        {:image, content}

      {:ok, _too_large} -> :skip
      {:error, _} -> :skip
    end
  else
    :not_image
  end
end
```

- [ ] **Step 2: Update process_owner_message to handle photos**

In the `:text` branch of `process_owner_message`, before the voice check, add image detection. The priority order should be: voice transcription > image vision > normal file.

Update the `:text` branch:

```elixir
:text ->
  prompt_text = cond do
    # Voice transcription
    match?({:transcribed, _}, maybe_transcribe_voice(file, state)) ->
      {:transcribed, transcribed} = maybe_transcribe_voice(file, state)
      caption = if text != "", do: " #{text}", else: ""
      "[голосовое сообщение]:#{caption} #{transcribed}"

    # Image — return multimodal content (not a string)
    match?({:image, _}, maybe_build_image_content(file, text, state)) ->
      {:image, content} = maybe_build_image_content(file, text, state)
      content

    # Normal file or text
    true ->
      saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
      build_prompt(text, sender_name, saved_file)
  end

  emit(state, :user_message, %{text: if(is_list(prompt_text), do: PiCore.Multimodal.to_text(prompt_text), else: prompt_text), sender: sender_name, chat_id: chat_id})
  API.send_chat_action(state.token, chat_id)
  dispatch_prompt(prompt_text, chat_id, is_group, state)
  state
```

Wait — this calls `maybe_transcribe_voice` and `maybe_build_image_content` twice each. Better approach: use a single function that resolves the content:

```elixir
defp resolve_message_content(text, file, chat_id, state) do
  cond do
    match?({:transcribed, _}, maybe_transcribe_voice(file, state)) ->
      {:transcribed, transcribed} = maybe_transcribe_voice(file, state)
      caption = if text != "", do: " #{text}", else: ""
      "[голосовое сообщение]:#{caption} #{transcribed}"

    match?({:image, _}, maybe_build_image_content(file, text, state)) ->
      {:image, content} = maybe_build_image_content(file, text, state)
      content

    true ->
      saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
      build_prompt(text, "", saved_file)
  end
end
```

Actually, `match?` + destructure is still two calls. Use `case` with assignment:

```elixir
defp resolve_message_content(text, file, chat_id, state) do
  voice_result = maybe_transcribe_voice(file, state)
  image_result = if voice_result == :not_voice, do: maybe_build_image_content(file, text, state), else: :not_image

  case {voice_result, image_result} do
    {{:transcribed, transcribed}, _} ->
      caption = if text != "", do: " #{text}", else: ""
      "[голосовое сообщение]:#{caption} #{transcribed}"

    {_, {:image, content}} ->
      content

    _ ->
      saved_file = if file, do: save_incoming_file(file, chat_id, state), else: nil
      build_prompt(text, "", saved_file)
  end
end
```

Then simplify `process_owner_message` `:text` branch:

```elixir
:text ->
  prompt_text = resolve_message_content(text, file, chat_id, state)
  display = if is_list(prompt_text), do: PiCore.Multimodal.to_text(prompt_text), else: prompt_text
  emit(state, :user_message, %{text: display, sender: sender_name, chat_id: chat_id})
  API.send_chat_action(state.token, chat_id)
  dispatch_prompt(prompt_text, chat_id, is_group, state)
  state
```

And update `resolve_voice_or_file` (used by group messages) to also handle images:

```elixir
defp resolve_voice_or_file(text, file, chat_id, state) do
  voice_result = maybe_transcribe_voice(file, state)
  image_result = if voice_result == :not_voice, do: maybe_build_image_content(file, text, state), else: :not_image

  case {voice_result, image_result} do
    {{:transcribed, transcribed}, _} ->
      caption = if text != "", do: " #{text}", else: ""
      {"[голосовое сообщение]:#{caption} #{transcribed}", nil}

    {_, {:image, content}} ->
      # For groups, convert to text — multimodal in groups is complex
      {PiCore.Multimodal.to_text(content), nil}

    _ ->
      saved = if file, do: save_incoming_file(file, chat_id, state), else: nil
      {text, saved}
  end
end
```

Note: For group messages, we convert images to text placeholder for now. Full multimodal in groups can be added later.

- [ ] **Step 3: Handle multimodal content in Session.prompt**

Read `v3/apps/pi_core/lib/pi_core/session.ex`. The `handle_cast({:prompt, text}, state)` creates a `Message` with `content: text`. If `text` is actually a list (multimodal), it works — the `content` field is untyped.

No change needed — the `Message` struct accepts any value for `content`.

- [ ] **Step 4: Verify compilation**

Run (from `v3/`): `mix compile`

- [ ] **Step 5: Run tests**

Run (from `v3/`): `mix test`

- [ ] **Step 6: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/druzhok/lib/druzhok/agent/telegram.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add vision input: pass photos to LLM as multimodal content"
```

---

### Task 6: Full verification

- [ ] **Step 1: Run full test suite**

Run (from `v3/`): `mix test`

Expected: All pi_core and druzhok_web tests pass. Pre-existing druzhok system_prompt failures only.

- [ ] **Step 2: Verify multimodal message flow**

Run (from `v3/`):
```
mix run -e '
  # Verify Anthropic conversion
  content = [
    %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,/9j/test"}},
    %{"type" => "text", "text" => "What is this?"}
  ]
  result = PiCore.Multimodal.to_anthropic_content(content)
  IO.inspect(result, label: "Anthropic blocks")

  # Verify text normalization
  IO.puts("Text: " <> PiCore.Multimodal.to_text(content))
'
```
