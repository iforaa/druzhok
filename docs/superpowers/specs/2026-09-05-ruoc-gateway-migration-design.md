# ruoc-gateway migration — design

Date: 2026-09-05. Status: approved design, awaiting implementation plan.

## 1. What this is

Druzhok's LLM proxy stops calling OpenRouter and OpenAI for chat, web search and
voice transcription and calls ruoc-gateway instead. Every bot gets its own
ruoc-gateway account, and all money — balance, prices, admission, metering —
moves to ruoc-gateway. Druzhok keeps a thin proxy in front of the bots that
authenticates the tenant key, translates the two request shapes hermes speaks
that ruoc-gateway does not, and records request previews for the dashboard.

Embeddings, image generation, text-to-speech and `/v1/responses` are out of
scope: they keep their current upstreams until ruoc-gateway sells those units.
Prod usage over the last 14 days was chat, search and transcription only.

Repositories: `druzhok` (this one) and `ruoc-gateway`
(`/Users/igorkuznetsov/Documents/ruoc-gateway`, Go, Postgres, deployed on the
same host at `127.0.0.1:8787`).

### Decisions

| Question | Decision |
|---|---|
| Account model | One ruoc-gateway account per bot, created by druzhok through the admin API |
| Daily USD cap | Dropped. The ruoc-gateway balance is the only limit |
| Scope | Chat, search, transcription now; other units later |
| Translation layer | Druzhok keeps a thin proxy; bots keep pointing at druzhok |
| Catalog | `GET /v1/models` on ruoc-gateway is the catalog; `ModelCatalog` goes |
| Cutover | Per bot: a ruoc key on the instance selects the new path |

## 2. ruoc-gateway changes

All additive; nothing existing changes shape.

### 2.1 `POST /admin/accounts`

Creates an account and issues one API key of kind `user` in one transaction.
Gated by `requireAdmin` like every `/admin/*` route.

Request:

```json
{ "label": "druzhok:igorhermes", "grant_rubles": "0" }
```

- `label` — required, stored on the key. Druzhok uses `druzhok:<bot name>`.
- `grant_rubles` — optional decimal string; when present and non-zero, a
  `promo` grant of that amount with no expiry is written in the same
  transaction. Parsed with `money.ParseRubles`, never a float.

Response `201`:

```json
{ "account_id": "…uuid…", "api_key": "ruoc_…" }
```

The key is returned once and never again, like every key. Funding and
suspension use the existing `POST /admin/accounts/{id}/grants` and
`POST /admin/accounts/{id}/status`. Nothing deletes an account: a deleted bot
is a suspended account, so its usage history keeps its explanation.

### 2.2 Transcribe accepts `ogg`

Telegram voice notes are ogg/opus. The Gemini route accepts them through
OpenRouter's `input_audio` part with `format: "ogg"` — druzhok sends exactly
that in production today. The allowlist becomes `wav`, `mp3`, `ogg`.

`estimatedSeconds` gets a bytes-per-second figure for ogg of 6 KiB/s (Telegram
records at 48 kbps; the figure sits above that so the estimate stays generous,
matching the rule the other two formats follow).

`docs/voice-transcription-client-contract.md` is updated to list `ogg`.

### 2.3 Prices on `GET /v1/models`

Each `modelPayload` gains:

```json
"price": { "input_rub_per_million": "12", "output_rub_per_million": "38" }
```

Decimal strings from the open `input_tokens` and `output_tokens` rates,
rendered per million as `ruocd model list` renders them. A model missing a rate
gets `null` for that side rather than `"0"`. The desktop app ignores fields it
does not know.

### 2.4 Tests

Go tests against the test database: account creation with and without a
grant, label stored on the key, key authenticates, admin token required;
`ogg` accepted and `webm` still refused; price fields present and correct
after a reprice.

## 3. Druzhok data model and configuration

### 3.1 Instance

Two nullable string columns: `ruoc_account_id`, `ruoc_api_key`. Presence of
`ruoc_api_key` is the switch: set means the ruoc path, nil means the legacy
OpenRouter path. `daily_budget_cents` and the `budgets` table stay until the
legacy path is deleted (section 7), then one migration drops both.

### 3.2 Settings

Three new keys in `Druzhok.Settings`, read at call time like
`openrouter_api_key`:

| key | default | meaning |
|---|---|---|
| `ruoc_url` | `http://127.0.0.1:8787` | base for `/v1/*` and `/admin/*` |
| `ruoc_admin_host` | (none) | value of the `Host` header on admin calls; ruoc-gateway serves the admin surface only on its admin hostname |
| `ruoc_admin_token` | (none) | bearer for `/admin/*` |
| `ruoc_catalog_key` | (none) | a bot-style key used only to read `/v1/models`; minted once with `POST /admin/accounts` and label `druzhok:catalog`, never funded |

The app env `:ruoc_url` (from `RUOC_URL`) overrides the setting so tests can
point it at Bypass, the same pattern `:openrouter_api_url` uses.

### 3.3 `Druzhok.Ruoc`

The one module that knows ruoc-gateway URLs and shapes.

```elixir
Druzhok.Ruoc.create_account(label)      # {:ok, %{account_id, api_key}} | {:error, term}
Druzhok.Ruoc.suspend(account_id)        # :ok | {:error, term}
Druzhok.Ruoc.balance(api_key)           # {:ok, %{balance_rub: "12.34"}} | {:error, term}
Druzhok.Ruoc.models()                   # [%{id, name, price: %{input, output}, capabilities}]
Druzhok.Ruoc.default_model()            # "ruoc-flash"
Druzhok.Ruoc.vision_models()            # models whose capabilities.attachment is true
```

`models/0` caches for 60 s in `:persistent_term` keyed on fetch time; on
upstream failure it returns the last good list, or `[]` on cold start, and
logs a warning. It authenticates with `ruoc_catalog_key`; `/v1/models` needs
a valid bearer and the admin token is not one. With the setting unset it
returns `[]` and logs an error, so the picker is empty rather than wrong.

`Druzhok.Ruoc.Client` does the HTTP: `post(path, api_key, body, opts)` and
`get(path, api_key)` over `Druzhok.Finch` with a 120 s receive timeout,
returning `{:ok, status, headers, body}` or `{:error, reason}`. Streaming uses
`Finch.stream/5` from the controller as the OpenRouter path does today.

## 4. The proxy

`LlmAuth` is unchanged: tenant key → instance in `conn.assigns`.

Each of `chat_completions`, `firecrawl_search` and `audio_transcriptions`
starts with:

```elixir
if instance.ruoc_api_key, do: ruoc_path(...), else: legacy_path(...)
```

The legacy functions are the existing code, byte for byte, so the 82 proxy
tests keep passing untouched. `embeddings`, `images_generations`,
`audio_speech` and `responses_proxy` do not look at the flag; they keep their
upstreams and their `Budget.check`.

The ruoc path never calls `Budget`. A 402 from ruoc-gateway is the budget.

Every ruoc-path response copies `X-Ruoc-Request-Id` from the gateway to the
bot's response and logs it at info with the bot name, so a disputed charge is
traceable in the ruoc console.

### 4.1 Chat

- Body forwarded to `POST /v1/chat/completions` with `Authorization: Bearer
  <ruoc_api_key>`. `model` is passed as stored on the instance (a ruoc id).
- Image stripping stays, driven by `Druzhok.Ruoc.vision_models/0` instead of
  the hardcoded list: image parts are removed when the requested model lacks
  `attachment`.
- The mimo fake-stream branch and the reasoning override are not carried over;
  neither model is in the ruoc catalog. `LlmFormat.prepare_body/1` splits
  into the legacy version and a ruoc version that only strips images.
- Streaming relays bytes unchanged. Usage is read from the final SSE chunk,
  which ruoc-gateway guarantees by forcing `stream_options.include_usage`.
- Non-2xx from ruoc-gateway is relayed unchanged: status, body and
  `content-type`. Hermes understands the OpenAI error envelope and shows the
  message, so a 402 reads as "account balance is too low".
- `Usage.log` writes tokens, latency, previews and request body with
  `provider: "ruoc"` and `cost_cents: 0`.

### 4.2 Search

Hermes posts Firecrawl's shape to `POST /v2/search`:
`{"query": "...", "limit": 5}`.

- Map to ruoc `POST /v1/search` with `{"query": query, "max_results":
  min(limit, 10)}`. Empty query is a 400 before any upstream call, as today.
- Map each result to `{"title", "url", "description": content, "position":
  n}` and reply `{"success": true, "data": {"web": [...]}}`.
- ruoc errors become `{"success": false, "error": <ruoc message>}` with the
  same status. Network failure is 502 `search provider unavailable`.
- `Usage.log` writes `request_type: "search"`, tokens 0, the query as
  `prompt_preview`, the titles joined as `response_preview`.
- `POST /v2/scrape` keeps returning 404 so hermes falls back to its browser.

### 4.3 Transcription

Hermes posts multipart to `POST /v1/audio/transcriptions` with `file` and
optional `response_format`.

- Format from the filename extension: `ogg`/`oga`/`opus` → `ogg`,
  `mp3`/`mpga`/`mpeg` → `mp3`, `wav` → `wav`. Anything else is a 400
  `unsupported audio format` before any upstream call. (The legacy path's
  wider list stays on the legacy path.)
- Read the upload, base64-encode, post `{"audio", "format"}` to ruoc
  `POST /v1/transcribe`.
- Reply `{"text": ...}` as JSON, or the bare text when `response_format` is
  `text`, exactly as the legacy path does.
- ruoc errors are relayed with their status and envelope; 413 and 402 reach
  hermes with ruoc's message. Network failure is 502.
- `Usage.log` writes `request_type: "audio"`, tokens 0, and the transcript
  as `response_preview`.

## 5. Dashboard, manager bot, catalog

### 5.1 Money display

For a migrated bot the settings tab and the manager bot's «Мои боты» show
balance in rubles from `Druzhok.Ruoc.balance/1` and a link to
`https://<admin host>/#/requests/<ruoc_account_id>` (the console's per-account requests view). The daily budget input
and «spent today» line are hidden for migrated bots and stay for the rest
until section 7 removes them. Balance fetch failure renders «—», never an
error page.

### 5.2 Catalog

`ModelCatalog` is deleted. Every caller switches:

| caller | before | after |
|---|---|---|
| dashboard create form, settings picker | `ModelCatalog.all/0` | `Druzhok.Ruoc.models/0`, price string beside the name |
| provisioner, onboarding default | `ModelCatalog.default_model/0` | `Druzhok.Ruoc.default_model/0` (`ruoc-flash`) |
| vision model picker | `ModelCatalog.image_models/0` | `Druzhok.Ruoc.vision_models/0` |
| image-gen picker | `ModelCatalog.image_gen_models/0` | a small `@image_gen_models` list kept inside `LlmProxyController` until ruoc sells images |
| `LlmFormat.extract_cost_cents` fallback prices | `ModelCatalog.price_per_million/1` | legacy path only; moved into `LlmFormat` as a private map, deleted with the legacy path |

`Runtime.Hermes` writes the instance's `model` into config.yaml as it does
now; a ruoc id like `ruoc-flash` is just a string to hermes.

### 5.3 Migration per bot

```elixir
BotManager.migrate_to_ruoc(name)
# {:ok, %{account_id, model}} | {:already_migrated, name} | {:error, term}
```

1. Skip if `ruoc_api_key` is set.
2. `Druzhok.Ruoc.create_account("druzhok:" <> name)`.
3. Remap `model` and `image_model` through a fixed table
   (`z-ai/glm-5.3-flash` → `ruoc-flash`, `z-ai/glm-5.3` → `ruoc-standard`,
   everything else → `ruoc-flash`; `image_model` → the first vision model or
   nil).
4. Update the row, then `BotManager.restart/1` so config.yaml is re-synced.

Exposed as a «Migrate to ruoc» button on the settings tab (admin only) and a
`mix druzhok.migrate_ruoc <name>` task for the server. Funding is done in the
ruoc console; the button's success message says so and shows the account link.

`BotManager.delete/1` calls `Druzhok.Ruoc.suspend/1` before wiping, when the
instance has an account id. A suspend failure is logged and does not block the
delete.

New bots created after cutover are migrated as part of `BotManager.create/2`:
account created, key stored, model defaulted to `ruoc-flash`. If account
creation fails, create fails and no row is left behind.

## 6. Rollout

1. ruoc-gateway: implement section 2, test, `deploy/deploy.sh`.
2. druzhok: implement sections 3–5, deploy with both paths live. Set the
   three ruoc settings on prod.
3. `mix druzhok.migrate_ruoc igorhermes`, grant it credit in the ruoc console,
   then from Telegram: a text message, a voice note, a question that triggers
   web search. Check the ruoc console shows three usage rows and the druzhok
   dashboard shows the requests with previews.
4. Migrate the remaining bots one at a time, funding each.
5. Section 7.

Rollback for one bot is clearing `ruoc_api_key` and restarting it; the legacy
path is still there until step 5.

## 7. Removing the legacy path

One commit after every active bot is migrated:

- Delete the OpenRouter chat, search and transcription functions, the mimo
  fake-stream, the reasoning override, the legacy `prepare_body`, and their
  tests.
- Delete `Druzhok.Budget`, the `budgets` table, `daily_budget_cents`, and the
  budget UI in the settings tab and onboarding.
- `embeddings`, `images_generations`, `audio_speech`, `responses_proxy` lose
  their `Budget.check` and run unmetered for money until they move to ruoc.
- `ruoc_api_key` becomes required on the instance; `LlmAuth` returns 503
  `bot not migrated` for a row without one.
- Update `CLAUDE.md` proxy table: upstream is ruoc-gateway for the three
  routes.

## 8. Testing

**ruoc-gateway** — section 2.4.

**druzhok**

- `DruzhokWebWeb.RuocStub` on Bypass beside `UpstreamStub`: canned
  `/v1/chat/completions` (sync and SSE), `/v1/search`, `/v1/transcribe`,
  `/v1/models`, `/v1/balance`, `/admin/accounts`, `/admin/accounts/:id/status`,
  each recording the request it received.
- `ProxyCase` gains `migrated_instance/1` that sets a ruoc key and points
  `:ruoc_url` at the stub.
- New test files under `controllers/llm_proxy/ruoc/`: chat sync, chat stream,
  search, transcription. Each asserts the upstream request body (bearer is the
  bot's ruoc key, model passed through, `max_results` clamped, format derived,
  audio base64 round-trips), the client response shape, error relay for 402,
  413, 429 and 502, `X-Ruoc-Request-Id` passthrough, and the `usage_logs` row.
- The existing 82 legacy tests are unchanged and keep running until section 7
  deletes the ones for chat, search and STT.
- `Druzhok.RuocTest`: create_account success and failure, models cache and
  stale fallback, vision_models filter.
- `BotManagerLifecycleTest`: migrate_to_ruoc creates the account and remaps the
  model, is idempotent, delete suspends; create after cutover provisions an
  account and rolls back on failure.
- `DashboardLive`/settings tab: model picker renders ruoc models with prices;
  migrated bot shows balance, unmigrated shows budget.

Coverage thresholds stay at 65 / 35 and are raised when the suite grows.

## 9. Decisions recorded

- **Why druzhok still proxies.** Hermes speaks OpenAI multipart for audio
  and Firecrawl JSON for search. Putting those dialects into ruoc-gateway would
  make it carry hermes-specific shapes for one customer; druzhok already
  carries them and their tests.
- **Why no per-bot daily cap.** The cap existed because OpenRouter was one
  shared account. With a ledger per bot the balance is the cap, and a runaway
  bot can only spend what its account holds.
- **Why suspend, not delete.** `usage_records` has no foreign key to
  accounts' children; suspension keeps history readable.
- **Why ruoc ids on the instance.** The catalog is ruoc's; storing OpenRouter
  ids would need a mapping in every request and a second source of truth.
- **Why the per-bot switch.** Same operator-bot-first rollout the Hermes
  updates use, and rollback for one bot is a column edit.
