# Smart web_fetch with Preview Mode

**Date:** 2026-03-26
**Status:** Approved

## Problem

`web_fetch` returns full content (up to 8K bytes after truncation cap). For RSS feeds, large HTML pages, and JSON responses, this dumps thousands of tokens of raw content into the LLM context when the bot often only needs a few facts or headlines. The bot should see a preview and decide whether to write a targeted extraction script.

## Design

### Behavior Change

After content processing (readability for HTML, passthrough for RSS/JSON/text), check the result size:

- **≤ 2000 bytes**: Return as-is (full content). Covers most API responses, short pages, clean readability extracts.
- **> 2000 bytes**: Return first 2000 chars as preview + a metadata footer with total size and content type.

### Preview Footer Format

```
---
[Content truncated: 63,189 bytes total, type: application/rss+xml]
```

No command suggestions — the model knows how to write bash/python extraction from AGENTS.md instructions and the preview gives enough context to understand the content structure.

### Implementation

Single change in `web_fetch.ex` — add a `maybe_preview` step after `process_body`:

```elixir
@preview_max_bytes 2000

defp maybe_preview(content, media_type) do
  if byte_size(content) > @preview_max_bytes do
    preview = String.slice(content, 0, @preview_max_bytes)
    preview <> "\n---\n[Content truncated: #{byte_size(content)} bytes total, type: #{media_type}]"
  else
    content
  end
end
```

Called in `execute/2` after `process_body`:
```elixir
case process_body(body, media_type) do
  {:ok, content} -> {:ok, maybe_preview(content, media_type)}
  error -> error
end
```

### What Doesn't Change

- Readability extraction for HTML
- Passthrough for RSS/JSON/text
- Error handling, SSRF checks, redirects, encoding
- The `direct: true` path (same truncation applies)

## File to Modify

| File | Change |
|------|--------|
| `pi_core/lib/pi_core/tools/web_fetch.ex` | Add `maybe_preview/2`, wrap `process_body` results |
