"""Scores an OpenAI-shaped /v1/embeddings on a Russian memory corpus: R@1, R@5, MRR, hard-negative wins.
Usage: EMBED_EVAL_KEY=<tenant or ruoc key> python3 ops/embed-eval/eval.py <base url> <model>
  e.g. ... http://127.0.0.1:4000 ruoc-embed-e5-large      (through the druzhok proxy, tenant key)
       ... https://agent.oldey.dev ruoc-embed-e5-large    (ruoc-gateway directly, ruoc key)
Needs only the standard library."""
import json
import os
import sys
import time
import urllib.request

from corpus import MEMORIES, QUERIES

tokens = 0
dims = set()


def embed(base, key, model, texts):
    global tokens
    req = urllib.request.Request(base + "/v1/embeddings", data=json.dumps({"model": model, "input": texts}).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=120) as resp:
        d = json.loads(resp.read())
    tokens += d.get("usage", {}).get("prompt_tokens", 0)
    vectors = [x["embedding"] for x in sorted(d["data"], key=lambda x: x["index"])]
    for v in vectors:
        dims.add(len(v))
    return vectors


def batched(base, key, model, texts, size=64):
    out = []
    for i in range(0, len(texts), size):
        out += embed(base, key, model, texts[i:i + size])
    return out


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def main(base, model):
    key = os.environ["EMBED_EVAL_KEY"]
    t0 = time.time()
    P = batched(base, key, model, ["passage: " + m for m in MEMORIES])
    Q = batched(base, key, model, ["query: " + q for q, _, _ in QUERIES])
    norms = [round(dot(v, v) ** 0.5, 4) for v in P[:3]]
    r1 = r5 = mrr = hn = 0.0
    nneg = 0
    for qi, (q, rel, neg) in enumerate(QUERIES):
        ranked = sorted(range(len(P)), key=lambda j: -dot(Q[qi], P[j]))
        ranked = [j + 1 for j in ranked]
        first = next(i for i, d in enumerate(ranked) if d in rel)
        mrr += 1 / (first + 1)
        r1 += ranked[0] in rel
        r5 += len(set(rel) & set(ranked[:5])) / min(5, len(rel))
        if neg:
            nneg += 1
            hn += any(ranked.index(n) < first for n in neg)
    n = len(QUERIES)
    print(f"{model}: R@1={r1/n:.2f} R@5={r5/n:.2f} MRR={mrr/n:.2f} hardneg_wins={int(hn)}/{nneg} "
          f"dims={sorted(dims)} tokens={tokens} norms={norms} took={time.time()-t0:.1f}s")


if __name__ == "__main__":
    main(sys.argv[1].rstrip("/"), sys.argv[2])
