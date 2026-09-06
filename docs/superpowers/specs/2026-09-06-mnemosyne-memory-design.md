# Mnemosyne memory for hermes bots — design

Date: 2026-09-06. Status: approved in chat, pending spec review.

## 1. Goal

Give each hermes bot long-term episodic memory that works in Russian, at near-zero
marginal cost, with the embedding traffic metered through ruoc-gateway so it can be
priced later. Nothing changes for a bot until its `memory_provider` is flipped.

## 2. Decisions and why

| Decision | Choice | Why |
|---|---|---|
| Memory engine | Mnemosyne (`mnemosyne-memory` + `mnemosyne-hermes`), in-process in each bot | Hermes's own memory-provider plugin API; SQLite in the tenant dir, so isolation and backup come with the tenant dir. No LLM per turn. Runs alongside builtin MEMORY.md/USER.md memory (hermes loads one external provider next to builtin). |
| Embedding model | `intfloat/multilingual-e5-small`, 384 dims | Eval on a 120-memory Russian corpus with 84 colloquial queries: R@1 0.80, R@5 0.95, MRR 0.87, 12 ms/query on 2 threads. bge-m3 scored R@1 0.88 / R@5 0.96 at 8× the latency and 2× the RAM; Mnemosyne's default bge-small-en scored R@5 0.36 on Russian. Top-5 is what the bot receives, so the small model wins. |
| Where the model runs | One druzhok-side ONNX worker, reached through ruoc | Same shape as `/v1/fetch`: bot → druzhok proxy → ruoc (meters) → druzhok `/internal/embed` → worker. ruoc stays a pure meter; one process holds the model for every bot. |
| Pricing | New ruoc catalogue kind `embedding`, per million input tokens, rate 0 at launch | Mirrors `transcribe`'s token pricing and `fetch`'s "free is still a ledger row". Repricing is one `ruocd embed setup`. |
| LLM consolidation | Off (`MNEMOSYNE_LLM_ENABLED` default false) | Zero LLM cost. Mnemosyne's non-LLM sleep (dedup, decay, prune) still runs every 10 turns. Revisit after seeing recall quality. |
| Tool surface | `memory.mnemosyne.tools: [mnemosyne_remember, mnemosyne_recall, mnemosyne_forget]` | The provider exposes 37 tools by default, about 9k tokens of schema on every LLM call. Three tools cover what a Telegram assistant needs; prefetch injection works regardless. |
| Rollout | Per-bot instance flag, default `builtin`, operator's bot first | Existing bots keep today's behaviour until flipped from the settings tab. |

## 3. Request path

```
hermes bot (Mnemosyne provider)
  │ POST /v1/embeddings  {"model":"ruoc-embed","input":["query: …"]}   Bearer <tenant key>
  ▼
druzhok proxy  POST /v1/embeddings      LlmAuth → LlmProxy.Ruoc (replaces the OpenRouter forward)
  │ POST /v1/embeddings                  Bearer <bot's ruoc key>
  ▼
ruoc-gateway   POST /v1/embeddings      catalogue entry `ruoc-embed`, kind `embedding`; admission, charge, ledger
  │ POST /internal/embed                 Bearer FETCH_SECRET (same secret and plug as /internal/fetch)
  ▼
druzhok        Druzhok.Embed.Worker     GenServer + Python ONNX worker port, multilingual-e5-small
```

The bot never sees ruoc; it only knows the proxy URL and its tenant key, both already in
its environment. Mnemosyne adds the `query: ` / `passage: ` prefixes itself from env.

## 4. Components

### 4.1 Embedding worker (druzhok)

- `apps/druzhok/priv/embed-worker/worker.py`: `onnxruntime` + `tokenizers` + `numpy`, no
  torch. Loads the model directory given as argv, `{:packet, 4}` JSON framing like the fetch
  worker. Request `{"texts": [...]}`; reply `{"vectors": [[f32 × 384], ...], "tokens": N}` or
  `{"error": "embed_failed"}`. Tokenize with truncation at 512, mean-pool over the attention
  mask, L2-normalise (the e5 recipe). `tokens` is the sum of token counts after truncation:
  the number ruoc bills. Intra-op threads 2.
- Model files: `model.onnx` (fp32, 470 MB) from the `onnx/` folder of the HF repo, plus
  `tokenizer.json`. Ship to `/data/opt/embed-models/multilingual-e5-small/`; the worker never
  downloads. The int8 `model_qint8_avx512_vnni.onnx` (118 MB) is an option once the eval
  corpus (scratchpad `corpus.py` / `eval.py`, to be moved to `ops/embed-eval/`) confirms R@5
  within 0.02 of fp32 on the server's Cascadelake.
- Venv: `/opt/druzhok-embed` (same pattern as `/opt/druzhok-fetch`), Python from
  `EMBED_WORKER_BIN`, model dir from `EMBED_MODEL_DIR`, both in `/etc/druzhok/druzhok.env`.
- `Druzhok.Embed.Worker` (`apps/druzhok/lib/druzhok/embed/worker.ex`): a copy of
  `Druzhok.Fetch.Worker`'s shape. `embed(texts, opts) :: {:ok, %{vectors, tokens}} |
  {:error, :embed_failed | :worker_down}`. Calls serialised through the GenServer; default
  timeout 10 s; restarts under `Druzhok.Application`'s supervisor; with no `embed_worker_bin`
  configured every call answers `{:error, :worker_down}`.
- Limits, enforced in the controller before the worker: at most 64 texts per request, each at
  most 8,000 characters, body at most 1 MiB.

### 4.2 Internal endpoint (druzhok_web)

- `POST /internal/embed`, behind the existing `FetchAuth` plug (bearer `fetch_secret`).
  `InternalEmbedController.create/2`: validate limits, call the worker, reply
  `{"vectors": [...], "tokens": N, "dim": 384, "model": "multilingual-e5-small"}`. Errors:
  400 on a bad body, 413 over limits, 503 `{"error": "worker_down"}`, 500
  `{"error": "embed_failed"}`.

### 4.3 ruoc-gateway

- `internal/catalog`: `KindEmbedding = "embedding"`. One entry named `ruoc-embed`, priced
  on the existing `InputTokens` unit kind (per million). Hidden from `GET /v1/models` and
  `ruocd model list`, like search and fetch. A completion naming `ruoc-embed` gets the usual
  404.
- `internal/upstream/embed.go`: `Embedder` interface
  (`Embed(ctx, EmbedRequest{Texts}) (EmbedResult{Vectors, Tokens, Dim}, error)`) and
  `DruzhokEmbedder` that POSTs to `<druzhok base>/internal/embed` with the bearer secret,
  reusing the `druzhok` upstream entry `/v1/fetch` already routes to. Timeout 20 s.
- `internal/httpapi/embed.go`: `POST /v1/embeddings`, OpenAI request and response shape
  (`{"model", "input": string | [string]}` in; `{"object":"list","data":[{"object":"embedding",
  "index","embedding"}],"model":"ruoc-embed","usage":{"prompt_tokens","total_tokens"}}` out).
  Shape of the fetch handler: authenticate, per-account rate limit (`embedByAccnt`,
  `EMBED_BURST` / `EMBED_INTERVAL`), body cap 1 MiB and the same 64 × 8,000 limits, admission
  on an estimate of `len(chars)/3` tokens, charge the worker's actual `tokens`, ledger row.
  A failed embed is charged nothing. 402 when the balance can't cover the estimate.
- `ruocd embed setup -rub-in <per M> [-usd-in <per M>]` and `ruocd embed show`, modelled on
  `transcribe setup`. Launch with `-rub-in 0`.
- Console pricing page lists the entry with the other kinds; no new screen.

### 4.4 Proxy leg (druzhok_web)

- `LlmProxyController.embeddings/2` stops forwarding to OpenRouter. It sends the body as is
  to ruoc `/v1/embeddings` with the bot's ruoc key through `LlmProxy.Ruoc` (the same 402 → pass
  through, 5xx → 502 handling as search), returns ruoc's response unchanged, and logs a
  `usage_logs` row with `request_type: "embedding"`, `prompt_tokens` from `usage`, `provider:
  "ruoc"`, `cost_cents: 0`. A bot without a ruoc key gets 503 from `LlmAuth` as today.
- The Settings page card "OpenRouter (embeddings, image generation, /v1/responses)" drops
  "embeddings" from its title.

### 4.5 Bot configuration (druzhok)

- Migration: `instances.memory_provider :string, default "builtin"`. Allowed values
  `"builtin"`, `"mnemosyne"`, validated in the `Instance` changeset.
- `Runtime.Hermes.sync_memory_block/1` writes `provider: <value>` (currently pinned to
  `builtin`); builtin flags stay `true` for both values. When the value is `mnemosyne` it also
  writes the nested block

  ```yaml
  memory:
    provider: mnemosyne
    memory_enabled: true
    user_profile_enabled: true
    mnemosyne:
      tools: [mnemosyne_remember, mnemosyne_recall, mnemosyne_forget]
  ```

  and removes the `mnemosyne:` block when the value goes back to `builtin`.
- `Runtime.Hermes.env_vars/1` adds, only for `mnemosyne`:

  ```
  MNEMOSYNE_DATA_DIR=<tenant dir>/mnemosyne
  MNEMOSYNE_EMBEDDING_API_URL=<proxy_url>/v1
  MNEMOSYNE_EMBEDDING_API_KEY=<tenant key>
  MNEMOSYNE_EMBEDDING_MODEL=ruoc-embed
  MNEMOSYNE_EMBEDDING_DIM=384
  MNEMOSYNE_EMBEDDING_QUERY_PREFIX="query: "
  MNEMOSYNE_EMBEDDING_DOC_PREFIX="passage: "
  MNEMOSYNE_LLM_ENABLED=false
  MNEMOSYNE_HOST_LLM_ENABLED=false
  ```

  The two prefixes carry a trailing space; the env file writer must quote them.
- Settings tab: a "Память" select with the two values, saved through the existing instance
  update path, applied on the next restart (same as other config changes). Dashboard create
  form and the manager bot keep `builtin`; flipping the default for new bots is a later
  one-line change once the operator's bot has run on it for a week.
- Data dir: `<tenant>/mnemosyne/` is created by Mnemosyne itself under the bot user; it sits
  inside `ReadWritePaths=/data/tenants/%i`, so the unit needs no change. The
  never-wipe rule covers it.

### 4.6 Hermes install

- The fork's `pyproject.toml` gets an optional extra
  `mnemosyne = ["mnemosyne-memory[embeddings]==3.15.1", "mnemosyne-hermes==0.5.0"]` (PyPI releases as of 2026-09-06; the plan re-checks), committed
  on the fork's `main` as a druzhok customisation and added to the `update-hermes` skill as
  "Customization 5" (re-add the extra after each reset to an upstream tag). The server
  install adds `--extra mnemosyne` to its `uv sync`. Hermes discovers the provider through the
  `hermes_agent.memory_providers` entry point; no per-tenant plugin directory.
- `[embeddings]` pulls fastembed + onnxruntime + sqlite-vec (about 200 MB in the shared
  venv). In API mode nothing is downloaded at runtime; bots have no internet anyway.

## 5. Failure modes

| Failure | Behaviour |
|---|---|
| Worker missing or crashed | `/internal/embed` 503 → ruoc 502 → proxy 502. Mnemosyne retries 3× with backoff, then the turn runs on FTS recall only. Bot keeps answering. Supervisor restarts the worker. |
| ruoc down | proxy 502, same degradation. |
| Balance empty (after pricing) | ruoc 402 → proxy 402 as is; Mnemosyne treats 4xx as permanent for that call and degrades. Can't happen at rate 0. |
| Over limits | 413 from druzhok or ruoc; Mnemosyne logs a warning and degrades. Its batches are far below 64 texts. |
| Model swapped for a different dimension later | Out of scope; needs `MNEMOSYNE_EMBEDDING_DIM` change plus `mnemosyne reindex` per tenant, and a new catalogue entry name so old and new vectors are never mixed. |

## 6. Testing

- Elixir: `Druzhok.Embed.Worker` against a fake worker script (`test/support/fake_embed_worker.py`)
  that returns fixed vectors and token counts, including a crash-and-restart case;
  `InternalEmbedController` auth, limits and error mapping; proxy embeddings leg with a stub ruoc
  (200 with usage, 402, 500) and the `usage_logs` row; `Runtime.Hermes` config block and env
  for both provider values, including prefix quoting and block removal on switch-back;
  `Instance` changeset rejects unknown values.
- Go: handler tests mirroring `fetch_test.go` (auth, rate limit, limits, estimate admission,
  charge on success, nothing on failure, 402), catalogue kind and pricing tests, `DruzhokEmbedder`
  against an httptest server, `ruocd embed setup/show`.
- Python: `worker.py` round trip on the real model (vectors normalised, token counts,
  truncation) run locally; the eval corpus moved to `ops/embed-eval/` with a `--endpoint` mode
  that scores `/internal/embed` on the server before the first bot is flipped.

## 7. Rollout

1. Server: create `/opt/druzhok-embed`, copy model files to `/data/opt/embed-models/`, add
   `EMBED_WORKER_BIN` and `EMBED_MODEL_DIR` to `/etc/druzhok/druzhok.env`.
2. Deploy ruoc with the new kind, `ruocd embed setup -rub-in 0`, `ruocd embed show`.
3. Deploy druzhok (migration, worker, endpoint, proxy leg). Check `/internal/embed` with the
   eval script, then `/v1/embeddings` with a tenant key.
4. Install the hermes extra into `/opt/hermes` (`uv sync … --extra mnemosyne`). Running bots
   are unaffected until restarted.
5. Flip `memory_provider` on the operator's bot, restart through `BotManager.restart`, talk to
   it, check `sudo druzhok-ctl logs`, the `usage_logs` embedding rows, the ruoc ledger and
   `mnemosyne stats` in the tenant dir.
6. After a week: flip other bots on request, then change the new-bot default.

## 8. Out of scope

Hindsight or any LLM-backed memory tier; LLM consolidation; changing the model or dimension;
per-user memory banks inside group bots (Mnemosyne's default scope is per HERMES_HOME, which is
per bot); a manager-bot command for the toggle; migrating existing MEMORY.md content into
Mnemosyne (builtin stays on, so nothing is lost).
