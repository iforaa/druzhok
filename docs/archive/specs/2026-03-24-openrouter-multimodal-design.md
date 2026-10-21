# OpenRouter Integration + Multimodal Capabilities — Design Spec

## Summary

Add OpenRouter as a third LLM provider alongside Anthropic and Nebius, then use it to enable voice transcription, image generation, and vision input for the Telegram bot.

## Scope — 4 Specs

| Spec | What | Depends on |
|------|------|------------|
| 1. OpenRouter Provider | Routing, API key, dashboard, seed models | Nothing |
| 2. Voice Transcription | Telegram voice→text via OpenRouter Gemini | Spec 1 |
| 3. Image Generation Tool | `generate_image` tool with dashboard toggle | Spec 1 |
| 4. Vision Input | Photos sent to LLM as image content | Nothing |

Specs 2, 3, 4 are independent of each other. Spec 4 doesn't require OpenRouter (works with Claude).

---

## Spec 1: OpenRouter Provider

### Goal

Add "openrouter" as a first-class provider so users can select OpenRouter models in the dashboard and route LLM calls through `https://openrouter.ai/api/v1`.

### Changes

**`v3/apps/druzhok/lib/druzhok/settings.ex`**

Add `"openrouter"` arm to the existing `case` in `api_url/1` and `api_key/1`:

```elixir
def api_url(provider) do
  case provider do
    "anthropic" -> ...  # existing
    "openrouter" -> get("openrouter_api_url") || Application.get_env(:pi_core, :openrouter_api_url) || "https://openrouter.ai/api/v1"
    _ -> ...            # existing nebius default
  end
end
```

Same pattern for `api_key/1` — add `"openrouter"` arm before the catch-all.

**`v3/apps/pi_core/lib/pi_core/llm/client.ex`**

No change needed — `detect_provider/1` already falls through to `:openai` for anything that's not "anthropic". OpenRouter is OpenAI-compatible.

**`v3/apps/pi_core/lib/pi_core/llm/openai.ex`**

Add OpenRouter-required headers when provider is openrouter:

```elixir
# In the headers list, when provider is :openrouter:
{"HTTP-Referer", "https://druzhok.app"},
{"X-Title", "Druzhok"}
```

The OpenAI client already receives the full opts map which includes `:provider`. Add a conditional in the headers construction:

```elixir
headers = [
  {"authorization", "Bearer #{opts.api_key}"},
  {"content-type", "application/json"}
]
headers = if opts[:provider] in [:openrouter, "openrouter"] do
  headers ++ [{"HTTP-Referer", "https://druzhok.app"}, {"X-Title", "Druzhok"}]
else
  headers
end
```

Note: `detect_provider/1` in `client.ex` routes OpenRouter to `:openai` (the OpenAI client), but the `:provider` atom `:openrouter` is preserved in opts for header injection.

**`v3/config/runtime.exs`**

Add:
```elixir
openrouter_api_key: System.get_env("OPENROUTER_API_KEY"),
openrouter_api_url: System.get_env("OPENROUTER_API_URL") || "https://openrouter.ai/api/v1"
```

**`v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`**

Add OpenRouter API key and URL fields to the settings page, same pattern as Anthropic/Nebius.

**`v3/apps/druzhok_web/lib/druzhok_web_web/live/models_live.ex`**

Add "openrouter" to the provider dropdown options (currently: "openai", "anthropic").

**`v3/apps/druzhok/lib/druzhok/instance_manager.ex`**

`resolve_credentials/2` already calls `Settings.api_url(provider)` and `Settings.api_key(provider)` — no change needed since we're adding the "openrouter" case to `Settings`.

`provider_atom/1` — add `defp provider_atom("openrouter"), do: :openrouter`.

**Migration — seed models:**

```sql
INSERT INTO models (model_id, label, provider, context_window, supports_tools, position) VALUES
  ('google/gemini-2.0-flash-lite-001', 'Gemini 2.0 Flash Lite', 'openrouter', 1048576, true, 20),
  ('google/gemini-2.5-flash-image', 'Gemini 2.5 Flash Image', 'openrouter', 1048576, false, 21),
  ('google/gemini-2.5-flash', 'Gemini 2.5 Flash', 'openrouter', 1048576, true, 22);
```

### Testing

- Unit test: `Settings.api_url("openrouter")` returns correct URL
- Unit test: `Settings.api_key("openrouter")` resolves from DB then env
- Integration test: make a simple completion call to OpenRouter with a seeded model (requires API key)

---

## Spec 2: Voice Transcription

### Goal

When a user sends a voice or audio message in Telegram, the bot transcribes it and processes the text as a normal message.

### Flow

```
User sends voice → Telegram
  → Bot downloads OGG via Telegram Bot API (getFile → download)
  → Sends audio (base64) to Gemini Flash Lite via OpenRouter
  → Gets transcribed text back
  → Injects as user message: "[голосовое сообщение]: {text}"
  → Session processes normally
```

### Components

**`Druzhok.Telegram.API.download_file(token, file_id)`**

New function. Calls Telegram's `getFile` API to get the file path, then downloads the file bytes. Returns `{:ok, bytes}` or `{:error, reason}`.

**`PiCore.Transcription`**

New module. Takes audio bytes + format, sends to an OpenRouter model for transcription.

```elixir
PiCore.Transcription.transcribe(audio_bytes, format: "ogg", opts)
# opts: %{model: "google/gemini-2.0-flash-lite-001", api_url: "...", api_key: "..."}
# => {:ok, "transcribed text"}
# => {:error, "reason"}
```

Implementation: builds an OpenAI-compatible messages request with `input_audio` content type (verified as the OpenRouter format for audio input):

```json
{
  "model": "google/gemini-2.0-flash-lite-001",
  "messages": [{
    "role": "user",
    "content": [
      {"type": "input_audio", "input_audio": {"data": "<base64>", "format": "ogg"}},
      {"type": "text", "text": "Transcribe this audio to text. Return only the transcription, nothing else."}
    ]
  }]
}
```

Supported audio formats: wav, mp3, aiff, aac, ogg, flac, m4a. Audio must be base64-encoded (URLs not supported).

Uses a direct `Finch` HTTP call to the OpenRouter API (not `PiCore.LLM.OpenAI.completion/1`, since that client doesn't handle `input_audio` content types). The transcription module builds its own request.

**`Druzhok.Agent.Telegram`**

In the message handling path, before passing text to the session:
1. Check if message has voice/audio attachment
2. If yes, download file via `Telegram.API.download_file`
3. Call `PiCore.Transcription.transcribe`
4. Prepend transcribed text: `"[голосовое сообщение]: {text}"`
5. Pass to session as normal text

**Settings:**

- `transcription_model` — default: `google/gemini-2.0-flash-lite-001`
- `transcription_enabled` — boolean, default: true
- Both configurable in dashboard settings page

**Credential resolution:** `Agent.Telegram` calls `Druzhok.Settings.api_key("openrouter")` and `Druzhok.Settings.api_url("openrouter")` directly to get OpenRouter credentials for transcription. This happens outside the normal LLM loop — the transcription is a preprocessing step before the message reaches the session.

**File size guard:** Check `msg["voice"]["file_size"]` before downloading. Reject files >10 MB to avoid excessive memory usage and slow transcription. Telegram voice messages are typically <1 MB.

When `transcription_enabled` is false, voice messages are passed as text: `"[голосовое сообщение — расшифровка отключена]"`.

### Testing

- Unit test: `Transcription.transcribe/2` with mocked LLM function
- Integration test: full pipeline with a real audio file (requires OpenRouter API key)

---

## Spec 3: Image Generation Tool

### Goal

The bot can generate images when the LLM decides it's appropriate, using Gemini Flash Image via OpenRouter.

### Flow

```
LLM calls generate_image(prompt: "a cat in space")
  → Tool sends request to Gemini 2.5 Flash Image via OpenRouter
  → Response contains base64 image data
  → Tool saves to temp file in workspace
  → Sends image to user via Telegram (reusing send_file mechanism)
  → Returns "Image generated and sent" to LLM
```

### Components

**`PiCore.Tools.GenerateImage`**

New tool module.

```elixir
%Tool{
  name: "generate_image",
  description: "Generate an image from a text description. The image will be sent to the user.",
  parameters: %{
    prompt: %{type: :string, description: "Description of the image to generate"}
  }
}
```

Execute:
1. Call OpenRouter with the image generation model
2. Parse base64 image from response content
3. Save to temp file: `{workspace}/tmp/generated_{timestamp}.png`
4. Send via Telegram using `context[:send_file_fn]` (same mechanism as `send_file` tool)
5. Clean up temp file
6. Return `{:ok, "Image generated and sent to chat"}`

**Settings:**

- `image_generation_model` — default: `google/gemini-2.5-flash-image`
- `image_generation_enabled` — boolean, default: false
- Both configurable in dashboard

**Conditional tool registration:**

In `Session.default_tools/0`, check if image generation is enabled before including the tool:

```elixir
if image_generation_enabled?(context) do
  [PiCore.Tools.GenerateImage.new(opts) | tools]
else
  tools
end
```

The setting is passed through `extra_tool_context` from the instance config.

**Dashboard UI:**

Add an "Image Generation" toggle to settings (or per-instance settings). When off, the tool doesn't appear in the LLM's tool list — it can't even try to generate images.

### API Format (verified)

**Request:**
```json
{
  "model": "google/gemini-2.5-flash-image",
  "messages": [{"role": "user", "content": "Generate an image of a cat in space"}]
}
```

**Response:** OpenRouter returns generated images in an `images` array on the message:
```json
{
  "choices": [{
    "message": {
      "role": "assistant",
      "content": "Here's a cat in space...",
      "images": [{
        "type": "image_url",
        "image_url": {
          "url": "data:image/png;base64,iVBORw0KGgo..."
        }
      }]
    }
  }]
}
```

Parse: extract `choices[0].message.images[0].image_url.url`, strip the `data:image/png;base64,` prefix, decode base64 to bytes. Save as PNG.

**Sending to Telegram:** Use `sendPhoto` (not `sendDocument`) for inline preview in chat. Add `Druzhok.Telegram.API.send_photo(token, chat_id, photo_bytes, caption)` alongside existing `send_document`.

### Testing

- Unit test: tool with mocked LLM function returning fake base64 image
- Test that tool is not registered when `image_generation_enabled` is false
- Integration test: generate a real image (requires OpenRouter API key)

---

## Spec 4: Vision Input

### Goal

When a user sends a photo in Telegram, the bot "sees" it — the image is passed to the LLM as multimodal content alongside any caption text.

### Flow

```
User sends photo (with optional caption) → Telegram
  → Bot downloads image via Telegram Bot API
  → Encodes as base64
  → Builds multimodal message: [{type: "image_url", ...}, {type: "text", ...}]
  → Session processes multimodal message
  → LLM receives and "sees" the image
```

### Components

**`PiCore.Loop.Message` — content format change**

Currently `content` is always a string. For vision, it needs to support content arrays:

```elixir
# Text message (unchanged):
%Message{role: "user", content: "Hello"}

# Multimodal message (new):
%Message{role: "user", content: [
  %{"type" => "image_url", "image_url" => %{"url" => "data:image/jpeg;base64,/9j/..."}},
  %{"type" => "text", "text" => "What's in this image?"}
]}
```

The `content` field remains untyped (any). Both string and list are valid.

**`PiCore.LLM.Anthropic` — convert_message**

Update `convert_message/1` to handle content arrays. When content is a list:
- `{"type": "text", ...}` → Anthropic `{"type": "text", "text": "..."}`
- `{"type": "image_url", ...}` → Anthropic `{"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": "..."}}`

Extract base64 data from the `data:image/jpeg;base64,...` URL format.

**`PiCore.LLM.OpenAI` — convert_messages**

OpenAI-compatible format already supports `image_url` content type natively. The message conversion just needs to pass content arrays through without stringifying them.

**`Druzhok.Agent.Telegram`**

In message handling:
1. Check if message has a photo attachment
2. If yes, select a medium-resolution photo (second-to-last in Telegram's `photo` array, or cap at ~1280px) to avoid sending multi-MB images to the LLM
3. Download image via `Druzhok.Telegram.API.fetch_file_by_id` (shared function from Spec 2)
4. Detect MIME type from file extension or default to `image/jpeg`
5. Encode as base64, build data URI: `data:{mime};base64,{data}`
6. Build content array with image + caption (or `"Пользователь отправил изображение"` if no caption)
7. Pass multimodal content to session

**`PiCore.Compaction`, `PiCore.Transform`, and `PiCore.SessionStore`**

Multimodal content with base64 images must NOT be kept in conversation history long-term:
- In `Compaction.serialize_messages/1`: if `content` is a list, convert to string — join text parts, replace image parts with `"[изображение]"`
- In `SessionStore`: same normalization before persisting to JSONL — never write multi-MB base64 to disk
- In `Transform.transform_messages/3`: when truncating old messages, treat list content the same as above

### No toggle needed

If the model supports vision (Claude, Gemini, GPT-4o), it just works. If it doesn't, the model will ignore or error on the image — that's expected and fine.

### Testing

- Unit test: Anthropic message conversion with image content
- Unit test: OpenAI message conversion with image content
- Unit test: compaction replaces image content with placeholder
- Integration test: send image to Claude, verify it describes it (requires API key)

---

## Shared Component: Telegram File Download

Both Spec 2 (voice) and Spec 4 (vision) need to download files from Telegram. New function (distinct from existing `download_file/2` which takes an already-resolved file path):

```elixir
Druzhok.Telegram.API.fetch_file_by_id(token, file_id)
# => {:ok, bytes}
# => {:error, reason}
```

Implementation (two-step wrapper):
1. `GET https://api.telegram.org/bot{token}/getFile?file_id={file_id}` → get `file_path`
2. Call existing `download_file(token, file_path)` → download bytes

This should be implemented first (as part of Spec 2) and reused by Spec 4.

---

## Implementation Order

1. **Spec 1: OpenRouter Provider** — foundation, no dependencies
2. **Spec 2: Voice Transcription** + shared Telegram file download — uses OpenRouter
3. **Spec 4: Vision Input** — reuses Telegram file download, independent of OpenRouter
4. **Spec 3: Image Generation** — uses OpenRouter, needs send_file mechanism

Specs 2, 3, 4 can be parallelized after Spec 1, but the recommended order above minimizes rework (shared file download built in Spec 2, reused in Spec 4).

---

## Models Seed Summary

| Model ID | Label | Provider | Purpose | Context Window |
|----------|-------|----------|---------|----------------|
| `google/gemini-2.0-flash-lite-001` | Gemini 2.0 Flash Lite | openrouter | Voice transcription | 1,048,576 |
| `google/gemini-2.5-flash-image` | Gemini 2.5 Flash Image | openrouter | Image generation | 1,048,576 |
| `google/gemini-2.5-flash` | Gemini 2.5 Flash | openrouter | General chat | 1,048,576 |

## Dashboard Settings Summary

| Setting | Type | Default | Spec |
|---------|------|---------|------|
| `openrouter_api_key` | string | env var | 1 |
| `openrouter_api_url` | string | `https://openrouter.ai/api/v1` | 1 |
| `transcription_enabled` | boolean | true | 2 |
| `transcription_model` | string | `google/gemini-2.0-flash-lite-001` | 2 |
| `image_generation_enabled` | boolean | false | 3 |
| `image_generation_model` | string | `google/gemini-2.5-flash-image` | 3 |
