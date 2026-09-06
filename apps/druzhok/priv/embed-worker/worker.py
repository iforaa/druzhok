"""Druzhok embed worker: texts in, unit vectors out, over an Erlang Port.

Framing is {:packet, 4}: a 4-byte big-endian length then one JSON object.
Request {"texts": [...]}; reply {"vectors": [[...], ...], "tokens": N} or
{"error": "embed_failed"}. `tokens` is the number of tokens actually
embedded after truncation, which is what ruoc bills. No network, no state
beyond the loaded model; every limit is enforced on the Elixir side.
"""

import json
import os
import struct
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

MAX_TOKENS = 512
THREADS = int(os.environ.get("EMBED_THREADS", "2"))


def read_message(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (length,) = struct.unpack(">I", header)
    payload = stream.read(length)
    if len(payload) < length:
        return None
    return json.loads(payload.decode("utf-8"))


def write_message(stream, obj):
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


class Embedder:
    def __init__(self, model_dir):
        self.tokenizer = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
        self.tokenizer.enable_truncation(MAX_TOKENS)
        pad_id = self.tokenizer.token_to_id("<pad>")
        self.tokenizer.enable_padding(pad_id=pad_id if pad_id is not None else 1, pad_token="<pad>")
        opts = ort.SessionOptions()
        opts.intra_op_num_threads = THREADS
        opts.inter_op_num_threads = 1
        self.session = ort.InferenceSession(os.path.join(model_dir, "model.onnx"), opts, providers=["CPUExecutionProvider"])
        self.input_names = [i.name for i in self.session.get_inputs()]

    def embed(self, texts):
        if not texts:
            return [], 0
        if not all(isinstance(t, str) for t in texts):
            raise ValueError("texts must be strings")
        enc = self.tokenizer.encode_batch(texts)
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
        feeds = {"input_ids": ids, "attention_mask": mask}
        if "token_type_ids" in self.input_names:
            feeds["token_type_ids"] = np.zeros_like(ids)
        hidden = self.session.run(None, feeds)[0]
        m = mask[..., None].astype(np.float32)
        pooled = (hidden * m).sum(axis=1) / np.clip(m.sum(axis=1), 1e-9, None)
        norms = np.linalg.norm(pooled, axis=1, keepdims=True)
        vectors = pooled / np.clip(norms, 1e-12, None)
        return vectors.astype(np.float32).tolist(), int(mask.sum())


def main():
    embedder = Embedder(sys.argv[1])
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    while True:
        request = read_message(stdin)
        if request is None:
            return
        try:
            vectors, tokens = embedder.embed(request.get("texts"))
            reply = {"vectors": vectors, "tokens": tokens}
        except Exception:  # noqa: BLE001 — one bad batch must not kill the worker
            reply = {"error": "embed_failed"}
        write_message(stdout, reply)


if __name__ == "__main__":
    main()
