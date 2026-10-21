# Usage Tracking for All Proxy Endpoints

## Problem

Only `/v1/chat/completions` tracks token usage, deducts budget, and enforces limits. Three other endpoints — image understanding (`/v1/responses`), audio transcription (`/v1/audio/transcriptions`), and embeddings (`/v1/embeddings`) — have no usage tracking, no budget enforcement, and no dashboard visibility.

## Solution

Extend the existing `usage_logs` table and `meter()` function to cover all four endpoint types. Add tenant auth to audio requests (matching image pattern). Enforce budget on image and audio; track-only for embeddings.

## Database Changes

Add 2 columns to `usage_logs`:

| Column | Type | Default | Purpose |
|--------|------|---------|---------|
| `request_type` | `:string` | `"chat"` | One of: `chat`, `image`, `audio`, `embedding` |
| `audio_duration_ms` | `:integer` | `nil` | Audio length in milliseconds (audio requests only) |

Existing rows default to `request_type = "chat"`. No data migration needed.

## PoolConfig: Add Auth to Audio

Currently only the image config sends a tenant key. Add the same `request.auth` block to audio config so the proxy can identify the instance:

```json
"audio": {
  "enabled": true,
  "echoTranscript": true,
  "models": [{"provider": "openai", "model": "gpt-4o-mini-transcribe", "baseUrl": "..."}],
  "request": {
    "auth": {"mode": "authorization-bearer", "token": "<first_tenant_key>"}
  }
}
```

This matches the existing image auth pattern in PoolConfig.

## Metering Per Endpoint

### `/v1/chat/completions` (existing, no changes)
- Already meters tokens via `meter()`
- Already enforces budget via `Budget.check()`
- Add `request_type: "chat"` to the usage log

### `/v1/responses` (image)
- `resolve_image_model(conn)` already looks up the instance by tenant key
- After streaming completes, extract token usage from OpenRouter SSE response
- Call `meter()` with `request_type: "image"`
- Add `Budget.check()` before proxying — return 429 if exceeded

### `/v1/audio/transcriptions` (audio)
- Extract tenant key from `Authorization: Bearer` header (new, after PoolConfig change)
- Look up instance by `tenant_key`
- Extract audio duration from the Whisper API response (it returns `duration` in the JSON response body)
- After Whisper responds, log with `request_type: "audio"` and `audio_duration_ms`
- Budget deduction: convert duration to token-equivalent using a configurable rate stored in Settings (`audio_tokens_per_second`, e.g. 10)
- Add `Budget.check()` before proxying — return 429 if exceeded

### `/v1/embeddings` (track only)
- Already goes through `llm_api` pipeline — `conn.assigns.instance` available
- After response, extract token usage from JSON body
- Call `meter()` with `request_type: "embedding"`
- **No budget enforcement** — blocking embeddings silently breaks memory search

## Budget Enforcement Summary

| Endpoint | Track | Enforce Budget |
|----------|-------|----------------|
| Chat completions | Yes (existing) | Yes (existing) |
| Image/responses | Yes (new) | Yes (new) |
| Audio transcription | Yes (new) | Yes (new) |
| Embeddings | Yes (new) | No — track only |

## Audio Duration → Token Equivalence

Audio costs are duration-based, not token-based. To use the same budget system:
- Store `audio_tokens_per_second` in Settings table (configurable via dashboard)
- Default: 10 tokens/second (adjustable based on actual Whisper pricing)
- Budget deduction: `duration_seconds * audio_tokens_per_second`
- The `usage_logs` row stores both `audio_duration_ms` (actual) and `total_tokens` (equivalent for budget)

## Dashboard Changes

In the existing Usage tab:

- **Request type filter**: Add pill buttons (All | Chat | Image | Audio | Embedding) above the summary cards
- **Summary cards**: Group by request type. Audio cards show duration ("47s across 3 calls") instead of token counts
- **Request log**: Add a "Type" column. Audio rows show duration in the Input column instead of token count
- **No new pages** — everything stays in the existing Usage tab

## Instance Schema

Add `audio_tokens_per_second` to Settings (global, not per-instance) with a default of 10. Exposed in the Settings dashboard page.

## Files Changed

- Migration: add `request_type` and `audio_duration_ms` to `usage_logs`
- `Usage` schema: add fields
- `PoolConfig`: add `request.auth` to audio config
- `LlmProxyController`: add metering to `responses_proxy`, `audio_transcriptions`, `embeddings`
- `Budget`: add check to `responses_proxy` and `audio_transcriptions`
- `UsageTab` component: add type filter, audio duration display
- `DashboardLive`: handle type filter event, pass filtered data
- `SettingsLive`: add `audio_tokens_per_second` setting
