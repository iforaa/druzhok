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
