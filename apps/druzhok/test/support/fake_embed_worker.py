"""Stand-in for the ONNX worker: same framing, deterministic 4-dim vectors,
tokens = words. A text equal to "CRASH" exits the process (restart tests);
"SLOW" sleeps 2 s (timeout tests); "BAD" answers embed_failed. Like the real
worker it announces {"ready": true} once "loaded"; a model dir named "die"
exits before that and one named "slow" takes 2 s to load (startup tests)."""
import json
import struct
import sys
import time


def write(stdout, reply):
    payload = json.dumps(reply).encode()
    stdout.write(struct.pack(">I", len(payload)) + payload)
    stdout.flush()


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    model_dir = sys.argv[1].rstrip("/") if len(sys.argv) > 1 else ""
    if model_dir.endswith("/die"):
        sys.exit(4)
    if model_dir.endswith("/slow"):
        time.sleep(2)
    write(stdout, {"ready": True})
    while True:
        header = stdin.read(4)
        if len(header) < 4:
            return
        (n,) = struct.unpack(">I", header)
        req = json.loads(stdin.read(n))
        texts = req.get("texts") or []
        if "CRASH" in texts:
            sys.exit(3)
        if "SLOW" in texts:
            time.sleep(2)
        if "BAD" in texts:
            reply = {"error": "embed_failed"}
        else:
            reply = {"vectors": [[len(t) / 100.0, 0.5, 0.25, 0.125] for t in texts],
                     "tokens": sum(len(t.split()) for t in texts)}
        write(stdout, reply)


if __name__ == "__main__":
    main()
