# Mnemosyne Memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each hermes bot Mnemosyne episodic memory with Russian-capable embeddings served by one druzhok-side model and metered through ruoc-gateway.

**Architecture:** The bot's Mnemosyne provider calls the druzhok proxy `/v1/embeddings`; the proxy forwards to ruoc `/v1/embeddings` (new catalogue kind `embedding`, priced per million input tokens, 0 at launch); ruoc calls back to druzhok `/internal/embed`, where a Python ONNX worker (multilingual-e5-small) runs behind a GenServer port. A per-bot `memory_provider` flag turns the config block and env vars on.

**Tech Stack:** Elixir/Phoenix (druzhok), Go (ruoc-gateway), Python 3 + onnxruntime + tokenizers (worker), SQLite (Mnemosyne, per tenant), systemd.

**Spec:** `docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md`

## Global Constraints

- Embedding model: `intfloat/multilingual-e5-small`, 384 dimensions, fp32 ONNX (`onnx/model.onnx`, 470 MB) plus `onnx/tokenizer.json`. Never downloaded at runtime.
- Catalogue entry name `ruoc-embed`, kind `embedding`, priced on `InputTokens` per million, launch rate 0.
- Limits shared by druzhok and ruoc: at most 64 texts per request, each at most 8,000 characters, body at most 1 MiB. Admission estimate `chars / 3` tokens.
- Mnemosyne env for a bot: `MNEMOSYNE_DATA_DIR`, `MNEMOSYNE_EMBEDDING_API_URL`, `MNEMOSYNE_EMBEDDING_API_KEY`, `MNEMOSYNE_EMBEDDING_MODEL=ruoc-embed`, `MNEMOSYNE_EMBEDDING_DIM=384`, `MNEMOSYNE_EMBEDDING_QUERY_PREFIX="query: "`, `MNEMOSYNE_EMBEDDING_DOC_PREFIX="passage: "`, `MNEMOSYNE_LLM_ENABLED=false`, `MNEMOSYNE_HOST_LLM_ENABLED=false`. The two prefixes keep their trailing space.
- Config block for a Mnemosyne bot: `memory.provider: mnemosyne`, builtin flags stay `true`, `memory.mnemosyne.tools: [mnemosyne_remember, mnemosyne_recall, mnemosyne_forget]`.
- Package pins: `mnemosyne-memory[embeddings]==3.15.1`, `mnemosyne-hermes==0.5.0`.
- Commits: short imperative subject, no Claude attribution, no trailers (user's global rule). Never `git add hermes-agent/` into druzhok.
- Secrets: never print or source `/etc/druzhok/druzhok.env`, `/etc/ruoc/ruoc.env`, or ruoc-gateway's `.env`. Read single keys with `grep -o '^KEY=.*'`.
- Local disk is nearly full. Before Task 1 free space: `rm -rf ~/.cache/huggingface/hub/models--BAAI--bge-m3 ~/.cache/huggingface/hub/models--intfloat--multilingual-e5-base` (eval leftovers, 3.2 GB) and, if needed, Xcode DerivedData.
- ruoc-gateway lives at `~/Documents/ruoc-gateway` (Go, separate repo). Its tests need `TEST_DATABASE_URL`; take it with `grep -o '^TEST_DATABASE_URL=.*' ~/Documents/ruoc-gateway/.env | cut -d= -f2-` and export only that variable.

## File structure

druzhok (this repo):

| Path | Responsibility |
|---|---|
| `apps/druzhok/priv/embed-worker/worker.py` | Python ONNX worker: texts in, unit vectors + token count out, packet-4 JSON framing |
| `apps/druzhok/priv/embed-worker/requirements.txt` | `onnxruntime`, `tokenizers`, `numpy` pins |
| `apps/druzhok/priv/embed-worker/test_worker.py` | Worker round-trip test on the real model |
| `ops/embed-model-fetch.sh` | Downloads the two model files into a directory |
| `apps/druzhok/lib/druzhok/embed/worker.ex` | `Druzhok.Embed.Worker` GenServer around the port |
| `apps/druzhok/test/support/fake_embed_worker.py` | Deterministic stand-in worker for GenServer tests |
| `apps/druzhok/test/druzhok/embed/worker_test.exs` | GenServer contract tests (fake) + one real-model test |
| `apps/druzhok_web/lib/druzhok_web_web/controllers/embed_controller.ex` | `POST /internal/embed` |
| `apps/druzhok_web/test/support/embed_stub.ex` | Stand-in for the worker in controller tests |
| `apps/druzhok_web/test/druzhok_web_web/controllers/embed_controller_test.exs` | Endpoint tests |
| `apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy/ruoc.ex` | `embeddings/2` ruoc leg |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/ruoc/embeddings_test.exs` | Proxy leg tests (replaces the OpenRouter one) |
| `apps/druzhok/priv/repo/migrations/20260906000001_add_memory_provider_to_instances.exs` | `memory_provider` column |
| `apps/druzhok/lib/druzhok/instance.ex` | field + validation |
| `apps/druzhok/lib/druzhok/runtime/hermes.ex` | memory block + env vars |
| `apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` | Memory card select |
| `ops/bootstrap.sh`, `CLAUDE.md`, `ops/embed-eval/` | venv + model + env keys, docs, eval corpus |

ruoc-gateway (`~/Documents/ruoc-gateway`):

| Path | Responsibility |
|---|---|
| `internal/catalog/model.go`, `internal/catalog/pricing.go` | `KindEmbedding`, `EmbedServiceID`, unit kinds |
| `internal/store/catalog.go` | `LoadEmbed` |
| `internal/upstream/embed.go` (+test) | `Embedder`, `DruzhokEmbedder` |
| `internal/httpapi/embed.go` (+test), `hosts.go`, `server.go` | `POST /v1/embeddings`, limiter, route |
| `internal/config/config.go` | `EMBED_BURST`, `EMBED_INTERVAL` |
| `cmd/ruocd/operator.go`, `cmd/ruocd/main.go` | `ruocd embed setup|show` |
| `web/src/lib/api.ts`, `README.md` | kind union, docs |

hermes fork (`hermes-agent/`, separate repo): `pyproject.toml` extra `mnemosyne`, `uv.lock`; skill file `~/.claude/skills/update-hermes/SKILL.md`.

---

## Part A: druzhok

### Task 1: Python embedding worker

**Files:**
- Create: `apps/druzhok/priv/embed-worker/worker.py`
- Create: `apps/druzhok/priv/embed-worker/requirements.txt`
- Create: `apps/druzhok/priv/embed-worker/test_worker.py`
- Create: `ops/embed-model-fetch.sh`
- Modify: `.gitignore` (add `.embed-venv/`, `.embed-model/`)

**Interfaces:**
- Produces: worker protocol. Request `{"texts": [str, ...]}`; reply `{"vectors": [[float × 384], ...], "tokens": int}` or `{"error": "embed_failed"}`. argv: `worker.py <model_dir>`. `{:packet, 4}` framing (4-byte big-endian length + JSON).

- [ ] **Step 1: Model download script**

```bash
cat > ops/embed-model-fetch.sh <<'SH'
#!/usr/bin/env bash
# Downloads the multilingual-e5-small ONNX model druzhok's embed worker loads.
# Usage: ops/embed-model-fetch.sh <dir>   (e.g. /data/opt/embed-models/multilingual-e5-small)
set -euo pipefail
dir="${1:?target directory}"
base="https://huggingface.co/intfloat/multilingual-e5-small/resolve/main/onnx"
mkdir -p "$dir"
for f in model.onnx tokenizer.json config.json; do
  [ -s "$dir/$f" ] || curl -fsSL "$base/$f" -o "$dir/$f.part" && mv -f "$dir/$f.part" "$dir/$f" 2>/dev/null || true
done
ls -l "$dir"
SH
chmod +x ops/embed-model-fetch.sh
printf '.embed-venv/\n.embed-model/\n' >> .gitignore
ops/embed-model-fetch.sh .embed-model
```

Expected: `.embed-model/model.onnx` about 470 MB, `tokenizer.json` about 17 MB.

- [ ] **Step 2: Requirements and venv**

```bash
cat > apps/druzhok/priv/embed-worker/requirements.txt <<'TXT'
onnxruntime==1.22.1
tokenizers==0.21.4
numpy==2.2.6
TXT
python3 -m venv .embed-venv && .embed-venv/bin/pip install -q -r apps/druzhok/priv/embed-worker/requirements.txt
```

If a pin is not on PyPI for the local Python, take the nearest release and keep it pinned.

- [ ] **Step 3: Write the failing worker test**

```python
# apps/druzhok/priv/embed-worker/test_worker.py
"""Round trip against the real model. Run: .embed-venv/bin/python apps/druzhok/priv/embed-worker/test_worker.py .embed-model"""
import json, math, os, struct, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def start(model_dir):
    return subprocess.Popen([sys.executable, os.path.join(HERE, "worker.py"), model_dir],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE)


def call(proc, obj):
    payload = json.dumps(obj).encode()
    proc.stdin.write(struct.pack(">I", len(payload)) + payload)
    proc.stdin.flush()
    (n,) = struct.unpack(">I", proc.stdout.read(4))
    return json.loads(proc.stdout.read(n))


def cos(a, b):
    return sum(x * y for x, y in zip(a, b))


def main(model_dir):
    proc = start(model_dir)
    r = call(proc, {"texts": ["query: кошка", "passage: кот сидит на окне", "passage: квартальная бухгалтерская отчётность"]})
    vecs, tokens = r["vectors"], r["tokens"]
    assert len(vecs) == 3 and all(len(v) == 384 for v in vecs), "dim"
    assert all(abs(math.sqrt(cos(v, v)) - 1) < 1e-3 for v in vecs), "unit norm"
    assert tokens > 6, tokens
    assert cos(vecs[0], vecs[1]) > cos(vecs[0], vecs[2]), "cat closer than accounting"

    long = "passage: " + "слово " * 3000
    r = call(proc, {"texts": [long]})
    assert r["tokens"] == 512, r["tokens"]

    r = call(proc, {"texts": []})
    assert r == {"vectors": [], "tokens": 0}, r

    r = call(proc, {"texts": [123]})
    assert r == {"error": "embed_failed"}, r

    proc.stdin.close()
    assert proc.wait(timeout=10) == 0
    print("ok")


if __name__ == "__main__":
    main(sys.argv[1])
```

- [ ] **Step 4: Run it to see it fail**

Run: `.embed-venv/bin/python apps/druzhok/priv/embed-worker/test_worker.py .embed-model`
Expected: FAIL, `worker.py` not found.

- [ ] **Step 5: Write the worker**

```python
# apps/druzhok/priv/embed-worker/worker.py
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
        self.tokenizer.enable_padding(pad_id=self.tokenizer.token_to_id("<pad>") or 1, pad_token="<pad>")
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
        (hidden,) = self.session.run(None, feeds)[:1]
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
```

- [ ] **Step 6: Run the test**

Run: `.embed-venv/bin/python apps/druzhok/priv/embed-worker/test_worker.py .embed-model`
Expected: `ok`. If the ONNX input names differ (`session.get_inputs()`), adapt `feeds` and keep the test as is.

- [ ] **Step 7: Commit**

```bash
git add apps/druzhok/priv/embed-worker ops/embed-model-fetch.sh .gitignore
git commit -m "add embed worker for multilingual-e5-small"
```

### Task 2: `Druzhok.Embed.Worker` GenServer

**Files:**
- Create: `apps/druzhok/lib/druzhok/embed/worker.ex`
- Create: `apps/druzhok/test/support/fake_embed_worker.py`
- Create: `apps/druzhok/test/druzhok/embed/worker_test.exs`
- Modify: `apps/druzhok/lib/druzhok/application.ex` (children list, after `Druzhok.Fetch.Worker`)
- Modify: `config/config.exs`, `config/test.exs`, `config/runtime.exs`, `apps/druzhok/test/test_helper.exs`

**Interfaces:**
- Produces: `Druzhok.Embed.Worker.embed(texts :: [String.t()], opts :: keyword) :: {:ok, %{vectors: [[float]], tokens: non_neg_integer}} | {:error, :embed_failed | :worker_down}`. Options: `server`, `timeout` (default 10_000 ms). `start_link/1` options: `name`, `bin`, `script`, `model_dir`.
- App env: `:druzhok, :embed_worker_bin` (Python path, nil disables), `:druzhok, :embed_model_dir`.

- [ ] **Step 1: Fake worker**

```python
# apps/druzhok/test/support/fake_embed_worker.py
"""Stand-in for the ONNX worker: same framing, deterministic 4-dim vectors,
tokens = words. A text equal to "CRASH" exits the process (restart tests);
"SLOW" sleeps 2 s (timeout tests); "BAD" answers embed_failed."""
import json, struct, sys, time


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
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
        payload = json.dumps(reply).encode()
        stdout.write(struct.pack(">I", len(payload)) + payload)
        stdout.flush()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Failing tests**

```elixir
# apps/druzhok/test/druzhok/embed/worker_test.exs
defmodule Druzhok.Embed.WorkerTest do
  use ExUnit.Case, async: false

  alias Druzhok.Embed.Worker

  @fake Path.expand("../../support/fake_embed_worker.py", __DIR__)

  defp start_fake(name) do
    start_supervised!({Worker, name: name, bin: System.find_executable("python3"), script: @fake, model_dir: "fake"})
    name
  end

  test "embeds a batch and reports the token count" do
    server = start_fake(:embed_fake_1)
    assert {:ok, %{vectors: [[0.05, 0.5, 0.25, 0.125], [0.11, 0.5, 0.25, 0.125]], tokens: 3}} =
             Worker.embed(["hello", "два слова"], server: server)
  end

  test "an empty batch is an empty answer" do
    server = start_fake(:embed_fake_2)
    assert {:ok, %{vectors: [], tokens: 0}} = Worker.embed([], server: server)
  end

  test "a worker error is embed_failed" do
    server = start_fake(:embed_fake_3)
    assert {:error, :embed_failed} = Worker.embed(["BAD"], server: server)
  end

  test "a crashed worker is restarted on the next call" do
    server = start_fake(:embed_fake_4)
    assert {:error, :embed_failed} = Worker.embed(["CRASH"], server: server)
    assert {:ok, %{tokens: 1}} = Worker.embed(["again"], server: server)
  end

  test "a slow worker is killed and the call times out" do
    server = start_fake(:embed_fake_5)
    assert {:error, :embed_failed} = Worker.embed(["SLOW"], server: server, timeout: 300)
    assert {:ok, %{tokens: 1}} = Worker.embed(["after"], server: server)
  end

  test "no configured python means worker_down" do
    start_supervised!({Worker, name: :embed_none, bin: nil})
    assert {:error, :worker_down} = Worker.embed(["x"], server: :embed_none)
  end

  @tag :embed_worker
  test "the real model answers 384-dim unit vectors" do
    assert {:ok, %{vectors: [v], tokens: tokens}} = Worker.embed(["query: кошка"])
    assert length(v) == 384
    assert_in_delta Enum.reduce(v, 0, &(&2 + &1 * &1)), 1.0, 0.001
    assert tokens > 0
  end
end
```

- [ ] **Step 3: Run to see them fail**

Run: `mix test apps/druzhok/test/druzhok/embed/worker_test.exs`
Expected: compile error, `Druzhok.Embed.Worker` undefined.

- [ ] **Step 4: Implement the worker**

```elixir
# apps/druzhok/lib/druzhok/embed/worker.ex
defmodule Druzhok.Embed.Worker do
  @moduledoc """
  The Python embedding worker (`priv/embed-worker/worker.py`) as an Erlang
  Port: texts in, unit vectors and a token count out. One long-lived process,
  calls serialized here, `{:packet, 4}` framing with a JSON object per message.

  Limits (batch size, text length) belong to the caller. Without a configured
  Python (`embed_worker_bin`) every call answers `{:error, :worker_down}` and
  embeddings are simply off; Mnemosyne then recalls by FTS alone.
  """

  use GenServer
  require Logger

  @default_timeout 10_000

  @type result :: {:ok, %{vectors: [[float]], tokens: non_neg_integer}} | {:error, :embed_failed | :worker_down}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec embed([String.t()], keyword) :: result
  def embed(texts, opts \\ []) when is_list(texts) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    GenServer.call(server, {:embed, texts, deadline}, timeout + 1_000)
  catch
    :exit, reason ->
      Logger.warning("[embed] worker call gave up: #{inspect(elem(reason, 0))}")
      {:error, :worker_down}
  end

  @impl true
  def init(opts) do
    bin = Keyword.get(opts, :bin, Application.get_env(:druzhok, :embed_worker_bin))
    model_dir = Keyword.get(opts, :model_dir, Application.get_env(:druzhok, :embed_model_dir))
    script = Keyword.get(opts, :script, Path.join(Application.app_dir(:druzhok, "priv/embed-worker"), "worker.py"))
    Process.flag(:trap_exit, true)
    {:ok, %{bin: bin, script: script, model_dir: model_dir, port: nil, warned: false} |> open()}
  end

  defp open(%{bin: nil} = state), do: state

  defp open(%{bin: bin, script: script, model_dir: model_dir} = state) do
    if File.exists?(bin) and File.exists?(script) and is_binary(model_dir) do
      port =
        Port.open({:spawn_executable, bin}, [:binary, {:packet, 4}, :exit_status, :use_stdio, args: [script, model_dir]])

      %{state | port: port}
    else
      unless state.warned, do: Logger.warning("[embed] worker not started: #{inspect(bin)}, #{script} or model dir #{inspect(model_dir)} is missing")
      %{state | port: nil, warned: true}
    end
  end

  @impl true
  def handle_call({:embed, texts, deadline}, from, %{port: nil} = state) do
    case open(state) do
      %{port: nil} = state -> {:reply, {:error, :worker_down}, state}
      state -> handle_call({:embed, texts, deadline}, from, state)
    end
  end

  def handle_call({:embed, texts, deadline}, _from, %{port: port} = state) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.warning("[embed] dropped a request that timed out while queued")
      {:reply, {:error, :worker_down}, state}
    else
      Port.command(port, Jason.encode!(%{texts: texts}))

      receive do
        {^port, {:data, reply}} ->
          {:reply, decode(reply), state}

        {^port, {:exit_status, status}} ->
          Logger.warning("[embed] worker exited with #{status} mid-request")
          {:reply, {:error, :embed_failed}, %{state | port: nil}}
      after
        remaining ->
          Logger.warning("[embed] worker took longer than #{remaining} ms; killing it")
          kill(port)
          {:reply, {:error, :embed_failed}, %{state | port: nil}}
      end
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("[embed] worker exited with #{status}; it restarts on the next call")
    {:noreply, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, %{state | port: nil}}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp decode(reply) do
    case Jason.decode(reply) do
      {:ok, %{"vectors" => vectors, "tokens" => tokens}} when is_list(vectors) and is_integer(tokens) ->
        {:ok, %{vectors: vectors, tokens: tokens}}

      _ ->
        {:error, :embed_failed}
    end
  end
end
```

Wire it up:

```elixir
# apps/druzhok/lib/druzhok/application.ex — after Druzhok.Fetch.Worker in `children`
      Druzhok.Embed.Worker,
```

```elixir
# config/config.exs — in the `config :druzhok,` block after fetch_worker_bin
  # Python + model dir for the embed worker (priv/embed-worker); nil disables embeddings.
  embed_worker_bin: nil,
  embed_model_dir: nil
```

```elixir
# config/test.exs — next to fetch_worker_bin
  embed_worker_bin: System.get_env("EMBED_WORKER_BIN") || Path.expand("../.embed-venv/bin/python", __DIR__),
  embed_model_dir: System.get_env("EMBED_MODEL_DIR") || Path.expand("../.embed-model", __DIR__)
```

```elixir
# config/runtime.exs — after the FETCH_WORKER_BIN line
if bin = System.get_env("EMBED_WORKER_BIN"), do: config(:druzhok, embed_worker_bin: bin)
if dir = System.get_env("EMBED_MODEL_DIR"), do: config(:druzhok, embed_model_dir: dir)
```

```elixir
# apps/druzhok/test/test_helper.exs — replace the exclude computation
worker_bin = Application.get_env(:druzhok, :fetch_worker_bin)
embed_bin = Application.get_env(:druzhok, :embed_worker_bin)
embed_model = Application.get_env(:druzhok, :embed_model_dir)

exclude =
  [] ++
    if(worker_bin && File.exists?(worker_bin), do: [], else: [:fetch_worker]) ++
    if(embed_bin && File.exists?(embed_bin) && embed_model && File.exists?(Path.join(embed_model, "model.onnx")),
      do: [],
      else: [:embed_worker])

if :fetch_worker in exclude, do: IO.puts("fetch worker venv not found at #{inspect(worker_bin)}; skipping :fetch_worker tests")
if :embed_worker in exclude, do: IO.puts("embed worker venv/model not found; skipping :embed_worker tests")
ExUnit.start(exclude: exclude)
```

- [ ] **Step 5: Run the tests**

Run: `mix test apps/druzhok/test/druzhok/embed/worker_test.exs`
Expected: 7 tests pass (the real-model one runs because `.embed-venv` and `.embed-model` exist locally).

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok/lib/druzhok/embed apps/druzhok/test/druzhok/embed apps/druzhok/test/support/fake_embed_worker.py apps/druzhok/lib/druzhok/application.ex config apps/druzhok/test/test_helper.exs
git commit -m "add Druzhok.Embed.Worker port around the embed worker"
```

### Task 3: `POST /internal/embed`

**Files:**
- Create: `apps/druzhok_web/lib/druzhok_web_web/controllers/embed_controller.ex`
- Create: `apps/druzhok_web/test/support/embed_stub.ex`
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/embed_controller_test.exs`
- Modify: `apps/druzhok_web/lib/druzhok_web_web/router.ex` (internal scope)

**Interfaces:**
- Consumes: `Druzhok.Embed.Worker.embed/2` (Task 2), `DruzhokWebWeb.Plugs.FetchAuth` (existing).
- Produces: `POST /internal/embed {"texts": [...]}` → 200 `{"vectors": [...], "tokens": N, "dim": 384, "model": "multilingual-e5-small"}`; 400 `{"error": "bad_request"}`; 413 `{"error": "too_many_texts" | "text_too_long"}`; 503 `{"error": "worker_down"}`; 502 `{"error": "embed_failed"}`. App env `:druzhok_web, :embed_module` selects the worker module (tests).

- [ ] **Step 1: Stub**

```elixir
# apps/druzhok_web/test/support/embed_stub.ex
defmodule DruzhokWebWeb.EmbedStub do
  @moduledoc "Stands in for `Druzhok.Embed.Worker` in controller tests: one canned reply, records calls."

  def start(reply \\ {:ok, %{vectors: [[0.1, 0.2]], tokens: 3}}) do
    {:ok, pid} = Agent.start(fn -> %{reply: reply, calls: []} end)
    Application.put_env(:druzhok_web, :embed_module, __MODULE__)
    Application.put_env(:druzhok_web, :embed_stub, pid)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:druzhok_web, :embed_module)
      Application.delete_env(:druzhok_web, :embed_stub)
      Agent.stop(pid)
    end)

    pid
  end

  def reply(result), do: Agent.update(agent(), &%{&1 | reply: result})
  def calls, do: agent() |> Agent.get(& &1.calls) |> Enum.reverse()

  def embed(texts, _opts \\ []) do
    Agent.get_and_update(agent(), fn state -> {state.reply, %{state | calls: [texts | state.calls]}} end)
  end

  defp agent, do: Application.fetch_env!(:druzhok_web, :embed_stub)
end
```

- [ ] **Step 2: Failing tests**

```elixir
# apps/druzhok_web/test/druzhok_web_web/controllers/embed_controller_test.exs
defmodule DruzhokWebWeb.EmbedControllerTest do
  use DruzhokWebWeb.ConnCase, async: false

  alias DruzhokWebWeb.EmbedStub

  @secret "fetch-secret-for-tests"

  setup do
    EmbedStub.start()
    Druzhok.Settings.set("fetch_secret", @secret)
    :ok
  end

  defp call(conn, body, secret \\ @secret) do
    conn |> put_req_header("authorization", "Bearer " <> secret) |> post("/internal/embed", body)
  end

  test "embeds with the shared secret and reports dim and model", %{conn: conn} do
    EmbedStub.reply({:ok, %{vectors: [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]], tokens: 7}})
    conn = call(conn, %{"texts" => ["a", "b"]})

    assert json_response(conn, 200) == %{
             "vectors" => [[0.1, 0.2, 0.3], [0.4, 0.5, 0.6]], "tokens" => 7, "dim" => 3, "model" => "multilingual-e5-small"
           }

    assert EmbedStub.calls() == [["a", "b"]]
  end

  test "refuses a missing or wrong secret without embedding", %{conn: conn} do
    assert call(conn, %{"texts" => ["a"]}, "nope").status == 401
    assert post(conn, "/internal/embed", %{"texts" => ["a"]}).status == 401
    assert EmbedStub.calls() == []
  end

  test "rejects bad bodies and over-limit batches before the worker", %{conn: conn} do
    assert json_response(call(build_conn(), %{}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => "a"}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => []}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => [1]}), 400) == %{"error" => "bad_request"}
    assert json_response(call(build_conn(), %{"texts" => List.duplicate("x", 65)}), 413) == %{"error" => "too_many_texts"}
    assert json_response(call(build_conn(), %{"texts" => [String.duplicate("я", 8_001)]}), 413) == %{"error" => "text_too_long"}
    assert EmbedStub.calls() == []
  end

  test "maps worker verdicts", %{conn: conn} do
    EmbedStub.reply({:error, :worker_down})
    assert json_response(call(conn, %{"texts" => ["a"]}), 503) == %{"error" => "worker_down"}
    EmbedStub.reply({:error, :embed_failed})
    assert json_response(call(build_conn(), %{"texts" => ["a"]}), 502) == %{"error" => "embed_failed"}
  end
end
```

- [ ] **Step 3: Run to see them fail**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/embed_controller_test.exs`
Expected: 404 route errors / undefined controller.

- [ ] **Step 4: Controller and route**

```elixir
# apps/druzhok_web/lib/druzhok_web_web/controllers/embed_controller.ex
defmodule DruzhokWebWeb.EmbedController do
  @moduledoc """
  `POST /internal/embed {texts}`: the embedder ruoc-gateway routes
  `POST /v1/embeddings` to. Druzhok owns the model; ruoc owns the price and
  the ledger. No usage row here: the tenant-facing `/v1/embeddings` leg
  records the call.
  """

  use DruzhokWebWeb, :controller
  require Logger

  @max_texts 64
  @max_chars 8_000
  @model "multilingual-e5-small"

  def embed(conn, params) do
    started = System.monotonic_time(:millisecond)

    with {:ok, texts} <- validate(params["texts"]),
         {:ok, %{vectors: vectors, tokens: tokens}} <- embed_module().embed(texts) do
      log(200, started, tokens, length(texts))
      json(conn, %{vectors: vectors, tokens: tokens, dim: length(List.first(vectors) || []), model: @model})
    else
      {:error, :bad_request} -> reply(conn, 400, "bad_request", started)
      {:error, :too_many_texts} -> reply(conn, 413, "too_many_texts", started)
      {:error, :text_too_long} -> reply(conn, 413, "text_too_long", started)
      {:error, :worker_down} -> reply(conn, 503, "worker_down", started)
      {:error, :embed_failed} -> reply(conn, 502, "embed_failed", started)
    end
  end

  defp validate(texts) when is_list(texts) and texts != [] do
    cond do
      not Enum.all?(texts, &is_binary/1) -> {:error, :bad_request}
      length(texts) > @max_texts -> {:error, :too_many_texts}
      Enum.any?(texts, &(String.length(&1) > @max_chars)) -> {:error, :text_too_long}
      true -> {:ok, texts}
    end
  end

  defp validate(_), do: {:error, :bad_request}

  defp embed_module, do: Application.get_env(:druzhok_web, :embed_module, Druzhok.Embed.Worker)

  defp reply(conn, status, code, started) do
    log(status, started, 0, 0, code)
    conn |> put_status(status) |> json(%{error: code})
  end

  defp log(status, started, tokens, count, code \\ nil) do
    latency = System.monotonic_time(:millisecond) - started
    Logger.info("[embed] #{status}#{if code, do: " " <> code} #{count} texts #{tokens} tokens #{latency}ms")
  end
end
```

```elixir
# router.ex — inside scope "/internal"
    post "/embed", EmbedController, :embed
```

Also update the comment above `pipeline :internal_api` to say "The page fetcher and the embedder ruoc-gateway route POST /v1/fetch and POST /v1/embeddings to."

- [ ] **Step 5: Run the tests**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/embed_controller_test.exs`
Expected: 4 pass.

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok_web/lib/druzhok_web_web/controllers/embed_controller.ex apps/druzhok_web/lib/druzhok_web_web/router.ex apps/druzhok_web/test/support/embed_stub.ex apps/druzhok_web/test/druzhok_web_web/controllers/embed_controller_test.exs
git commit -m "add POST /internal/embed for ruoc"
```

### Task 4: Proxy leg `/v1/embeddings` through ruoc

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy/ruoc.ex` (new `embeddings/2` after `fetch/3`)
- Modify: `apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:160-195` (`embeddings/2` body)
- Delete: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/embeddings_test.exs`
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/ruoc/embeddings_test.exs`
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex:60` (card title)

**Interfaces:**
- Consumes: `Druzhok.Ruoc.Client.post/4`, `meter/9`, `relay_headers/3`, `request_id/1`, `log/5`, `error_message/2`, `json_error/4` (all existing in `LlmProxy.Ruoc`).
- Produces: `DruzhokWebWeb.LlmProxy.Ruoc.embeddings(conn, instance) :: Plug.Conn.t()`.

- [ ] **Step 1: Failing tests**

```elixir
# apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/ruoc/embeddings_test.exs
defmodule DruzhokWebWeb.LlmProxy.Ruoc.EmbeddingsTest do
  use DruzhokWebWeb.RuocProxyCase

  @body %{"model" => "ruoc-embed", "input" => ["query: кошка", "passage: кот"]}
  @reply %{
    "object" => "list", "model" => "ruoc-embed",
    "data" => [%{"object" => "embedding", "index" => 0, "embedding" => [0.1, 0.2]}, %{"object" => "embedding", "index" => 1, "embedding" => [0.3, 0.4]}],
    "usage" => %{"prompt_tokens" => 9, "total_tokens" => 9}
  }

  test "forwards model and input with the bot's key and relays the answer", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer " <> bot_key()]
      assert Jason.decode!(raw) == @body
      gateway_reply(req, 200, @reply, "req_emb")
    end)

    conn = post(conn, "/v1/embeddings", Map.put(@body, "encoding_format", "float"))
    assert json_response(conn, 200) == @reply
    assert get_resp_header(conn, "x-ruoc-request-id") == ["req_emb"]
  end

  test "a single string input is forwarded as is", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["input"] == "one"
      gateway_reply(req, 200, @reply)
    end)

    assert post(conn, "/v1/embeddings", %{"model" => "ruoc-embed", "input" => "one"}).status == 200
  end

  test "meters as embedding with the token count, no cost", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> gateway_reply(req, 200, @reply) end)
    post(conn, "/v1/embeddings", @body)

    assert [log] = usage_logs(instance)
    assert log.request_type == "embedding"
    assert log.provider == "ruoc"
    assert log.model == "ruoc-embed"
    assert log.prompt_tokens == 9 and log.completion_tokens == 0 and log.total_tokens == 9
    assert log.cost_cents == 0
    assert log.prompt_preview == "query: кошка"
  end

  test "a bad input is refused before the gateway", %{conn: conn} do
    for body <- [%{"model" => "ruoc-embed"}, %{"input" => [1]}, %{"input" => []}] do
      conn = post(conn, "/v1/embeddings", body)
      assert json_response(conn, 400)["error"]["type"] == "invalid_request_error"
    end
  end

  test "an empty balance relays the 402 unchanged", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> gateway_error(req, 402, "insufficient_quota", "account balance is too low to embed this batch") end)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 402)["error"]["type"] == "insufficient_quota"
    assert usage_logs(instance) == []
  end

  test "other refusals keep status and message", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> gateway_error(req, 413, "invalid_request_error", "too many texts") end)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 413)["error"]["message"] == "too many texts"
  end

  test "an unreachable gateway is a 502", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 502)["error"]["message"] == "embeddings provider unavailable"
  end
end
```

Delete the old file: `git rm apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/embeddings_test.exs`.

- [ ] **Step 2: Run to see them fail**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/ruoc/embeddings_test.exs`
Expected: failures (requests go to the OpenRouter path, Bypass expectations unmet).

- [ ] **Step 3: Implement the leg**

```elixir
# llm_proxy/ruoc.ex — add after fetch/3, before "# --- Images"
  # --- Embeddings ------------------------------------------------------------

  @embed_timeout 30_000

  @doc """
  OpenAI `embeddings` in and out, over ruoc `POST /v1/embeddings`. Only
  `model` and `input` travel; the answer comes back unchanged, including a
  402, which Mnemosyne treats as a permanent failure for that batch and
  falls back to FTS recall.
  """
  def embeddings(conn, instance) do
    body = conn.body_params
    started_at = System.monotonic_time(:millisecond)

    case embed_input(body["input"]) do
      :error ->
        json_error(conn, 400, "input must be a non-empty string or list of strings", "invalid_request_error")

      {:ok, input} ->
        request = %{"model" => body["model"] || "ruoc-embed", "input" => input}

        case Client.post("/v1/embeddings", instance.ruoc_api_key, Jason.encode!(request), receive_timeout: @embed_timeout) do
          {:ok, 200, headers, resp_body} ->
            request_id = request_id(headers)
            usage = usage_of(resp_body)
            meter(instance, "embedding", "ruoc-embed", usage, started_at, nil, nil, request_id, preview_of(input))

            conn |> relay_headers(headers, request_id) |> send_resp(200, resp_body)

          {:ok, status, headers, resp_body} ->
            request_id = request_id(headers)
            log(instance, "embedding", request_id, started_at, "HTTP #{status}")
            conn |> relay_headers(headers, request_id) |> send_resp(status, resp_body)

          {:error, reason} ->
            Logger.error("[ruoc] #{instance.name} embeddings unreachable: #{inspect(reason)}")
            json_error(conn, 502, "embeddings provider unavailable", "server_error")
        end
    end
  end

  defp embed_input(input) when is_binary(input) and input != "", do: {:ok, input}
  defp embed_input([_ | _] = input), do: if(Enum.all?(input, &is_binary/1), do: {:ok, input}, else: :error)
  defp embed_input(_), do: :error

  defp preview_of(input) when is_binary(input), do: String.slice(input, 0, 200)
  defp preview_of([first | _]), do: String.slice(first, 0, 200)

  defp usage_of(resp_body) do
    case Jason.decode(resp_body) do
      {:ok, %{"usage" => %{"prompt_tokens" => n}}} when is_integer(n) -> %{prompt_tokens: n, completion_tokens: 0}
      _ -> @no_usage
    end
  end
```

Replace the controller action body:

```elixir
# llm_proxy_controller.ex
  def embeddings(conn, _params), do: RuocProxy.embeddings(conn, conn.assigns.instance)
```

Remove the now-unused OpenRouter embeddings code in that function (the whole old body). Change the settings card title to `"OpenRouter (image generation, /v1/responses)"`.

- [ ] **Step 4: Run the tests and the whole web suite**

Run: `mix test apps/druzhok_web`
Expected: all pass. If `LlmFormat` or the moduledoc mention embeddings on OpenRouter, update the wording (`llm_format.ex:4`).

- [ ] **Step 5: Commit**

```bash
git add -A apps/druzhok_web
git commit -m "route /v1/embeddings through ruoc"
```

### Task 5: `memory_provider` on instances

**Files:**
- Create: `apps/druzhok/priv/repo/migrations/20260906000001_add_memory_provider_to_instances.exs`
- Modify: `apps/druzhok/lib/druzhok/instance.ex:6-40`
- Test: `apps/druzhok/test/druzhok/instance_test.exs` (create)

**Interfaces:**
- Produces: `instances.memory_provider :string, default "builtin"`, values `"builtin" | "mnemosyne"`; `Druzhok.Instance.memory_providers/0 :: ["builtin", "mnemosyne"]`.

- [ ] **Step 1: Failing test**

```elixir
# apps/druzhok/test/druzhok/instance_test.exs
defmodule Druzhok.InstanceTest do
  use Druzhok.DataCase, async: true

  alias Druzhok.Instance

  @base %{name: "memtest", model: "ruoc-flash", workspace: "/tmp/x"}

  test "memory_provider defaults to builtin and accepts mnemosyne" do
    assert Instance.changeset(%Instance{}, @base).changes[:memory_provider] == nil
    assert %Instance{memory_provider: "builtin"} = %Instance{}
    assert Instance.changeset(%Instance{}, Map.put(@base, :memory_provider, "mnemosyne")).valid?
  end

  test "an unknown memory_provider is rejected" do
    cs = Instance.changeset(%Instance{}, Map.put(@base, :memory_provider, "hindsight"))
    refute cs.valid?
    assert {"is invalid", _} = cs.errors[:memory_provider]
  end

  test "memory_providers lists the two values in order" do
    assert Instance.memory_providers() == ["builtin", "mnemosyne"]
  end
end
```

If `Druzhok.DataCase` does not exist, use `use ExUnit.Case, async: true` (the tests do not touch the database).

- [ ] **Step 2: Run to see it fail**

Run: `mix test apps/druzhok/test/druzhok/instance_test.exs`
Expected: FAIL, unknown field / undefined function.

- [ ] **Step 3: Migration, field, validation**

```elixir
# apps/druzhok/priv/repo/migrations/20260906000001_add_memory_provider_to_instances.exs
defmodule Druzhok.Repo.Migrations.AddMemoryProviderToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :memory_provider, :string, null: false, default: "builtin"
    end
  end
end
```

```elixir
# instance.ex — schema
    field :memory_provider, :string, default: "builtin"

# instance.ex — after the schema block
  @memory_providers ~w(builtin mnemosyne)
  def memory_providers, do: @memory_providers

# changeset: add :memory_provider to the cast list and, after validate_required:
    |> validate_inclusion(:memory_provider, @memory_providers)
```

Run `mix ecto.migrate && MIX_ENV=test mix ecto.migrate`.

- [ ] **Step 4: Run the tests**

Run: `mix test apps/druzhok/test/druzhok/instance_test.exs`
Expected: 3 pass.

- [ ] **Step 5: Commit**

```bash
git add apps/druzhok/priv/repo/migrations/20260906000001_add_memory_provider_to_instances.exs apps/druzhok/lib/druzhok/instance.ex apps/druzhok/test/druzhok/instance_test.exs
git commit -m "add memory_provider to instances"
```

### Task 6: `Runtime.Hermes` memory block and env vars

**Files:**
- Modify: `apps/druzhok/lib/druzhok/runtime/hermes.ex` (`env_vars/1` ~82-136, `sync_config/2` ~170, `sync_memory_block/1` ~539-550)
- Test: `apps/druzhok/test/druzhok/runtime/hermes_test.exs` (add to `describe "env_vars/1"` and the `sync_config` describe that holds "forces builtin provider...")
- Test: `apps/druzhok/test/druzhok/host/systemd_test.exs` (one assertion)

**Interfaces:**
- Consumes: `instance.memory_provider` (Task 5; absent key means `"builtin"`).
- Produces: `Hermes.env_vars/1` with the nine `MNEMOSYNE_*` keys when the provider is `mnemosyne` and none otherwise; `sync_config/2` writing `provider: <value>` and the `mnemosyne:` flow-mapping line.

- [ ] **Step 1: Failing tests**

Add inside `describe "env_vars/1"`:

```elixir
    test "a builtin bot gets no MNEMOSYNE_ keys" do
      refute Hermes.env_vars(@instance) |> Map.keys() |> Enum.any?(&String.starts_with?(&1, "MNEMOSYNE_"))
    end

    test "a mnemosyne bot points the provider at the proxy with e5 prefixes and no LLM" do
      env = Hermes.env_vars(Map.put(@instance, :memory_provider, "mnemosyne"))
      assert env["MNEMOSYNE_DATA_DIR"] == Path.join(Druzhok.Runtime.data_root(@instance), "mnemosyne")
      assert env["MNEMOSYNE_EMBEDDING_API_URL"] == Druzhok.Runtime.proxy_url()
      assert env["MNEMOSYNE_EMBEDDING_API_KEY"] == "dk-alice-token"
      assert env["MNEMOSYNE_EMBEDDING_MODEL"] == "ruoc-embed"
      assert env["MNEMOSYNE_EMBEDDING_DIM"] == "384"
      assert env["MNEMOSYNE_EMBEDDING_QUERY_PREFIX"] == "query: "
      assert env["MNEMOSYNE_EMBEDDING_DOC_PREFIX"] == "passage: "
      assert env["MNEMOSYNE_LLM_ENABLED"] == "false"
      assert env["MNEMOSYNE_HOST_LLM_ENABLED"] == "false"
    end
```

`Druzhok.Runtime.data_root/1`: check the name of the function `Runtime.Hermes.data_root/1` delegates to (`grep -n "def data_root" apps/druzhok/lib/druzhok/runtime*.ex apps/druzhok/lib/druzhok/runtime/*.ex`) and use whichever is public; if only the private one exists in `Runtime.Hermes`, assert `String.ends_with?(env["MNEMOSYNE_DATA_DIR"], "/alice/mnemosyne")` instead.

Add to the `sync_config` describe next to "forces builtin provider and legacy memory on":

```elixir
    test "switches the memory block to mnemosyne with the three tools, builtin flags still on", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      model:
        default: "x"
      memory:
        provider: builtin
        memory_enabled: true
        user_profile_enabled: true
        memory_char_limit: 999
      """)

      inst = %{name: "b", model: "x", tenant_key: "k", memory_provider: "mnemosyne"}
      assert :ok = Hermes.sync_config(inst, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  provider: mnemosyne$/m
      assert content =~ ~r/^  memory_enabled: true$/m
      assert content =~ ~r/^  user_profile_enabled: true$/m
      assert content =~ ~r/^  mnemosyne: \{tools: \[mnemosyne_remember, mnemosyne_recall, mnemosyne_forget\]\}$/m
      assert content =~ ~r/^  memory_char_limit: 999$/m
      assert YamlElixir.read_from_string!(content)["memory"]["mnemosyne"]["tools"] == ~w(mnemosyne_remember mnemosyne_recall mnemosyne_forget)

      # Idempotent: a second sync changes nothing.
      assert :ok = Hermes.sync_config(inst, tmp_dir)
      assert File.read!(Path.join(tmp_dir, "config.yaml")) == content
    end

    test "switching back to builtin drops the mnemosyne block hermes may have re-dumped as a mapping", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      memory:
        provider: mnemosyne
        memory_enabled: true
        user_profile_enabled: true
        mnemosyne:
          tools:
          - mnemosyne_remember
          - mnemosyne_recall
        memory_char_limit: 999
      """)

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k", memory_provider: "builtin"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert content =~ ~r/^  provider: builtin$/m
      refute content =~ "mnemosyne"
      assert content =~ ~r/^  memory_char_limit: 999$/m
    end

    test "a re-dumped mnemosyne mapping is replaced, not doubled", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "config.yaml"), """
      memory:
        provider: mnemosyne
        mnemosyne:
          tools:
          - mnemosyne_remember
        memory_enabled: true
      """)

      assert :ok = Hermes.sync_config(%{name: "b", model: "x", tenant_key: "k", memory_provider: "mnemosyne"}, tmp_dir)
      content = File.read!(Path.join(tmp_dir, "config.yaml"))
      assert length(Regex.scan(~r/mnemosyne:/, content)) == 1
      assert YamlElixir.read_from_string!(content)["memory"]["mnemosyne"]["tools"] == ~w(mnemosyne_remember mnemosyne_recall mnemosyne_forget)
    end
```

If `yaml_elixir` is not a dependency (`grep yaml_elixir mix.lock`), drop the two `YamlElixir` assertions; the regex ones cover the shape.

Add to `apps/druzhok/test/druzhok/host/systemd_test.exs`:

```elixir
  test "env_file keeps a trailing space inside the quotes" do
    assert Systemd.env_file(%{"MNEMOSYNE_EMBEDDING_QUERY_PREFIX" => "query: "}) == ~s(MNEMOSYNE_EMBEDDING_QUERY_PREFIX="query: "\n)
  end
```

- [ ] **Step 2: Run to see them fail**

Run: `mix test apps/druzhok/test/druzhok/runtime/hermes_test.exs apps/druzhok/test/druzhok/host/systemd_test.exs`
Expected: the new env and sync tests fail; the env_file one passes already (keep it).

- [ ] **Step 3: Implement**

In `env_vars/1`, replace the closing `}` of the map with `} |> Map.merge(mnemosyne_env(instance))` and add:

```elixir
  # Mnemosyne memory provider (docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md):
  # embeddings go to the proxy's /v1/embeddings with the tenant key, e5 needs
  # its two prefixes (trailing space included), and LLM consolidation stays
  # off. `MNEMOSYNE_DATA_DIR` keeps the SQLite bank inside the tenant dir.
  defp mnemosyne_env(instance) do
    if memory_provider(instance) == "mnemosyne" do
      %{
        "MNEMOSYNE_DATA_DIR" => Path.join(data_root(instance), "mnemosyne"),
        "MNEMOSYNE_EMBEDDING_API_URL" => Druzhok.Runtime.proxy_url(),
        "MNEMOSYNE_EMBEDDING_API_KEY" => Map.get(instance, :tenant_key, "") || "",
        "MNEMOSYNE_EMBEDDING_MODEL" => "ruoc-embed",
        "MNEMOSYNE_EMBEDDING_DIM" => "384",
        "MNEMOSYNE_EMBEDDING_QUERY_PREFIX" => "query: ",
        "MNEMOSYNE_EMBEDDING_DOC_PREFIX" => "passage: ",
        "MNEMOSYNE_LLM_ENABLED" => "false",
        "MNEMOSYNE_HOST_LLM_ENABLED" => "false"
      }
    else
      %{}
    end
  end

  defp memory_provider(instance) do
    case Map.get(instance, :memory_provider) do
      "mnemosyne" -> "mnemosyne"
      _ -> "builtin"
    end
  end
```

Change `|> sync_memory_block()` in `sync_config/2` to `|> sync_memory_block(instance)` and replace the function:

```elixir
  # Druzhok owns `memory.provider` (builtin, or mnemosyne when the bot's
  # memory_provider says so); legacy MEMORY.md/USER.md memory stays on in
  # both cases (hermes runs one external provider alongside builtin).
  # Char-limit fields are left alone so user edits survive.
  #
  # The mnemosyne sub-block is written as a flow mapping on one line. Hermes
  # re-dumps config.yaml at runtime as a block mapping, so any existing
  # `mnemosyne:` key is dropped with its body first and re-added; otherwise
  # the one-line upsert would leave the old nested lines dangling.
  @mnemosyne_tools ~w(mnemosyne_remember mnemosyne_recall mnemosyne_forget)

  defp sync_memory_block(content, instance) do
    provider = memory_provider(instance)

    sync_yaml_block(content, "memory",
      upsert: fn body ->
        body =
          body
          |> String.split("\n")
          |> drop_owned_keys(["mnemosyne"])
          |> Enum.join("\n")
          |> upsert_indented_line("provider", provider)
          |> upsert_indented_line("memory_enabled", "true")
          |> upsert_indented_line("user_profile_enabled", "true")

        if provider == "mnemosyne",
          do: "  mnemosyne: {tools: [#{Enum.join(@mnemosyne_tools, ", ")}]}\n" <> body,
          else: body
      end,
      default: default_memory_block(provider)
    )
  end

  defp default_memory_block(provider) do
    mnemosyne = if provider == "mnemosyne", do: "\n  mnemosyne: {tools: [#{Enum.join(@mnemosyne_tools, ", ")}]}", else: ""

    """
    memory:
      provider: #{provider}
      memory_enabled: true
      user_profile_enabled: true#{mnemosyne}
      memory_char_limit: 2200
      user_char_limit: 1375\
    """
  end
```

`build_config_yaml/1` (line ~866) also emits a memory block for a fresh data root; leave it on `builtin` (sync_config runs on every start and corrects it).

- [ ] **Step 4: Run the tests**

Run: `mix test apps/druzhok/test/druzhok/runtime apps/druzhok/test/druzhok/host`
Expected: all pass, including the idempotency check.

- [ ] **Step 5: Commit**

```bash
git add apps/druzhok/lib/druzhok/runtime/hermes.ex apps/druzhok/test/druzhok/runtime/hermes_test.exs apps/druzhok/test/druzhok/host/systemd_test.exs
git commit -m "write mnemosyne memory config and env for flagged bots"
```

### Task 7: Settings tab Memory card

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/components/settings_tab.ex` (the empty "Card: Memory" at ~205-208, and a `handle_event` next to `set_image_gen_model` ~385)
- Test: `apps/druzhok_web/test/druzhok_web_web/live/settings_tab_test.exs`

**Interfaces:**
- Consumes: `Instance.memory_providers/0` (Task 5), `update_instance/2`, `restart_bot/1`, `notify_parent/1` (existing private helpers in the component).

- [ ] **Step 1: Failing test**

```elixir
  test "the memory card switches the provider and restarts a running bot only", %{conn: conn} do
    inst = create_instance(%{active: false, ruoc_account_id: "acct-77", ruoc_api_key: "ruoc_bot77", model: "ruoc-flash"})
    {:ok, view, _} = live(conn, "/instances/#{inst.name}")

    html = render(view)
    assert html =~ "Memory provider"
    assert html =~ ~s(<option value="builtin" selected)
    assert html =~ ~s(<option value="mnemosyne")

    view |> element("form[phx-change=set_memory_provider]") |> render_change(%{"memory_provider" => "mnemosyne"})
    assert Repo.get_by!(Instance, name: inst.name).memory_provider == "mnemosyne"
    Process.sleep(100)
    refute Repo.get_by!(Instance, name: inst.name).active

    view |> element("form[phx-change=set_memory_provider]") |> render_change(%{"memory_provider" => "builtin"})
    assert Repo.get_by!(Instance, name: inst.name).memory_provider == "builtin"
    stop(view)
  end
```

- [ ] **Step 2: Run to see it fail**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/live/settings_tab_test.exs`
Expected: FAIL, "Memory provider" not rendered.

- [ ] **Step 3: Implement**

Replace the empty Memory card:

```heex
          <%!-- Card: Memory --%>
          <div class="bg-raised/50 border border-line rounded-lg p-3 space-y-2.5">
            <h3 class="label">Memory</h3>
            <form phx-change="set_memory_provider" phx-target={@myself}>
              <label class="block text-[10px] text-muted mb-0.5">Memory provider</label>
              <select name="memory_provider" class="w-full border border-line2 rounded px-2 py-1 text-xs">
                <%= for p <- Druzhok.Instance.memory_providers() do %>
                  <option value={p} selected={p == (@instance[:memory_provider] || "builtin")}><%= memory_provider_label(p) %></option>
                <% end %>
              </select>
              <p class="text-[10px] text-muted mt-1">builtin: MEMORY.md / USER.md only. mnemosyne: adds recall of past turns (embeddings via ruoc). Applies on restart.</p>
            </form>
          </div>
```

```elixir
  # Restart: hermes reads memory.provider and the MNEMOSYNE_* env at start.
  def handle_event("set_memory_provider", %{"memory_provider" => provider}, socket) when is_binary(provider) do
    name = socket.assigns.instance.name

    if provider in Druzhok.Instance.memory_providers() do
      update_instance(name, %{memory_provider: provider})
      if socket.assigns.instance[:active], do: restart_bot(name)
    end

    notify_parent(socket)
    {:noreply, socket}
  end

  defp memory_provider_label("builtin"), do: "builtin (MEMORY.md)"
  defp memory_provider_label("mnemosyne"), do: "mnemosyne (episodic + builtin)"
```

Check how `@instance` is built for the component (whether it is a map with atom keys carrying `memory_provider`); if the parent LiveView selects fields explicitly, add `memory_provider` there (`grep -n "image_gen_model" apps/druzhok_web/lib/druzhok_web_web/live/*.ex`).

- [ ] **Step 4: Run the tests**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/live/settings_tab_test.exs`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add apps/druzhok_web
git commit -m "settings tab: memory provider select"
```

### Task 8: Ops, docs and the eval corpus

**Files:**
- Modify: `ops/bootstrap.sh:60-64` (add the embed venv + model + env keys after the fetch worker step)
- Modify: `CLAUDE.md` (proxy table row for `/v1/embeddings`, layout line)
- Create: `ops/embed-eval/corpus.py`, `ops/embed-eval/eval.py`, `ops/embed-eval/README.md`

**Interfaces:**
- Produces: env keys `EMBED_WORKER_BIN=/opt/druzhok-embed/.venv/bin/python`, `EMBED_MODEL_DIR=/data/opt/embed-models/multilingual-e5-small` in `/etc/druzhok/druzhok.env`.

- [ ] **Step 1: bootstrap.sh**

After the fetch worker step add:

```bash
step "embed worker venv + model (multilingual-e5-small for Mnemosyne memory)"
python3 -m venv /opt/druzhok-embed/.venv
/opt/druzhok-embed/.venv/bin/pip install -q -r "$OPS/../apps/druzhok/priv/embed-worker/requirements.txt"
mkdir -p /data/opt/embed-models
"$OPS/embed-model-fetch.sh" /data/opt/embed-models/multilingual-e5-small
chmod -R a+rX /data/opt/embed-models
grep -q '^EMBED_WORKER_BIN=' /etc/druzhok/druzhok.env 2>/dev/null || echo 'EMBED_WORKER_BIN=/opt/druzhok-embed/.venv/bin/python' >> /etc/druzhok/druzhok.env
grep -q '^EMBED_MODEL_DIR=' /etc/druzhok/druzhok.env 2>/dev/null || echo 'EMBED_MODEL_DIR=/data/opt/embed-models/multilingual-e5-small' >> /etc/druzhok/druzhok.env
```

- [ ] **Step 2: Eval corpus with an endpoint mode**

Copy the scratchpad `corpus.py` (120 memories, 84 queries) to `ops/embed-eval/corpus.py` unchanged. Write `ops/embed-eval/eval.py` so it scores an HTTP endpoint instead of loading models:

```python
"""Scores /internal/embed on a Russian memory corpus: R@1, R@5, MRR, hard-negative wins.
Usage: python3 ops/embed-eval/eval.py http://127.0.0.1:4000 <FETCH_SECRET>
Needs only the standard library."""
import json, sys, urllib.request
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
```

`ops/embed-eval/README.md`: three lines saying what it is, the expected numbers for fp32 e5-small (R@1 0.80, R@5 0.95, MRR 0.87) and that the int8 model may replace fp32 only if R@5 stays within 0.02.

- [ ] **Step 3: Run the eval locally against the dev server**

```bash
DATABASE_PATH=data/druzhok.db mix phx.server &   # separate terminal is fine
# set a fetch secret once in the dashboard Settings page or:
DATABASE_PATH=data/druzhok.db mix run -e 'Druzhok.Settings.set("fetch_secret", "dev-secret")'
python3 ops/embed-eval/eval.py http://127.0.0.1:4000 dev-secret
```

Expected: `R@1=0.80 R@5=0.95 MRR=0.87` within a point or two.

- [ ] **Step 4: CLAUDE.md**

Change the `/v1/embeddings` row of the proxy table to:

```
| `POST /v1/embeddings` | ruoc-gateway `/v1/embeddings` (kind `embedding`, `ruoc-embed`, per 1M input tokens, free at launch) → druzhok `POST /internal/embed` (same `FETCH_SECRET`) → `Druzhok.Embed.Worker` + Python ONNX worker (`EMBED_WORKER_BIN`, `EMBED_MODEL_DIR`, multilingual-e5-small). Used by the Mnemosyne memory provider (`instances.memory_provider`), spec `docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md` |
```

and take `/v1/embeddings` out of the OpenRouter row.

- [ ] **Step 5: Commit**

```bash
git add ops/bootstrap.sh ops/embed-eval CLAUDE.md
git commit -m "ops: embed worker bootstrap, eval corpus, docs"
```

---

## Part B: ruoc-gateway (`~/Documents/ruoc-gateway`, Go)

Run Go tests with the throwaway database only:

```bash
export TEST_DATABASE_URL="$(grep -o '^TEST_DATABASE_URL=.*' ~/Documents/ruoc-gateway/.env | cut -d= -f2- | tr -d '"')"
```

Never source `.env` as a whole. Commit in the ruoc repo with the same short-subject, no-trailer rule.

### Task 9: Catalogue kind `embedding`

**Files:**
- Modify: `internal/catalog/model.go` (kinds block, service ids)
- Modify: `internal/catalog/pricing.go` (`UnitKindsFor`)
- Modify: `internal/store/catalog.go` (`LoadEmbed`)
- Test: `internal/catalog/pricing_test.go`, `internal/store/embed_test.go` (create)

**Interfaces:**
- Produces: `catalog.KindEmbedding = "embedding"`, `catalog.EmbedServiceID = "ruoc-embed"`, `UnitKindsFor(KindEmbedding) == []UnitKind{InputTokens}`, `(*store.Store).LoadEmbed(ctx) (catalog.Model, error)`.

- [ ] **Step 1: Failing tests**

Append to `internal/catalog/pricing_test.go`:

```go
func TestEmbeddingKindBillsInputTokensPerMillion(t *testing.T) {
	if got := UnitKindsFor(KindEmbedding); len(got) != 1 || got[0] != InputTokens {
		t.Fatalf("UnitKindsFor(KindEmbedding) = %v", got)
	}
	if BasisFor(KindEmbedding) != BasisPerMillion {
		t.Fatalf("basis: %s", BasisFor(KindEmbedding))
	}
	if BillableOn(KindEmbedding, OutputTokens) || BillableOn(KindEmbedding, WebSearches) || BillableOn(KindEmbedding, PageFetches) {
		t.Fatal("an embedding entry must only take an input-token rate")
	}
	if EmbedServiceID != "ruoc-embed" {
		t.Fatalf("EmbedServiceID = %q", EmbedServiceID)
	}
}
```

Create `internal/store/embed_test.go`:

```go
package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ruoc/gateway/internal/catalog"
	"github.com/ruoc/gateway/internal/money"
)

// seedEmbedService creates the embedding entry routed to druzhok at a
// per-million input-token rate (nanorub per token).
func seedEmbedService(t *testing.T, s *Store, perToken money.Nanorub) {
	t.Helper()
	ctx := context.Background()
	if err := s.UpsertModel(ctx, ModelInput{
		ID: catalog.EmbedServiceID, DisplayName: "Text embeddings", Kind: catalog.KindEmbedding,
	}); err != nil {
		t.Fatalf("UpsertModel: %v", err)
	}
	if err := s.AddRoute(ctx, catalog.EmbedServiceID, "druzhok", "embed", 1); err != nil {
		t.Fatalf("AddRoute: %v", err)
	}
	if err := s.SetPrice(ctx, catalog.EmbedServiceID, catalog.InputTokens, perToken, time.Now().Add(-time.Hour)); err != nil {
		t.Fatalf("SetPrice: %v", err)
	}
}

func TestEmbedEntryLoadsAtZeroAndIsKeptApart(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	seedEmbedService(t, s, 0)

	entry, err := s.LoadEmbed(ctx)
	if err != nil {
		t.Fatalf("LoadEmbed: %v", err)
	}
	if entry.Kind != catalog.KindEmbedding || len(entry.Routes) != 1 || entry.Routes[0].Upstream != "druzhok" {
		t.Fatalf("entry: %+v", entry)
	}
	if rate, priced := catalog.RateAt(entry.Prices, catalog.InputTokens, time.Now()); !priced || rate != 0 {
		t.Fatalf("rate %v priced %v", rate, priced)
	}
	if _, err := s.LoadModel(ctx, catalog.EmbedServiceID); !errors.Is(err, ErrUnknownModel) {
		t.Fatalf("an embedding entry must not load as a model: %v", err)
	}
	if _, err := s.LoadFetch(ctx); !errors.Is(err, ErrUnknownModel) {
		t.Fatalf("no fetch entry was seeded: %v", err)
	}
	models, err := s.ListModels(ctx)
	if err != nil {
		t.Fatalf("ListModels: %v", err)
	}
	for _, m := range models {
		if m.ID == catalog.EmbedServiceID {
			t.Fatal("the embedding entry must not be listed as a model")
		}
	}
}
```

If the store's model-listing function has another name (`grep -n "func (s \*Store) List" internal/store/catalog.go`), use that one.

- [ ] **Step 2: Run to see them fail**

Run: `cd ~/Documents/ruoc-gateway && go test ./internal/catalog/ ./internal/store/ -run 'Embed'`
Expected: compile errors, undefined `KindEmbedding`, `EmbedServiceID`, `LoadEmbed`.

- [ ] **Step 3: Implement**

`internal/catalog/model.go`, in the kinds `const` block after `KindFetch`:

```go
	// KindEmbedding is the text-embedding unit sold through POST /v1/embeddings.
	// One entry, priced per million input tokens like a model's input line,
	// but its own kind so it never reaches GET /v1/models and never takes a
	// per-call rate.
	KindEmbedding = "embedding"
```

After `FetchServiceID`:

```go
// EmbedServiceID is the catalogue entry POST /v1/embeddings bills against, a
// constant for the reason FetchServiceID is one.
const EmbedServiceID = "ruoc-embed"
```

`internal/catalog/pricing.go`, in `UnitKindsFor` before `default`:

```go
	case KindEmbedding:
		// Input tokens only: an embedding has no output line, and BillableOn
		// must refuse one so a console reprice cannot attach it.
		return []UnitKind{InputTokens}
```

`internal/store/catalog.go`, after `LoadFetch`:

```go
// LoadEmbed returns the enabled embedding entry with its route and per-token
// price, refusing every other kind for the reason LoadModel refuses a service.
func (s *Store) LoadEmbed(ctx context.Context) (catalog.Model, error) {
	return s.loadEntry(ctx, catalog.EmbedServiceID, catalog.KindEmbedding)
}
```

Update the `ModelInput.Kind` comment to list `catalog.KindEmbedding` too.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/catalog/ ./internal/store/`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add internal/catalog internal/store
git commit -m "catalog: embedding kind priced per input token"
```

### Task 10: `upstream.Embedder` and the druzhok adapter

**Files:**
- Create: `internal/upstream/embed.go`
- Create: `internal/upstream/embed_test.go`

**Interfaces:**
- Produces:

```go
type Embedder interface { Embed(ctx context.Context, req EmbedRequest) (EmbedResult, error) }
type EmbedRequest struct { Texts []string }
type EmbedResult struct { Vectors [][]float32; Tokens int64; Dim int }
var ErrEmbedderUnavailable, ErrBadEmbedInput error
func NewDruzhokEmbedder(baseURL, secret string, timeout time.Duration) *DruzhokEmbedder
```

- [ ] **Step 1: Failing tests**

```go
// internal/upstream/embed_test.go
package upstream

import (
	"context"
	"errors"
	"testing"
	"time"
)

func newEmbedderForTest(t *testing.T, f *fakeDruzhok) *DruzhokEmbedder {
	t.Helper()
	return NewDruzhokEmbedder(f.server(t).URL, "shared-secret", 5*time.Second)
}

func TestEmbedPostsTextsWithTheSecretAndDecodesVectors(t *testing.T) {
	fake := &fakeDruzhok{reply: `{"vectors":[[0.1,0.2],[0.3,0.4]],"tokens":7,"dim":2,"model":"multilingual-e5-small"}`}
	got, err := newEmbedderForTest(t, fake).Embed(context.Background(), EmbedRequest{Texts: []string{"a", "b"}})
	if err != nil {
		t.Fatalf("Embed: %v", err)
	}
	if got.Tokens != 7 || got.Dim != 2 || len(got.Vectors) != 2 || got.Vectors[1][1] != 0.4 {
		t.Fatalf("got %+v", got)
	}
	if fake.path != "/internal/embed" || fake.auth != "Bearer shared-secret" {
		t.Fatalf("path %q auth %q", fake.path, fake.auth)
	}
	texts, _ := fake.body["texts"].([]any)
	if len(texts) != 2 || texts[0] != "a" {
		t.Fatalf("body: %v", fake.body)
	}
}

func TestEmbedMapsDruzhokVerdicts(t *testing.T) {
	cases := []struct {
		status int
		reply  string
		want   error
	}{
		{503, `{"error":"worker_down"}`, ErrEmbedderUnavailable},
		{502, `{"error":"embed_failed"}`, ErrEmbedderUnavailable},
		{413, `{"error":"too_many_texts"}`, ErrBadEmbedInput},
		{400, `{"error":"bad_request"}`, ErrBadEmbedInput},
	}
	for _, c := range cases {
		fake := &fakeDruzhok{status: c.status, reply: c.reply}
		_, err := newEmbedderForTest(t, fake).Embed(context.Background(), EmbedRequest{Texts: []string{"a"}})
		if !errors.Is(err, c.want) {
			t.Fatalf("status %d: got %v want %v", c.status, err, c.want)
		}
	}
	fake := &fakeDruzhok{status: 500, reply: `oops`}
	if _, err := newEmbedderForTest(t, fake).Embed(context.Background(), EmbedRequest{Texts: []string{"a"}}); err == nil ||
		errors.Is(err, ErrEmbedderUnavailable) || errors.Is(err, ErrBadEmbedInput) {
		t.Fatalf("a 500 is our problem, untyped: %v", err)
	}
}

func TestEmbedRefusesAnAnswerWithTheWrongCount(t *testing.T) {
	fake := &fakeDruzhok{reply: `{"vectors":[[0.1]],"tokens":3,"dim":1}`}
	if _, err := newEmbedderForTest(t, fake).Embed(context.Background(), EmbedRequest{Texts: []string{"a", "b"}}); err == nil {
		t.Fatal("two texts, one vector must be an error")
	}
}
```

- [ ] **Step 2: Run to see them fail**

Run: `go test ./internal/upstream/ -run Embed`
Expected: compile errors.

- [ ] **Step 3: Implement**

```go
// internal/upstream/embed.go
package upstream

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// maxEmbedBody bounds one embedder reply: 64 vectors of 384 floats as JSON
// is under 400 KiB; 8 MiB leaves room for a larger model later.
const maxEmbedBody = 8 << 20

// Embedder turns texts into vectors. Its own interface for the reason
// Fetcher has one: one bounded request, one bounded answer, metered from
// the token count the embedder reports.
type Embedder interface {
	Embed(ctx context.Context, req EmbedRequest) (EmbedResult, error)
}

// EmbedRequest is one batch.
type EmbedRequest struct {
	Texts []string
}

// EmbedResult carries one unit vector per text, in order, and the number of
// tokens actually embedded after truncation — the billable quantity.
type EmbedResult struct {
	Vectors [][]float32
	Tokens  int64
	Dim     int
}

var (
	// ErrEmbedderUnavailable: the embedder is down or failed on this batch.
	// Transient; unpaid; a retry may pass.
	ErrEmbedderUnavailable = errors.New("embed: embedder unavailable")
	// ErrBadEmbedInput: the embedder refused the batch (too many texts, a text
	// too long, not strings). Deterministic; the handler answers 4xx.
	ErrBadEmbedInput = errors.New("embed: bad input")
)

// DruzhokEmbedder calls druzhok's internal embedder, which owns the model.
// It authenticates with the shared secret; the tenant's ruoc key never travels.
type DruzhokEmbedder struct {
	baseURL string
	secret  string
	client  *http.Client
}

// NewDruzhokEmbedder builds the adapter with a client-level timeout.
func NewDruzhokEmbedder(baseURL, secret string, timeout time.Duration) *DruzhokEmbedder {
	return &DruzhokEmbedder{baseURL: baseURL, secret: secret, client: &http.Client{Timeout: timeout}}
}

// Embed runs one batch.
func (e *DruzhokEmbedder) Embed(ctx context.Context, in EmbedRequest) (EmbedResult, error) {
	body, err := json.Marshal(map[string][]string{"texts": in.Texts})
	if err != nil {
		return EmbedResult{}, fmt.Errorf("upstream embed: encode: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, e.baseURL+"/internal/embed", bytes.NewReader(body))
	if err != nil {
		return EmbedResult{}, fmt.Errorf("upstream embed: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+e.secret)

	resp, err := e.client.Do(req)
	if err != nil {
		return EmbedResult{}, fmt.Errorf("%w: %v", ErrEmbedderUnavailable, err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxEmbedBody+1))
	if err != nil {
		return EmbedResult{}, fmt.Errorf("upstream embed: read: %w", err)
	}
	if len(raw) > maxEmbedBody {
		return EmbedResult{}, fmt.Errorf("upstream embed: response exceeds %d bytes", maxEmbedBody)
	}

	switch resp.StatusCode {
	case http.StatusOK:
		var reply struct {
			Vectors [][]float32 `json:"vectors"`
			Tokens  int64       `json:"tokens"`
			Dim     int         `json:"dim"`
		}
		if err := json.Unmarshal(raw, &reply); err != nil {
			return EmbedResult{}, fmt.Errorf("upstream embed: decode: %w", err)
		}
		if len(reply.Vectors) != len(in.Texts) {
			return EmbedResult{}, fmt.Errorf("upstream embed: %d texts, %d vectors", len(in.Texts), len(reply.Vectors))
		}
		return EmbedResult{Vectors: reply.Vectors, Tokens: reply.Tokens, Dim: reply.Dim}, nil
	case http.StatusBadRequest, http.StatusRequestEntityTooLarge:
		return EmbedResult{}, ErrBadEmbedInput
	case http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
		return EmbedResult{}, fmt.Errorf("%w: status %d", ErrEmbedderUnavailable, resp.StatusCode)
	default:
		return EmbedResult{}, fmt.Errorf("upstream embed: status %d", resp.StatusCode)
	}
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/upstream/`
Expected: pass.

- [ ] **Step 5: Commit**

```bash
git add internal/upstream/embed.go internal/upstream/embed_test.go
git commit -m "upstream: druzhok embedder"
```

### Task 11: `POST /v1/embeddings`

**Files:**
- Create: `internal/httpapi/embed.go`
- Create: `internal/httpapi/embed_test.go`
- Modify: `internal/httpapi/server.go` (Config fields + Defaults + Server fields + New), `internal/httpapi/hosts.go` (route)
- Modify: `internal/config/config.go` (`EMBED_BURST`, `EMBED_INTERVAL`)
- Modify: `cmd/ruocd/main.go` (build embedders from `cfg.Fetchers`, `WithEmbedders`)

**Interfaces:**
- Consumes: Task 9 (`KindEmbedding`, `EmbedServiceID`, `LoadEmbed`), Task 10 (`Embedder`).
- Produces: `POST /v1/embeddings` OpenAI shape; `(*Server).WithEmbedders(map[string]upstream.Embedder) *Server`; `Config.EmbedBurst` (default 60), `Config.EmbedInterval` (default 1 s).

- [ ] **Step 1: Failing tests**

```go
// internal/httpapi/embed_test.go
package httpapi

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ruoc/gateway/internal/catalog"
	"github.com/ruoc/gateway/internal/ledger"
	"github.com/ruoc/gateway/internal/money"
	"github.com/ruoc/gateway/internal/store"
	"github.com/ruoc/gateway/internal/upstream"
)

type fakeEmbedder struct {
	mu       sync.Mutex
	err      error
	tokens   int64
	requests []upstream.EmbedRequest
}

func (f *fakeEmbedder) Embed(ctx context.Context, in upstream.EmbedRequest) (upstream.EmbedResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.requests = append(f.requests, in)
	if f.err != nil {
		return upstream.EmbedResult{}, f.err
	}
	vectors := make([][]float32, len(in.Texts))
	for i := range in.Texts {
		vectors[i] = []float32{0.6, 0.8}
	}
	tokens := f.tokens
	if tokens == 0 {
		tokens = int64(3 * len(in.Texts))
	}
	return upstream.EmbedResult{Vectors: vectors, Tokens: tokens, Dim: 2}, nil
}

func (f *fakeEmbedder) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.requests)
}

type embedHarness struct {
	t        *testing.T
	store    *store.Store
	server   *httptest.Server
	token    string
	account  string
	embedder *fakeEmbedder
}

type embedSetup struct {
	err        error
	tokens     int64
	noEmbedder bool
	noEntry    bool
	unpriced   bool
	perMillion money.Nanorub
	cfg        func(*Config)
}

func withEmbedError(err error) func(*embedSetup)           { return func(s *embedSetup) { s.err = err } }
func withEmbedTokens(n int64) func(*embedSetup)            { return func(s *embedSetup) { s.tokens = n } }
func withoutEmbedder() func(*embedSetup)                   { return func(s *embedSetup) { s.noEmbedder = true } }
func withoutEmbedEntry() func(*embedSetup)                 { return func(s *embedSetup) { s.noEntry = true } }
func withUnpricedEmbed() func(*embedSetup)                 { return func(s *embedSetup) { s.unpriced = true } }
func withEmbedPerMillion(r money.Nanorub) func(*embedSetup) { return func(s *embedSetup) { s.perMillion = r } }
func withEmbedConfig(f func(*Config)) func(*embedSetup)     { return func(s *embedSetup) { s.cfg = f } }

func newEmbedHarness(t *testing.T, balance money.Nanorub, opts ...func(*embedSetup)) *embedHarness {
	t.Helper()
	setup := embedSetup{cfg: func(*Config) {}}
	for _, o := range opts {
		o(&setup)
	}
	st := newStoreForTest(t)
	ctx := context.Background()
	if !setup.noEntry {
		if err := st.UpsertModel(ctx, store.ModelInput{ID: catalog.EmbedServiceID, Kind: catalog.KindEmbedding, DisplayName: "Text embeddings"}); err != nil {
			t.Fatalf("UpsertModel: %v", err)
		}
		if err := st.AddRoute(ctx, catalog.EmbedServiceID, "druzhok", "embed", 1); err != nil {
			t.Fatalf("AddRoute: %v", err)
		}
		if !setup.unpriced {
			rate := catalog.RubRate(setup.perMillion, catalog.BasisPerMillion)
			if err := st.SetPrice(ctx, catalog.EmbedServiceID, catalog.InputTokens, rate, time.Now().Add(-24*time.Hour)); err != nil {
				t.Fatalf("SetPrice: %v", err)
			}
		}
	}
	if _, _, err := st.CreateUser(ctx, "embed@example.com", "password123456"); err != nil {
		t.Fatalf("CreateUser: %v", err)
	}
	login, err := st.Login(ctx, "embed@example.com", "password123456", "test")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if balance > 0 {
		if _, err := st.AddGrant(ctx, store.GrantInput{AccountID: login.AccountID, Kind: ledger.KindTopup, Amount: balance}); err != nil {
			t.Fatalf("AddGrant: %v", err)
		}
	}
	embedder := &fakeEmbedder{err: setup.err, tokens: setup.tokens}
	cfg := Defaults()
	setup.cfg(&cfg)
	srv := New(st, map[string]upstream.Adapter{}, cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if !setup.noEmbedder {
		srv = srv.WithEmbedders(map[string]upstream.Embedder{"druzhok": embedder})
	}
	gw := httptest.NewServer(srv.Handler())
	t.Cleanup(gw.Close)
	return &embedHarness{t: t, store: st, server: gw, token: login.Token, account: login.AccountID, embedder: embedder}
}

func (h *embedHarness) embed(body string) *http.Response {
	h.t.Helper()
	req, err := http.NewRequest(http.MethodPost, h.server.URL+"/v1/embeddings", strings.NewReader(body))
	if err != nil {
		h.t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer "+h.token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		h.t.Fatalf("POST /v1/embeddings: %v", err)
	}
	return resp
}

func (h *embedHarness) balance() money.Nanorub {
	h.t.Helper()
	b, err := h.store.Balance(context.Background(), h.account)
	if err != nil {
		h.t.Fatalf("balance: %v", err)
	}
	return b
}

func (h *embedHarness) usageRows() []struct {
	Status  string
	Charged money.Nanorub
} {
	h.t.Helper()
	rows, err := h.store.Pool().Query(context.Background(),
		`select status, charged_nanorub from usage_records where model_id = $1 order by ended_at`, catalog.EmbedServiceID)
	if err != nil {
		h.t.Fatalf("usage rows: %v", err)
	}
	defer rows.Close()
	var out []struct {
		Status  string
		Charged money.Nanorub
	}
	for rows.Next() {
		var status string
		var charged int64
		if err := rows.Scan(&status, &charged); err != nil {
			h.t.Fatalf("scan: %v", err)
		}
		out = append(out, struct {
			Status  string
			Charged money.Nanorub
		}{status, money.Nanorub(charged)})
	}
	return out
}

func TestEmbedAtZeroReturnsVectorsInOpenAIShapeAndRecordsAFreeRow(t *testing.T) {
	h := newEmbedHarness(t, money.Rubles(10))
	resp := h.embed(`{"model":"ruoc-embed","input":["query: кошка","passage: кот"]}`)
	if resp.StatusCode != http.StatusOK {
		raw, _ := io.ReadAll(resp.Body)
		t.Fatalf("status %d: %s", resp.StatusCode, raw)
	}
	if resp.Header.Get("X-Ruoc-Request-Id") == "" {
		t.Fatal("no request id header")
	}
	var got embedResponse
	decodeBody(t, resp, &got)
	if got.Object != "list" || got.Model != "ruoc-embed" || len(got.Data) != 2 || got.Data[1].Index != 1 ||
		got.Data[1].Object != "embedding" || len(got.Data[1].Embedding) != 2 || got.Usage.PromptTokens != 6 || got.Usage.TotalTokens != 6 {
		t.Fatalf("response: %+v", got)
	}
	if h.embedder.callCount() != 1 || len(h.embedder.requests[0].Texts) != 2 {
		t.Fatalf("embedder calls: %+v", h.embedder.requests)
	}
	rows := h.usageRows()
	if len(rows) != 1 || rows[0].Status != store.StatusCompleted || rows[0].Charged != 0 {
		t.Fatalf("usage rows: %+v", rows)
	}
	if h.balance() != money.Rubles(10) {
		t.Fatalf("a free embed must not move the balance: %s", h.balance())
	}
}

func TestEmbedAcceptsASingleString(t *testing.T) {
	h := newEmbedHarness(t, money.Rubles(10))
	resp := h.embed(`{"model":"ruoc-embed","input":"one"}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	var got embedResponse
	decodeBody(t, resp, &got)
	if len(got.Data) != 1 {
		t.Fatalf("response: %+v", got)
	}
}

func TestEmbedAtAPriceDebitsTheReportedTokens(t *testing.T) {
	// 1,000,000 RUB per million tokens = 1 RUB per token; 5 tokens = 5 RUB.
	h := newEmbedHarness(t, money.Rubles(10), withEmbedPerMillion(money.Rubles(1_000_000)), withEmbedTokens(5))
	resp := h.embed(`{"input":["a"]}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if got := resp.Header.Get("X-Ruoc-Balance"); got != strconv.FormatInt(int64(money.Rubles(5)), 10) {
		t.Fatalf("balance header: %q", got)
	}
	resp.Body.Close()
	if h.balance() != money.Rubles(5) {
		t.Fatalf("balance: %s", h.balance())
	}
	rows := h.usageRows()
	if len(rows) != 1 || rows[0].Charged != money.Rubles(5) {
		t.Fatalf("usage rows: %+v", rows)
	}
}

func TestEmbedBelowTheEstimateIsRefusedBeforeTheEmbedder(t *testing.T) {
	// 30 chars → estimate 10 tokens → 10 RUB; the account holds 1.
	h := newEmbedHarness(t, money.Rubles(1), withEmbedPerMillion(money.Rubles(1_000_000)))
	resp := h.embed(`{"input":["` + strings.Repeat("x", 30) + `"]}`)
	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if typ, _ := errorType(t, resp); typ != "insufficient_quota" {
		t.Fatalf("type %q", typ)
	}
	if h.embedder.callCount() != 0 {
		t.Fatal("the embedder must not be called for an account that cannot pay")
	}
}

func TestEmbedFailureIsNotChargedAndIsA502(t *testing.T) {
	h := newEmbedHarness(t, money.Rubles(10), withEmbedPerMillion(money.Rubles(1_000_000)), withEmbedError(upstream.ErrEmbedderUnavailable))
	resp := h.embed(`{"input":["a"]}`)
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if h.balance() != money.Rubles(10) {
		t.Fatalf("balance moved: %s", h.balance())
	}
	rows := h.usageRows()
	if len(rows) != 1 || rows[0].Status == store.StatusCompleted || rows[0].Charged != 0 {
		t.Fatalf("a failed embed is recorded unpaid: %+v", rows)
	}
}

func TestEmbedBadInputIs400OrRefusedByTheEmbedderAs400(t *testing.T) {
	h := newEmbedHarness(t, money.Rubles(10))
	for _, body := range []string{`{}`, `{"input":[]}`, `{"input":[1]}`, `{"input":""}`, `not json`} {
		resp := h.embed(body)
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("%s: status %d", body, resp.StatusCode)
		}
		resp.Body.Close()
	}
	many := `{"input":[` + strings.Repeat(`"x",`, 64) + `"x"]}`
	if resp := h.embed(many); resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("65 texts: status %d", resp.StatusCode)
	}
	long := `{"input":["` + strings.Repeat("я", 8001) + `"]}`
	if resp := h.embed(long); resp.StatusCode != http.StatusRequestEntityTooLarge {
		t.Fatalf("8001 chars: status %d", resp.StatusCode)
	}
	if h.embedder.callCount() != 0 {
		t.Fatal("nothing above may reach the embedder")
	}

	h2 := newEmbedHarness(t, money.Rubles(10), withEmbedError(upstream.ErrBadEmbedInput))
	if resp := h2.embed(`{"input":["a"]}`); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("embedder refusal: status %d", resp.StatusCode)
	}
}

func TestEmbedWithoutEntryEmbedderOrPriceIs503(t *testing.T) {
	for name, opt := range map[string]func(*embedSetup){
		"no entry": withoutEmbedEntry(), "no embedder": withoutEmbedder(), "unpriced": withUnpricedEmbed(),
	} {
		h := newEmbedHarness(t, money.Rubles(10), opt)
		if resp := h.embed(`{"input":["a"]}`); resp.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("%s: status %d", name, resp.StatusCode)
		}
	}
}

func TestEmbedIsRateLimitedPerAccount(t *testing.T) {
	h := newEmbedHarness(t, money.Rubles(10), withEmbedConfig(func(c *Config) { c.EmbedBurst = 2; c.EmbedInterval = time.Hour }))
	for i := 0; i < 2; i++ {
		if resp := h.embed(`{"input":["a"]}`); resp.StatusCode != http.StatusOK {
			t.Fatalf("call %d: status %d", i, resp.StatusCode)
		}
	}
	if resp := h.embed(`{"input":["a"]}`); resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("third call: status %d", resp.StatusCode)
	}
}

func TestEmbedNeedsABearerToken(t *testing.T) {
	h := newEmbedHarness(t, money.Rubles(10))
	req, _ := http.NewRequest(http.MethodPost, h.server.URL+"/v1/embeddings", strings.NewReader(`{"input":["a"]}`))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status %d", resp.StatusCode)
	}
}
```

- [ ] **Step 2: Run to see them fail**

Run: `go test ./internal/httpapi/ -run Embed`
Expected: compile errors (`WithEmbedders`, `embedResponse`, `EmbedBurst`).

- [ ] **Step 3: Implement**

`internal/httpapi/server.go`: in `Config` after the fetch bucket:

```go
	// POST /v1/embeddings gets its own bucket: a memory provider embeds on
	// every turn, so the ceiling is high, but a loop must still hit one.
	EmbedBurst    int
	EmbedInterval time.Duration
```

In `Defaults()`: `EmbedBurst: 60, EmbedInterval: time.Second,`. In the `Server` struct next to `fetchByAccnt`: `embedByAccnt *limiter`; next to `fetchers`: `embedders map[string]upstream.Embedder`. In `New`: `embedByAccnt: newLimiter(cfg.EmbedBurst, cfg.EmbedInterval),`.

`internal/httpapi/hosts.go`, after the fetch route: `mux.HandleFunc("POST /v1/embeddings", s.embeddings)`.

`internal/config/config.go`: add `EMBED_BURST` next to `SEARCH_BURST` (`cfg.API.EmbedBurst`) and `{"EMBED_INTERVAL", &cfg.API.EmbedInterval}` to the duration table.

`cmd/ruocd/main.go`, after the fetchers loop:

```go
	// The embedder is druzhok too, behind the same secret and base URL.
	embedders := map[string]upstream.Embedder{}
	for name, up := range cfg.Fetchers {
		embedders[name] = upstream.NewDruzhokEmbedder(up.BaseURL, up.APIKey, embedTimeout)
	}
```

with `const embedTimeout = 30 * time.Second` beside `fetchTimeout`, and `.WithEmbedders(embedders)` in the `httpapi.New(...)` chain.

The handler:

```go
// internal/httpapi/embed.go
package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"
	"unicode/utf8"

	"github.com/ruoc/gateway/internal/catalog"
	"github.com/ruoc/gateway/internal/money"
	"github.com/ruoc/gateway/internal/store"
	"github.com/ruoc/gateway/internal/upstream"
)

// WithEmbedders attaches the embedders POST /v1/embeddings may route to,
// keyed by upstream name. Optional: a gateway with none serves everything else.
func (s *Server) WithEmbedders(m map[string]upstream.Embedder) *Server {
	s.embedders = m
	return s
}

// The limits druzhok's embedder enforces too, so a refusal is decided here
// before any work is done.
const (
	maxEmbedRequestBytes = 1 << 20
	maxEmbedTexts        = 64
	maxEmbedTextChars    = 8000
	// embedCharsPerToken is the admission estimate: three characters per
	// token is generous for Cyrillic under a SentencePiece vocabulary, and
	// admission only needs to refuse an account that could not pay.
	embedCharsPerToken = 3
)

type embedRequest struct {
	Model string          `json:"model"`
	Input json.RawMessage `json:"input"`
}

type embedVector struct {
	Object    string    `json:"object"`
	Index     int       `json:"index"`
	Embedding []float32 `json:"embedding"`
}

type embedUsage struct {
	PromptTokens int64 `json:"prompt_tokens"`
	TotalTokens  int64 `json:"total_tokens"`
}

// embedResponse is the OpenAI embeddings shape, which is what every client
// library and Mnemosyne expect.
type embedResponse struct {
	Object string        `json:"object"`
	Data   []embedVector `json:"data"`
	Model  string        `json:"model"`
	Usage  embedUsage    `json:"usage"`
}

// embedTexts decodes `input`, which OpenAI allows as one string or a list.
func embedTexts(raw json.RawMessage) ([]string, bool) {
	var one string
	if err := json.Unmarshal(raw, &one); err == nil {
		if one == "" {
			return nil, false
		}
		return []string{one}, true
	}
	var many []string
	if err := json.Unmarshal(raw, &many); err != nil || len(many) == 0 {
		return nil, false
	}
	return many, true
}

// embeddings serves POST /v1/embeddings: one batch of texts as unit vectors,
// billed per input token at the embedding entry's rate — zero at launch,
// which is still a rate and still a ledger row.
//
// The shape is the fetch handler's: admission compares the balance with an
// estimate, the account is debited for the tokens the embedder reports, and
// a failed batch costs nothing. No repeat guard: a memory provider embeds
// the same query on purpose.
func (s *Server) embeddings(w http.ResponseWriter, r *http.Request) {
	principal, ok := s.authenticate(w, r)
	if !ok {
		return
	}
	if !s.embedByAccnt.allow(principal.AccountID) {
		writeError(w, http.StatusTooManyRequests, "rate_limit_error", "too many embedding requests for this account; slow down")
		return
	}

	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxEmbedRequestBytes))
	if err != nil {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request body too large")
		return
	}
	var req embedRequest
	if err := json.Unmarshal(body, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid JSON body")
		return
	}
	texts, ok := embedTexts(req.Input)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "input must be a non-empty string or list of strings")
		return
	}
	if len(texts) > maxEmbedTexts {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "at most "+strconv.Itoa(maxEmbedTexts)+" texts per request")
		return
	}
	var chars int64
	for _, t := range texts {
		n := utf8.RuneCountInString(t)
		if n > maxEmbedTextChars {
			writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "a text is longer than "+strconv.Itoa(maxEmbedTextChars)+" characters")
			return
		}
		chars += int64(n)
	}

	releaseSlot, ok := s.slots.acquire(principal.AccountID, s.cfg.MaxConcurrent)
	if !ok {
		writeError(w, http.StatusTooManyRequests, "rate_limit_error", "too many requests in flight for this account")
		return
	}
	defer releaseSlot()

	entry, err := s.store.LoadEmbed(r.Context())
	if errors.Is(err, store.ErrUnknownModel) {
		writeError(w, http.StatusServiceUnavailable, "api_error", "embeddings are not available")
		return
	}
	if err != nil {
		s.fail(w, "load embedding entry", err)
		return
	}

	started := time.Now()
	if _, priced := catalog.RateAt(entry.Prices, catalog.InputTokens, started); !priced {
		s.log.Error("embeddings have no rate in force; refusing rather than serving them free", "entry", catalog.EmbedServiceID)
		writeError(w, http.StatusServiceUnavailable, "api_error", "embeddings are not available")
		return
	}

	estimateTokens := chars/embedCharsPerToken + int64(len(texts))
	estimate, err := catalog.Compute(entry.Prices, catalog.Quantities{catalog.InputTokens: estimateTokens}, started)
	if err != nil {
		s.fail(w, "embed admission estimate", err)
		return
	}
	balance, err := s.store.Balance(r.Context(), principal.AccountID)
	if err != nil {
		s.fail(w, "embed balance", err)
		return
	}
	if balance < estimate.Total {
		writeError(w, http.StatusPaymentRequired, "insufficient_quota", "account balance is too low to embed this batch")
		return
	}

	result, route, err := s.runEmbed(r.Context(), entry, texts)
	if errors.Is(err, errNoEmbedder) {
		writeError(w, http.StatusServiceUnavailable, "api_error", "embeddings are not available")
		return
	}
	requestID := newRequestID()
	switch {
	case errors.Is(err, upstream.ErrBadEmbedInput):
		s.recordEmbed(principal, route, requestID, store.StatusUpstreamError, started, nil, catalog.Charge{})
		writeError(w, http.StatusBadRequest, "invalid_request_error", "the embedder refused the batch")
		return
	case err != nil:
		s.log.Warn("the batch could not be embedded", "request_id", requestID, "account", principal.AccountID, "error", err)
		s.recordEmbed(principal, route, requestID, store.StatusUpstreamError, started, nil, catalog.Charge{})
		writeError(w, http.StatusBadGateway, "api_error", "the embedder could not be reached")
		return
	}

	quantities := catalog.Quantities{catalog.InputTokens: result.Tokens}
	charge, err := catalog.Compute(entry.Prices, quantities, started)
	if err != nil {
		s.log.Error("a served embedding could not be priced", "request_id", requestID, "error", err)
	}
	s.recordEmbed(principal, route, requestID, store.StatusCompleted, started, quantities, charge)

	data := make([]embedVector, len(result.Vectors))
	for i, v := range result.Vectors {
		data[i] = embedVector{Object: "embedding", Index: i, Embedding: v}
	}
	header := w.Header()
	header.Set("X-Ruoc-Request-Id", requestID)
	header.Set("X-Ruoc-Balance", strconv.FormatInt(int64(balance-charge.Total), 10))
	writeJSON(w, http.StatusOK, embedResponse{
		Object: "list", Data: data, Model: catalog.EmbedServiceID,
		Usage: embedUsage{PromptTokens: result.Tokens, TotalTokens: result.Tokens},
	})
}

var errNoEmbedder = errors.New("httpapi: no embedder is configured")

// runEmbed tries each route in priority order; a refusal of the input ends
// the walk, another embedder would say the same.
func (s *Server) runEmbed(ctx context.Context, entry catalog.Model, texts []string) (upstream.EmbedResult, catalog.Route, error) {
	var lastErr error
	var tried bool
	for _, route := range entry.Routes {
		provider, ok := s.embedders[route.Upstream]
		if !ok {
			continue
		}
		tried = true
		result, err := provider.Embed(ctx, upstream.EmbedRequest{Texts: texts})
		if err != nil {
			lastErr = err
			if errors.Is(err, upstream.ErrBadEmbedInput) {
				return upstream.EmbedResult{}, route, err
			}
			continue
		}
		return result, route, nil
	}
	if !tried {
		return upstream.EmbedResult{}, catalog.Route{}, errNoEmbedder
	}
	return upstream.EmbedResult{}, catalog.Route{}, lastErr
}

// recordEmbed writes the usage row and its debit, detached from the request
// context for the reason recordFetch is. A zero charge still writes the row.
func (s *Server) recordEmbed(principal store.Principal, route catalog.Route, requestID, status string,
	started time.Time, quantities catalog.Quantities, charge catalog.Charge) {

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if quantities == nil {
		quantities = catalog.Quantities{}
	}
	if charge.Lines == nil {
		charge.Lines = []catalog.ChargeLine{}
	}

	var upstreamCost money.Nanousd
	if route.Upstream != "" && status == store.StatusCompleted {
		if prices, err := s.store.UpstreamPrices(ctx, route.Upstream, route.UpstreamModelID); err == nil {
			if cost, err := catalog.ComputeUpstream(prices, quantities, started); err == nil {
				upstreamCost = cost
			}
		}
	}

	now := time.Now()
	var firstByte *time.Time
	if status == store.StatusCompleted {
		firstByte = &now
	}
	if _, err := s.store.Debit(ctx, store.Usage{
		AccountID:           principal.AccountID,
		APIKeyID:            &principal.KeyID,
		ModelID:             catalog.EmbedServiceID,
		Upstream:            route.Upstream,
		UpstreamModelID:     route.UpstreamModelID,
		RequestID:           requestID,
		Status:              status,
		Estimated:           false,
		StartedAt:           started,
		FirstByteAt:         firstByte,
		EndedAt:             now,
		Quantities:          quantities,
		Breakdown:           charge,
		ChargedNanorub:      charge.Total,
		UpstreamCostNanousd: upstreamCost,
	}); err != nil {
		s.log.Error("failed to record an embedding", "request_id", requestID, "account", principal.AccountID, "error", err)
	}
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/httpapi/ ./internal/config/ ./cmd/...`
Expected: pass. If `Config` has a test enumerating every env var (`config_test.go`), add `EMBED_BURST` / `EMBED_INTERVAL` cases there in the same style as `SEARCH_BURST`.

- [ ] **Step 5: Commit**

```bash
git add internal/httpapi internal/config cmd/ruocd/main.go
git commit -m "POST /v1/embeddings billed per input token"
```

### Task 12: `ruocd embed setup|show`, console kind, README

**Files:**
- Modify: `cmd/ruocd/operator.go` (new `embedCommand`, `embedSetup`, `embedShow` after the fetch ones ~1770)
- Modify: `cmd/ruocd/main.go` (usage text after the fetch lines; `case "embed":` in the dispatch)
- Modify: `web/src/lib/api.ts:393` (kind union)
- Modify: `README.md` (new section "## Text embeddings" after "## Voice transcription")
- Test: `cmd/ruocd/operator_test.go` if one exists for `fetchSetup` (`grep -n "fetchSetup\|fetchShow" cmd/ruocd/*_test.go`); otherwise the commands are verified by hand in Step 4.

- [ ] **Step 1: Implement the commands**

```go
// embedCommand: `ruocd embed setup|show`. Embeddings are one entry priced per
// million input tokens; its own command because the unit is a token line,
// not a per-call price like search or fetch.
func embedCommand(ctx context.Context, st *store.Store, args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: ruocd embed (setup|show) ...")
	}
	switch args[0] {
	case "setup":
		return embedSetup(ctx, st, args[1:])
	case "show":
		return embedShow(ctx, st)
	default:
		return fmt.Errorf("unknown embed subcommand %q; expected setup or show", args[0])
	}
}

// embedUpstreamModelID is the upstream_model_id an embed route carries; the
// embedder has one model, so it is a constant like fetchUpstreamModelID.
const embedUpstreamModelID = "embed"

// embedSetup creates the embedding entry, its route and its prices, and is the
// supported way to reprice. Zero is accepted: the unit launches free.
func embedSetup(ctx context.Context, st *store.Store, args []string) error {
	fs := flag.NewFlagSet("embed setup", flag.ExitOnError)
	rubIn := fs.String("rub-in", "", "RUB per million input tokens, charged to the customer (0 for free)")
	usdIn := fs.String("usd-in", "", "USD per million input tokens, what the embedder costs; omit to leave it unchanged")
	provider := fs.String("provider", "druzhok", "embedder name, matching its FETCH_SECRET configuration")
	name := fs.String("name", "Text embeddings", "display name, for the operator's own reports")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if strings.TrimSpace(*rubIn) == "" {
		return fmt.Errorf("-rub-in is required: say 0 to give embeddings away, it is not the default")
	}
	quotedRub, err := money.ParseRubles(strings.TrimSpace(*rubIn))
	if err != nil {
		return fmt.Errorf("-rub-in: %w", err)
	}
	if quotedRub < 0 {
		return fmt.Errorf("-rub-in: an embedding price cannot be negative, got %s", quotedRub)
	}
	customer := map[catalog.UnitKind]money.Nanorub{catalog.InputTokens: quotedRub}
	upstreamCost := map[catalog.UnitKind]money.Nanousd{}
	if strings.TrimSpace(*usdIn) != "" {
		cost, err := money.ParseDollars(strings.TrimSpace(*usdIn))
		if err != nil {
			return fmt.Errorf("-usd-in: %w", err)
		}
		upstreamCost[catalog.InputTokens] = cost
	}
	if err := checkQuotes(customer, upstreamCost); err != nil {
		return err
	}

	if err := st.UpsertModel(ctx, store.ModelInput{
		ID: catalog.EmbedServiceID, Kind: catalog.KindEmbedding,
		DisplayName: *name, Description: "Text embeddings for bot memory, billed per million input tokens",
	}); err != nil {
		return err
	}
	if err := st.AddRoute(ctx, catalog.EmbedServiceID, *provider, embedUpstreamModelID, 1); err != nil {
		return err
	}
	in := store.RepriceInput{
		EntryID: catalog.EmbedServiceID, Basis: catalog.BasisPerMillion,
		Customer: customer, UpstreamName: *provider, UpstreamModelID: embedUpstreamModelID,
	}
	if len(upstreamCost) > 0 {
		in.Upstream = upstreamCost
	}
	from, err := st.Reprice(ctx, in)
	if err != nil {
		return err
	}
	fmt.Printf("%s  %s\nroute     %s/%s\neffective %s\n\n",
		catalog.EmbedServiceID, *name, *provider, embedUpstreamModelID, from.Format(time.RFC3339Nano))
	return embedShow(ctx, st)
}

// embedShow prints what the endpoint will charge per million tokens and where
// it will route.
func embedShow(ctx context.Context, st *store.Store) error {
	entry, err := st.LoadEmbed(ctx)
	if errors.Is(err, store.ErrUnknownModel) {
		fmt.Println("embeddings are not configured; run: ruocd embed setup -rub-in <price per million>")
		return nil
	}
	if err != nil {
		return err
	}
	rate, priced := catalog.RateAt(entry.Prices, catalog.InputTokens, time.Now())
	if !priced {
		fmt.Printf("%s has no rate in force; /v1/embeddings will answer 503\n", catalog.EmbedServiceID)
		return nil
	}
	fmt.Printf("%s  %s\n", entry.ID, entry.DisplayName)
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "ROUTE\tUPSTREAM COST / 1M\tCUSTOMER PRICE / 1M")
	label := fetchRateLabel(catalog.QuoteRub(rate, catalog.BasisPerMillion))
	if len(entry.Routes) == 0 {
		fmt.Fprintf(w, "(none)\t\t%s\n", label)
	}
	for _, route := range entry.Routes {
		costShown := "none recorded"
		if prices, err := st.UpstreamPrices(ctx, route.Upstream, route.UpstreamModelID); err == nil {
			if c, ok := upstreamRateNowFor(prices, catalog.InputTokens); ok {
				costShown = catalog.QuoteUsd(c, catalog.BasisPerMillion).String()
			}
		}
		fmt.Fprintf(w, "%s/%s\t%s\t%s\n", route.Upstream, route.UpstreamModelID, costShown, label)
	}
	w.Flush()
	fmt.Println("\nThe app reaches this as POST /v1/embeddings. Set FETCH_SECRET before serving, or the endpoint answers 503.")
	return nil
}
```

Check `catalog.QuoteUsd` exists (`grep -n "func QuoteUsd" internal/catalog/pricing.go`); if not, print `c.String()` with a "/token" suffix instead. `main.go`: add `case "embed": return embedCommand(ctx, st, args)` and the two usage lines:

```
  ruocd embed setup -rub-in [-usd-in]  price text embeddings per million tokens (0 = free), or reprice
  ruocd embed show                what /v1/embeddings charges and where it routes
```

`web/src/lib/api.ts:393`: `kind: "model" | "service" | "transcription" | "image" | "fetch" | "embedding"`.

- [ ] **Step 2: Build and vet**

Run: `go build ./... && go vet ./... && go test ./...` (with `TEST_DATABASE_URL` exported).
Expected: clean.

- [ ] **Step 3: README section**

After "## Voice transcription" add:

````markdown
## Text embeddings

`POST /v1/embeddings` takes `{"model":"ruoc-embed","input": string | [string]}` and
answers in the OpenAI embeddings shape. It exists for druzhok's bot memory
(Mnemosyne): every turn the bot embeds what the user said and its recall query.
The vectors come from druzhok's own embedder (`POST /internal/embed`, behind the
same `FETCH_SECRET` as page fetch), so the gateway holds no model; it meters.

```sh
./ruocd embed setup -rub-in 0        # free at launch, still a ledger row per batch
./ruocd embed show
```

**Priced per million input tokens**, like a model's input line, and billed from
the token count the embedder reports after truncation (512 tokens per text).
Admission estimates three characters per token; a batch the balance cannot cover
is refused with 402 before the embedder is called. At most 64 texts of 8,000
characters per request, 1 MiB body. `EMBED_BURST` / `EMBED_INTERVAL` cap calls per
account (default 60 per second, high on purpose: memory embeds on every turn).
A failed batch is charged nothing. The entry is kind `embedding`: never in
`GET /v1/models`, never accepted by a completion.
````

- [ ] **Step 4: Try the commands against the local database**

```bash
go run ./cmd/ruocd embed show          # "embeddings are not configured"
go run ./cmd/ruocd embed setup -rub-in 0
go run ./cmd/ruocd embed show          # route druzhok/embed, customer price free
```

(`ruocd` reads `DATABASE_URL` from the environment; export only that variable from `.env` the way `TEST_DATABASE_URL` is exported above, and confirm it names a local database first.)

- [ ] **Step 5: Commit**

```bash
git add cmd/ruocd web/src/lib/api.ts README.md
git commit -m "ruocd embed setup/show; document embeddings"
```

---

## Part C: hermes fork

### Task 13: `mnemosyne` extra in the fork, skill update

**Files:**
- Modify: `hermes-agent/pyproject.toml` (optional-dependencies, after `hindsight`)
- Modify: `hermes-agent/uv.lock` (regenerated)
- Modify: `~/.claude/skills/update-hermes/SKILL.md` (Customization 5, server `uv sync` line)

This is the separate fork repo (`hermes-agent/`, remote `origin` = `iforaa/druzhok-hermes`). Never `git add` it from the druzhok repo.

- [ ] **Step 1: Add the extra**

```toml
# Druzhok: Mnemosyne memory provider (docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md
# in the druzhok repo). Installed with `--extra mnemosyne`; discovered through the
# hermes_agent.memory_providers entry point.
mnemosyne = ["mnemosyne-memory[embeddings]==3.15.1", "mnemosyne-hermes==0.5.0"]
```

- [ ] **Step 2: Lock and verify**

```bash
cd /Users/igorkuznetsov/Documents/druzhok/hermes-agent
git status --short            # must be clean
uv lock                       # resolves only the new extra; other pins stay
git diff --stat uv.lock
uv sync --frozen --extra mnemosyne 2>&1 | tail -3
.venv/bin/python -c "import importlib.metadata as m; print([e.name for e in m.entry_points(group='hermes_agent.memory_providers')])"
.venv/bin/python -m pytest tests/test_project_metadata.py -q
```

Expected: the entry point list contains `mnemosyne`; the metadata test passes (the extra is not in `[all]`, which is the policy). If `mnemosyne-hermes` declares an incompatible Python or a conflicting pin, report it instead of loosening other pins.

- [ ] **Step 3: Commit and push the fork**

```bash
git add pyproject.toml uv.lock
git commit -m "druzhok: mnemosyne memory extra"
git push origin main
```

- [ ] **Step 4: Update the skill**

In `~/.claude/skills/update-hermes/SKILL.md` add after "Customization 4":

````markdown
### Customization 5: Mnemosyne memory extra (`pyproject.toml`)

**Intent:** druzhok bots with `memory_provider = mnemosyne` load the Mnemosyne provider from the shared venv.

**Idempotency check:** `grep -n '^mnemosyne = ' pyproject.toml` — if present, skip.

**Apply** under `[project.optional-dependencies]`:
```toml
mnemosyne = ["mnemosyne-memory[embeddings]==3.15.1", "mnemosyne-hermes==0.5.0"]
```
then `uv lock` (no `--upgrade`) and commit `uv.lock` with it. Server installs use `--extra mnemosyne` (Step 2 below).
````

and add `--extra mnemosyne` to the server `uv sync` command in Step 2 of the skill. Also add `mnemosyne` to the "our env vars still referenced?" list check: `grep -c "hermes_agent.memory_providers" plugins/memory/__init__.py` must stay non-zero.

---

## Part D: rollout

### Task 14: Deploy and flip the operator's bot

This task is manual and ordered. Stop at the first failed check.

- [ ] **Step 1: Server prerequisites (once)**

```bash
ssh ubuntu@195.49.213.8 'df -h /data | tail -1; python3 --version'
rsync -az --delete --exclude=_build --exclude=deps apps config ops mix.exs mix.lock .tool-versions ubuntu@195.49.213.8:~/druzhok/
ssh ubuntu@195.49.213.8 'sudo python3 -m venv /opt/druzhok-embed/.venv && sudo /opt/druzhok-embed/.venv/bin/pip install -q -r ~/druzhok/apps/druzhok/priv/embed-worker/requirements.txt && sudo mkdir -p /data/opt/embed-models && sudo bash ~/druzhok/ops/embed-model-fetch.sh /data/opt/embed-models/multilingual-e5-small && sudo chmod -R a+rX /data/opt/embed-models'
ssh ubuntu@195.49.213.8 'sudo /opt/druzhok-embed/.venv/bin/python ~/druzhok/apps/druzhok/priv/embed-worker/test_worker.py /data/opt/embed-models/multilingual-e5-small'
ssh ubuntu@195.49.213.8 'grep -c "^EMBED_WORKER_BIN=\|^EMBED_MODEL_DIR=" /etc/druzhok/druzhok.env'
```

If the count is not 2, append the two keys with `sudo tee -a /etc/druzhok/druzhok.env` (values from Task 8), never by echoing the file.

- [ ] **Step 2: ruoc**

Deploy ruoc-gateway the way its `README.md` "## Deploying" section says, then:

```bash
ssh ubuntu@195.49.213.8 'sudo -u ruoc ruocd embed setup -rub-in 0 && sudo -u ruoc ruocd embed show'
```

(Adjust the user and binary path to how `ruocd fetch setup` was run on 2026-09-05; `journalctl -u ruoc --since "1 hour ago" | grep -i embed` afterwards must be quiet.)

- [ ] **Step 3: druzhok**

```bash
ssh ubuntu@195.49.213.8
. ~/.asdf/asdf.sh; set -a; . /etc/druzhok/druzhok.env; set +a
cd ~/druzhok && MIX_ENV=prod mix compile && MIX_ENV=prod mix ecto.migrate
sudo systemctl restart druzhok
journalctl -u druzhok --since '2 min ago' | grep -i "embed\|error" | tail
```

Then from the laptop, with the secret read the allowed way on the box:

```bash
ssh ubuntu@195.49.213.8 'S=$(sudo grep -o "^FETCH_SECRET=.*" /etc/druzhok/druzhok.env | cut -d= -f2- | tr -d "\""); cd ~/druzhok && python3 ops/embed-eval/eval.py http://127.0.0.1:4000 "$S"'
```

Expected: `R@1=0.80 R@5=0.95 MRR=0.87` within a couple of points. Then one tenant-key call:

```bash
curl -s -H "Authorization: Bearer <tenant_key>" http://127.0.0.1:4000/v1/embeddings -d '{"model":"ruoc-embed","input":["query: тест"]}' | head -c 300
```

- [ ] **Step 4: hermes install**

```bash
ssh ubuntu@195.49.213.8 'cd /opt/hermes && sudo git fetch -q origin && sudo git reset -q --hard origin/main && sudo UV_CACHE_DIR=/data/opt/uv-cache UV_PYTHON_INSTALL_DIR=/data/opt/uv-python uv sync --frozen --python /usr/bin/python3 --extra all --extra messaging --extra firecrawl --extra mnemosyne 2>&1 | tail -3; sudo chown -R root:root /data/opt/hermes; sudo chmod -R a+rX /data/opt/hermes; /opt/hermes/.venv/bin/python -c "import mnemosyne_hermes; print(\"ok\")"'
```

Running bots are unaffected until restarted.

- [ ] **Step 5: Flip the operator's bot**

In the dashboard settings tab of the operator's bot pick `mnemosyne`, then:

```bash
ssh ubuntu@195.49.213.8 'sudo druzhok-ctl logs <operator-bot> 60'
ssh ubuntu@195.49.213.8 'sudo ls -la /data/tenants/<operator-bot>/mnemosyne'
```

Talk to the bot: tell it three facts, `/new`, ask about one of them. Then check the trail:

```bash
ssh ubuntu@195.49.213.8 'sudo ops/druzhok-run.sh "Druzhok.Repo.all(from u in Druzhok.Usage, where: u.request_type == \"embedding\", order_by: [desc: u.inserted_at], limit: 5) |> Enum.map(&{&1.prompt_tokens, &1.latency_ms}) |> IO.inspect()"'
ssh ubuntu@195.49.213.8 'sudo -u postgres psql -d ruoc -c "select status, charged_nanorub, quantities from usage_records where model_id = '"'"'ruoc-embed'"'"' order by ended_at desc limit 5"'
```

Expected: usage rows with token counts and latency under 500 ms; ruoc rows with `completed` and 0 charged; the bot answered from memory.

- [ ] **Step 6: Record**

Add a memory note (project) that Mnemosyne is live on the operator's bot as of the date, the model files' location, and that other bots flip per request; `ops/smoke.sh <operator-bot>` still passes.
