# web_fetch Tool — Design Spec

## Summary

Add a `web_fetch` tool to PiCore that fetches a URL and returns clean plain text using Mozilla's Readability algorithm via a Rust NIF. Replaces the need for `curl | python3` chains in bash for web content extraction.

## Motivation

The bot currently fetches web content via bash tool (`curl`). This returns raw HTML — huge token cost, no useful content extraction. When the bot makes multiple tool calls in a loop (fetch → process → remind), each iteration is another LLM API request. Large payloads + rapid requests = Anthropic 429 rate limits.

A dedicated `web_fetch` tool with Readability extraction returns only readable text, dramatically reducing token usage per tool result.

## Architecture

```
LLM calls web_fetch(url)
  → Elixir: validate URL, HTTP GET via Finch
  → Elixir: check Content-Type
    → HTML: pass to Rust NIF (Readability) → plain text
    → RSS/JSON/text: return raw body as-is
  → Return text to loop (truncated by existing pipeline)
```

### Component 1: Rust NIF — `PiCore.Native.Readability`

**Location:** `v3/apps/pi_core/native/readability/`

**Crate:** `readabilityrs` (Rust port of Mozilla's Readability, v0.1.2+)

**Interface:**
```elixir
PiCore.Native.Readability.extract(html_string)
# => {:ok, %{title: "Article Title", text: "Extracted plain text...", excerpt: "Summary..."}}
# => {:error, "reason"}

PiCore.Native.Readability.strip_tags(html_string)
# => {:ok, "plain text with all HTML tags removed"}
# Used as fallback when Readability extraction fails
```

**Note on crate API:** The exact `readabilityrs` API must be verified during implementation. The crate may return an `Option<Article>` or `Result<Article, Error>` — the NIF wrapper adapts to whatever it provides. If the crate's field names differ (e.g., `text_content` instead of `text`), the NIF normalizes them to the interface above.

**Characteristics:**
- Pure function — no I/O, no network, no side effects
- Input: HTML string (UTF-8 binary)
- Output: map with title, text, excerpt (all strings)
- Safe for NIF — computation only, predictable runtime
- Also exposes `strip_tags/1` for fallback HTML→text (uses the same HTML parser, not regex)

**Dependencies (Cargo.toml):**
- `readabilityrs` — Readability extraction
- `rustler` — Erlang NIF bindings

### Component 2: Elixir Tool — `PiCore.Tools.WebFetch`

**Location:** `v3/apps/pi_core/lib/pi_core/tools/web_fetch.ex`

**Tool definition:**
- Name: `"web_fetch"`
- Description: "Fetch a URL and extract readable text content. Returns clean text from web pages (HTML→text via Readability), or raw content for RSS/JSON/plain text. Use this instead of curl for reading web content."
- Parameters:
  - `url` (string, required) — URL to fetch

**Execute flow:**

1. **Validate URL**
   - Must start with `http://` or `https://`
   - Resolve hostname via `:inet.getaddr/2` before connecting (prevents DNS rebinding)
   - Block resolved IPs: `127.0.0.0/8`, `10.0.0.0/8`, `192.168.0.0/16`, `172.16.0.0/12`, `0.0.0.0`, `169.254.0.0/16`, IPv6 loopback (`::1`), link-local (`fe80::/10`, `fc00::/7`)
   - Return `{:error, "Invalid URL"}` or `{:error, "Blocked: private/internal address"}` on failure

2. **HTTP GET via Finch**
   - Timeout: 10 seconds (receive timeout)
   - User-Agent: `"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"`
   - Default headers: `Accept-Language: ru,en;q=0.9`
   - Redirects: handle manually — on 3xx, extract `Location` header, re-issue request (max 3 hops, re-validate each resolved IP)
   - Body size: accumulate via `Finch.stream/5`, abort if body exceeds 2 MB
   - On HTTP error (4xx/5xx): return `{:error, "HTTP <status>: <url>"}`
   - Note: Finch does not natively support redirects or body size limits, both are implemented in the tool

3. **Content-Type routing**
   - Parse media type from Content-Type header (strip `;charset=...` and parameters before matching)
   - `text/html` → pass to Rust NIF, return extracted text
   - `application/xml`, `text/xml`, `application/rss+xml`, `application/atom+xml` → return raw body (RSS/Atom feeds)
   - `application/json` → return raw body
   - `text/plain` → return raw body
   - Other → return `{:error, "Unsupported content type: <type>"}`

4. **Encoding normalization** (before Readability)
   - Check Content-Type charset parameter and HTML `<meta charset>` tag
   - If not UTF-8, transcode to UTF-8 via `:unicode.characters_to_binary/2` or Erlang `:iconv` if needed
   - Most modern sites are UTF-8; this is a safety net for legacy pages

5. **Readability extraction** (HTML only)
   - Call `PiCore.Native.Readability.extract(html)`
   - Format output: `"# <title>\n\n<text>"`
   - If extraction fails or returns empty text, fall back to stripping HTML tags via the Rust NIF (use the same HTML parser already in the NIF, not regex)

6. **Return text**
   - No truncation in the tool — the loop's `truncate_output` handles size capping consistently with all other tools

**Context independence:** This tool always makes HTTP requests regardless of sandbox/workspace context. It does not dispatch based on `context[:sandbox]` like bash/read/write do.

### Component 3: Tool Registration

Add to `default_tools/0` in `session.ex`:

```elixir
PiCore.Tools.WebFetch.new(),
```

### Component 4: Schema Fix

Update `schema.ex` to honor `required: false` on tool parameters. Currently all parameters are added to the `"required"` array regardless of their `required` field. Fix: filter to only include parameters where `required != false`.

## Non-Goals

- No JavaScript rendering (Readability works on static HTML)
- No caching (keep it simple, stateless)
- No authentication/cookies
- No proxy support
- No Firecrawl fallback
- No CSS selector extraction (future enhancement if needed)

## Testing

- Unit test for Rust NIF: known HTML → expected text extraction
- Unit test for URL validation: private IPs blocked, valid URLs pass
- Unit test for content-type routing: HTML vs RSS vs JSON
- Integration test: fetch a known stable URL and verify text extraction

## Dependencies to Add

**pi_core mix.exs:**
- `{:rustler, "~> 0.36"}` — Rust NIF compilation

**Cargo.toml (native/readability/):**
- `readabilityrs = "0.1"` — Readability algorithm
- `rustler = "0.36"` — NIF bindings
