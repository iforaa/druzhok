# Web fetch service

Date: 2026-09-05. Status: **designed**. Depends on ruoc-gateway
`docs/superpowers/specs/2026-09-05-page-fetch-design.md`.

Hermes's `web_extract` tool posts `/v2/scrape` to druzhok and gets a 404, so
bots read pages by running `curl` in their own environment, unmetered, from
a box that lets bot users reach any host on 80/443. This spec gives druzhok a
page fetcher, routes every read through ruoc-gateway so it is a priced unit,
and closes the side door: bot users may only reach druzhok, DNS and Telegram.

Three pieces, in dependency order:

1. **Fetcher** (`Druzhok.Fetch`): fetch a URL safely, turn HTML or PDF into
   markdown through a Python worker.
2. **Endpoints**: `POST /internal/fetch` (ruoc calls it), `POST /v2/scrape`
   (hermes calls it, druzhok forwards to ruoc `/v1/fetch`).
3. **Egress lockdown** (`ops/nftables-druzhok.nft`).

## Data flow

```
hermes web_extract ──► druzhok POST /v2/scrape        (tenant key)
                          │
                          ▼
                       ruoc POST /v1/fetch            (bot's ruoc key; rate, balance, ledger)
                          │
                          ▼
                       druzhok POST /internal/fetch   (FETCH_SECRET; network + safety)
                          │
                          ▼
                       Druzhok.Fetch ─► Mint GET ─► Fetch.Worker (Python) ─► markdown
```

Druzhok appears twice on purpose: the tenant side knows the bot and pays,
the internal side knows the network and owes nothing to anyone but ruoc.

## Fetcher: `Druzhok.Fetch`

`Druzhok.Fetch.fetch(url, opts) :: {:ok, page} | {:error, code, meta}`

```elixir
page = %{final_url: String.t(), title: String.t(), markdown: String.t(),
         status_code: integer, bytes: integer}
code = :bad_url | :unsafe_url | :unsupported_type | :too_large | :timeout
     | :unreachable | :no_text
```

### Policy (`Druzhok.Fetch.Policy`, pure)

`check(url, resolver) :: {:ok, %{scheme, host, port, ip, path}} | {:error, :bad_url | :unsafe_url}`.

- Scheme `http` or `https`, host present, no userinfo, port 80/443 or
  explicit 1024–65535. Anything else `:bad_url`.
- Host that is an IP literal or resolves (A then AAAA, first answer) to any of:
  `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`,
  `169.254.0.0/16`, `100.64.0.0/10`, `0.0.0.0/8`, `224.0.0.0/4`,
  `240.0.0.0/4`, `::1`, `::`, `fc00::/7`, `fe80::/10`, `ff00::/8`,
  `::ffff:0:0/96` mapped forms of the above → `:unsafe_url`. Hosts `localhost`
  and anything ending `.local`, `.internal`, `.localhost` → `:unsafe_url`
  without resolving.
- Resolver is `(host -> {:ok, ip} | :error)`; production uses
  `:inet.getaddr/2`, tests pass a map. Resolution failure → `:unreachable`.

The checked IP is the one connected to. Redirects go through `check/2` again
per hop, at most 5 hops, then `:unreachable`.

### Transport (`Druzhok.Fetch.HTTP`, Mint)

Mint rather than Finch because the connection must go to the checked IP while
Host and SNI carry the original name (`Mint.HTTP.connect(scheme, ip, port,
hostname: host)`), and because the body must be capped while streaming.

- Connect timeout 10 s, total budget 30 s from the first connect (redirects
  included), enforced by a deadline passed down.
- Request headers: `User-Agent: Mozilla/5.0 (compatible; Druzhok/1.0)`,
  `Accept: text/html,application/xhtml+xml,application/pdf,text/plain;q=0.8,*/*;q=0.1`,
  `Accept-Language: ru,en;q=0.8`, `Accept-Encoding: identity`.
- Response: `Content-Type` must start with `text/html`,
  `application/xhtml+xml`, `text/plain` or `application/pdf`, else
  `:unsupported_type` (the body is not read). Body read up to 5 MiB, one byte
  more → `:too_large`. Non-2xx after redirects → `{:error, :no_text,
  %{status_code: n}}` without extraction.
- Errors: connect/TLS/read failures `:unreachable`, deadline `:timeout`.

### Worker (`Druzhok.Fetch.Worker`, GenServer + Port)

One long-lived Python process, `apps/druzhok/priv/fetch-worker/worker.py`
(next to its `requirements.txt`), started with `{:spawn_executable, bin}`
where `bin` is `FETCH_WORKER_BIN` / `config :druzhok, :fetch_worker_bin`
(prod `/opt/druzhok-fetch/.venv/bin/python`), args `[worker.py]` resolved
through `Application.app_dir(:druzhok, "priv/fetch-worker")`. Port options
`[:binary, {:packet, 4}, :exit_status]`; each message is a JSON object.

Request `{"kind": "html"|"pdf"|"text", "url": ..., "body_b64": ...}`;
reply `{"title": ..., "markdown": ...}` or `{"error": "extract_failed"}`.

- `html`: `trafilatura.bare_extraction(html, url=url, output_format="markdown",
  include_links=True, include_tables=True, include_comments=False,
  favor_recall=True)` → `text` and `title` (fallback `<title>`).
- `pdf`: `pymupdf` text per page joined with `\n\n---\n\n`, title from the
  document metadata or the URL's last path segment.
- `text`: body as-is, title = URL.
- Output truncated to 200 000 characters before returning.

`Worker.extract(kind, url, body) :: {:ok, %{title, markdown}} | {:error, :extract_failed | :worker_down}`
with a 20 s call timeout; calls are serialized by the GenServer, which is
enough for the expected load and keeps one Python process. The supervisor
restarts it on exit; a reply with `"error"` or a crash mid-request is
`:extract_failed` for that request only. Markdown shorter than 60 characters
after trimming → `:no_text`.

`requirements.txt`: `trafilatura==2.0.0`, `pymupdf==1.25.5`. The venv is
created by a new `ops/bootstrap.sh` step (`python3 -m venv
/opt/druzhok-fetch/.venv && pip install -r`) and documented in CLAUDE.md;
locally `python3 -m venv .fetch-venv` at the repo root, gitignored. When the
binary is missing the worker logs once and every extract is
`{:error, :worker_down}`, which the endpoint reports as 502.

## Endpoints

### `POST /internal/fetch`

New router pipeline `:internal_api` with plug `DruzhokWebWeb.Plugs.FetchAuth`:
constant-time compare of `Authorization: Bearer <token>` against Settings
`fetch_secret` (env `FETCH_SECRET` as fallback, same precedence as the ruoc
settings); missing setting or mismatch → 401. Settings page gets the field.

Controller `FetchController.fetch/2`: body `{"url"}`; result mapping:

| fetch result | status | body |
|---|---|---|
| `{:ok, page}` | 200 | `{final_url, title, markdown, status_code, bytes}` |
| `:bad_url`, `:unsafe_url`, `:unsupported_type` | 400 | `{error: code}` |
| `:no_text` | 422 | `{error: "no_text", status_code}` |
| `:timeout` | 504 | `{error: "timeout"}` |
| `:unreachable`, `:too_large`, `:worker_down`, `:extract_failed` | 502 | `{error: code}` |

One log line per call: `[fetch] host status latency bytes`. No usage row here;
the tenant side records it.

### `POST /v2/scrape`

Under the existing `:llm_api` pipeline next to `/v2/search`.
`LlmProxyController.firecrawl_scrape/2` validates `url` (string, non-empty,
else 400 `{success: false, error}`), ignores `formats`, and calls
`LlmProxy.Ruoc.fetch(conn, instance, url)`:

- ruoc 200 → 200

```json
{"success": true,
 "data": {"markdown": "...",
          "metadata": {"title": "...", "sourceURL": "<final_url>",
                       "statusCode": 200, "url": "<requested>"}}}
```

  and a usage row: `request_type: "fetch"`, model `ruoc-fetch`, tokens 0,
  cost 0, `prompt_preview` = URL (500 chars), `response_preview` = title,
  latency; log line with ruoc's request id like search.
- ruoc 402 → 402 `{success: false, error: BalanceNotice.text(instance)}`.
- ruoc 400/422/429/502/503 → same status, `{success: false, error:
  <ruoc message>}`; the SDK raises and hermes records a per-URL error, which
  is what its prompt expects ("if a URL fails, ...").
- transport error → 502 `{success: false, error: "fetch provider unavailable"}`.

`Client.post` timeout for this call: 50 s (ruoc's 45 s plus slack).

Runtime.Hermes needs no change: `FIRECRAWL_API_URL` already points at druzhok
and the plugin already posts `/v2/scrape`. The dashboard usage table gets
`fetch` in its request-type filter.

## Egress lockdown

`ops/nftables-druzhok.nft` replaces the open web rule:

```
table inet druzhok {
  set bot_uids { type uid; }
  set telegram4 { type ipv4_addr; flags interval;
    elements = { 149.154.160.0/20, 91.108.4.0/22, 91.108.8.0/22, 91.108.12.0/22,
                 91.108.16.0/22, 91.108.20.0/22, 91.108.56.0/22, 185.76.151.0/24 } }
  set telegram6 { type ipv6_addr; flags interval;
    elements = { 2001:b28:f23d::/48, 2001:b28:f23f::/48, 2001:67c:4e8::/48, 2a0a:f280::/32 } }

  chain output {
    type filter hook output priority 0; policy accept;
    meta skuid != @bot_uids accept
    ip daddr 127.0.0.1 tcp dport 4000 accept
    udp dport 53 accept
    tcp dport 53 accept
    ip daddr @telegram4 tcp dport 443 meter bot_tg { meta skuid counter } accept
    ip6 daddr @telegram6 tcp dport 443 meter bot_tg6 { meta skuid counter } accept
    counter drop
  }
}
```

Bot users keep Telegram (long polling and file downloads both go to
`api.telegram.org` in those ranges), DNS and the proxy. The druzhok user is
not in `bot_uids`, so the fetcher and ruoc keep full egress. Hermes's
models.dev refresh fails closed onto its disk cache or an empty registry,
which it handles. Applied with `nft delete table inet druzhok; nft -f` as
bootstrap does today; `druzhok-ctl` is unchanged.

## Tests

- `Druzhok.Fetch.PolicyTest`: every range above, IP literals, mapped IPv6,
  `localhost`, `.internal`, userinfo, `ftp:`, ports, resolver map.
- `Druzhok.Fetch.HTTPTest` (Bypass, `policy: :allow_all`): 200 HTML, redirect
  chain of 5 then 6, redirect into a blocked address (resolver map + real
  policy), `Content-Type` rejection before the body, 5 MiB + 1 byte, 404,
  slow body past the deadline.
- `Druzhok.Fetch.WorkerTest`: fixture article HTML → markdown with title and
  no nav text; fixture PDF; junk → `:extract_failed`; worker killed mid-call →
  `:extract_failed` then next call works. Skipped with a message when the venv
  is absent (`@moduletag :fetch_worker`, excluded unless
  `FETCH_WORKER_BIN` resolves).
- `FetchControllerTest`: secret check, every row of the mapping with
  `Druzhok.Fetch` stubbed via `config :druzhok, :fetch_impl`.
- `LlmProxy.Ruoc.FetchTest` (`RuocStub` gains `POST /v1/fetch`): 200 shape and
  usage row, 402 notice, 422 relay, transport error.
- `ops/smoke.sh` gains one `/v2/scrape` call against `https://example.com`.

## Deploy

1. ruoc-gateway first (its spec), `FETCH_SECRET` set there.
2. Server: `sudo bash -c 'python3 -m venv /opt/druzhok-fetch/.venv &&
   /opt/druzhok-fetch/.venv/bin/pip install -r ~/druzhok/apps/druzhok/priv/fetch-worker/requirements.txt'`,
   `FETCH_WORKER_BIN` in `/etc/druzhok/druzhok.env`.
3. rsync, compile, migrate, `fetch_secret` in Settings, restart druzhok,
   `ops/smoke.sh <operator bot>`.
4. `ruocd fetch setup -rub 0 -usd 0`; `curl /v2/scrape` with the operator
   bot's key; ask the operator's bot to read a page.
5. `sudo install ops/nftables-druzhok.nft /etc/nftables.d/druzhok.nft && sudo nft
   delete table inet druzhok && sudo nft -f /etc/nftables.d/druzhok.nft`; then
   re-add the uids (`druzhok-ctl` does it on create only, so a one-off loop
   over `getent passwd | grep ^bot-`). Watch `nft list table inet druzhok`
   drop counters and the operator bot for an hour.

## Out of scope

JavaScript rendering, screenshots, crawling, caching of fetched pages,
per-tenant allow/deny lists (hermes has its own `website_policy`), and moving
TTS or `/v1/responses` off OpenRouter.
