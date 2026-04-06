# Configurable Image, Audio & Embedding Models Per Instance

## Problem

Image model (`google/gemini-2.5-flash-lite`), audio model (`gpt-4o-mini-transcribe`), and embedding model (`openai/text-embedding-3-small`) are hardcoded in PoolConfig and LlmProxyController. Changing them requires a code change and redeploy.

## Solution

Add `image_model`, `audio_model`, and `embedding_model` fields to the Instance (bot) schema. Read these in PoolConfig and LlmProxyController instead of hardcoded values. Expose dropdowns in the dashboard.

## Architecture

### Database Migration

Add 3 nullable string columns to `instances`:

| Column | Type | Default (in code) |
|--------|------|-------------------|
| `image_model` | `:string` | `google/gemini-2.5-flash-lite` |
| `audio_model` | `:string` | `gpt-4o-mini-transcribe` |
| `embedding_model` | `:string` | `openai/text-embedding-3-small` |

Columns are nullable. Defaults applied in code via `instance.image_model || @default_image_model`.

### Instance Schema

File: `v4/druzhok/apps/druzhok/lib/druzhok/instance.ex`

- Add 3 fields to schema
- Add to changeset cast list

### PoolConfig Changes

File: `v4/druzhok/apps/druzhok/lib/druzhok/pool_config.ex`

All three models are pool-level config (one OpenClaw container = one config). Use first instance's values (same pattern as `first_tenant_key`):

- **Line 50** (embedding): `first_instance.embedding_model || "openai/text-embedding-3-small"`
- **Line 84** (audio): `first_instance.audio_model || "gpt-4o-mini-transcribe"`
- **Line 91** (image): `first_instance.image_model || "google/gemini-2.5-flash-lite"`

### LlmProxyController Changes

File: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex`

The `/v1/responses` endpoint currently uses `@image_model` module attribute. Change:

1. Extract `Authorization: Bearer <token>` from request headers (already sent by PoolConfig image auth config)
2. Look up instance by `tenant_key`
3. Use `instance.image_model || "google/gemini-2.5-flash-lite"`
4. Pass model to `convert_responses_to_chat/2` instead of using module attribute

Remove the `@image_model` module attribute.

### ModelCatalog Additions

File: `v4/druzhok/apps/druzhok/lib/druzhok/model_catalog.ex`

Add 3 new functions returning curated lists:

```elixir
def image_models do
  [
    %{id: "google/gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite"},
    %{id: "google/gemini-3-flash-preview", name: "Gemini 3 Flash"},
    %{id: "openai/gpt-5.4-mini", name: "GPT-5.4 Mini"}
  ]
end

def audio_models do
  # Note: audio model IDs have no provider prefix (e.g. "gpt-4o-mini-transcribe" not "openai/gpt-4o-mini-transcribe")
  # because OpenClaw sends them to the OpenAI-compatible transcription API directly
  [
    %{id: "gpt-4o-mini-transcribe", name: "GPT-4o Mini Transcribe"}
  ]
end

def embedding_models do
  [
    %{id: "openai/text-embedding-3-small", name: "Text Embedding 3 Small"}
  ]
end
```

Lists can be extended later as new models become available.

### Dashboard UI

File: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

In the instance settings tab (around line 960), inside the existing `phx-change="update_models"` form, add 3 dropdowns after the existing Default/Smart model selectors:

- **Image Model** — populated from `ModelCatalog.image_models()`
- **Audio Model** — populated from `ModelCatalog.audio_models()`
- **Embedding Model** — populated from `ModelCatalog.embedding_models()`

Update the `handle_event("update_models", ...)` handler to persist the 3 new fields.

## Data Flow

```
Dashboard dropdown → Instance DB field → PoolConfig.build() → OpenClaw JSON config
                                        → LlmProxyController (image model via tenant lookup)
```

## Testing

1. **Unit**: `mix test` — existing tests pass, migration runs clean
2. **Integration**: Start a pool, inspect generated OpenClaw config JSON — verify image/audio/embedding models match instance values
3. **E2E via Docker**: Deploy, send image to bot (vision), send voice message (transcription), trigger memory search (embeddings) — all work with configured models
