# Embedding eval

`corpus.py` is one Russian Telegram user's memory bank (120 facts, 13 deliberate look-alikes)
with 84 colloquial queries. `EMBED_EVAL_KEY=<key> eval.py <base url> <model>` embeds it through
an OpenAI-shaped `POST /v1/embeddings` (druzhok proxy with a tenant key, or ruoc-gateway with a
ruoc key) and prints R@1, R@5, MRR and how often a look-alike outranks the answer.

Gate: R@5 ≥ 0.95. Any model a ruoc catalogue entry is pointed at must pass it before bots move,
and a move is a new entry + `MNEMOSYNE_EMBEDDING_MODEL`/`DIM` in `Runtime.Hermes` +
`druzhok-ctl exec <bot> mnemosyne reindex --yes` per bot.

| Model | R@1 | R@5 | MRR | hard-negative wins |
|---|---|---|---|---|
| multilingual-e5-small fp32 (druzhok ONNX worker, retired) | 0.80 | 0.95 | 0.87 | 2/44 |
| `ruoc-embed-e5-large` = intfloat/multilingual-e5-large via OpenRouter (2026-10-20) | 0.86 | 0.97 | 0.91 | 5/44 |
| baai/bge-m3 via OpenRouter | 0.88 | 0.94 ✗ | 0.91 | 3/44 |
| **`ruoc-embed-gemini`** = google/gemini-embedding-001 via OpenRouter (2026-10-22) | 0.95 | 1.00 | 0.97 | 2/44 |
| openai/text-embedding-3-small via OpenRouter | 0.83 | 0.98 | 0.90 | 5/44 |
| qwen/qwen3-embedding-8b via OpenRouter | 0.85 | 0.97 | 0.90 | 4/44 |

All rows with the e5 `query: `/`passage: ` prefixes, which bots send (`MNEMOSYNE_EMBEDDING_*_PREFIX`).
Without them (2026-10-22): gemini R@5 0.99, text-embedding-3-small 0.96, e5-large 0.95, qwen3-8b 0.87.
Single-query latency from one window of 30 calls: e5-large had one 32-text batch hang > 60 s; gemini p90 1.2 s.
