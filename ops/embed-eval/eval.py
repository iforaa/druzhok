"""Scores /internal/embed on a Russian memory corpus: R@1, R@5, MRR, hard-negative wins.
Usage: python3 ops/embed-eval/eval.py http://127.0.0.1:4000 <FETCH_SECRET>
Needs only the standard library."""
import json
import sys
import urllib.request

from corpus import MEMORIES, QUERIES


def embed(base, secret, texts):
    req = urllib.request.Request(base + "/internal/embed", data=json.dumps({"texts": texts}).encode(),
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + secret})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())["vectors"]


def batched(base, secret, texts, size=64):
    out = []
    for i in range(0, len(texts), size):
        out += embed(base, secret, texts[i:i + size])
    return out


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def main(base, secret):
    P = batched(base, secret, ["passage: " + m for m in MEMORIES])
    Q = batched(base, secret, ["query: " + q for q, _, _ in QUERIES])
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
    print(f"R@1={r1/n:.2f} R@5={r5/n:.2f} MRR={mrr/n:.2f} hardneg_wins={int(hn)}/{nneg}")


if __name__ == "__main__":
    main(sys.argv[1].rstrip("/"), sys.argv[2])
