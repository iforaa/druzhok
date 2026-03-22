# Docker Sandbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Isolate agent tool execution inside Docker containers with a Go agent binary communicating via TCP JSON line protocol.

**Architecture:** Each instance optionally gets a Docker container with a Go agent binary listening on TCP. Tools check `context[:sandbox]` — if set, they dispatch to the sandbox functions; otherwise they execute locally. A `Druzhok.Sandbox` behaviour with `Local` and `Docker` implementations makes the backend swappable.

**Tech Stack:** Go (agent binary), Docker, Elixir OTP (GenServer for TCP client), JSON line protocol

**Spec:** `docs/superpowers/specs/2026-03-22-docker-sandbox-design.md`

---

### Task 1: Go Agent Binary

**Files:**
- Create: `services/sandbox-agent/go.mod`
- Create: `services/sandbox-agent/main.go`

- [ ] **Step 1: Create Go module**

```bash
mkdir -p services/sandbox-agent
cd services/sandbox-agent
go mod init github.com/druzhok/sandbox-agent
```

- [ ] **Step 2: Implement agent binary**

`services/sandbox-agent/main.go` — a single-file TCP server (~250 lines):

- Read `SANDBOX_SECRET` from env
- Listen on `:9999`
- Accept one connection only (reject subsequent)
- First message must be `{"type":"auth","secret":"..."}` — validate against env secret
- Handle commands: `exec`, `read`, `write`, `mkdir`, `ls`, `stat`
- `exec`: run via `bash -c`, stream stdout/stderr as separate JSON lines, send `exit` with code
- `read`/`write`/`mkdir`/`ls`/`stat`: file operations under `/workspace` only (path guard via `filepath.EvalSymlinks`)
- 5-minute timeout on exec, 30-second on file ops
- All responses include request `id` for correlation

Key implementation details:
- Use `bufio.Scanner` for line-delimited JSON input
- Use `encoding/json` for marshal/unmarshal
- `exec` uses `os/exec.CommandContext` with timeout context
- Stdout/stderr piped via goroutines that send JSON lines
- Path guard: resolve absolute path, check `strings.HasPrefix(resolved, "/workspace")`

- [ ] **Step 3: Build and test locally**

```bash
cd services/sandbox-agent
go build -o sandbox-agent .
# Quick smoke test:
echo '{"id":"1","type":"auth","secret":"test"}' | SANDBOX_SECRET=test ./sandbox-agent &
# (will listen on :9999)
```

- [ ] **Step 4: Commit**

```bash
git add services/sandbox-agent/
git commit -m "add Go sandbox agent binary"
```

---

### Task 2: Dockerfile + Image Build

**Files:**
- Create: `services/sandbox-agent/Dockerfile`

- [ ] **Step 1: Create Dockerfile**

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o sandbox-agent .

FROM alpine:3.20
RUN apk add --no-cache \
    bash python3 py3-pip nodejs npm git curl wget \
    build-base openssh-client jq
COPY --from=builder /build/sandbox-agent /usr/local/bin/sandbox-agent
RUN mkdir -p /workspace
WORKDIR /workspace
EXPOSE 9999
ENTRYPOINT ["sandbox-agent"]
```

- [ ] **Step 2: Build image**

```bash
cd services/sandbox-agent
docker build -t druzhok-sandbox:latest .
```

- [ ] **Step 3: Test container**

```bash
docker run -d --name test-sandbox -e SANDBOX_SECRET=test123 -p 19999:9999 druzhok-sandbox:latest
# Wait 1 second, then test:
echo '{"type":"auth","secret":"test123"}' | nc localhost 19999
# Should get: {"type":"auth_ok"}
echo '{"id":"1","type":"exec","command":"echo hello"}' | nc localhost 19999
# Should get stdout + exit messages
docker stop test-sandbox && docker rm test-sandbox
```

- [ ] **Step 4: Commit**

```bash
git add services/sandbox-agent/Dockerfile
git commit -m "add sandbox Docker image"
```

---

### Task 3: Sandbox Behaviour + Local Implementation

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/sandbox.ex`
- Create: `v3/apps/druzhok/lib/druzhok/sandbox/local.ex`
- Create: `v3/apps/druzhok/priv/repo/migrations/20260322000008_add_sandbox_to_instances.exs`
- Modify: `v3/apps/druzhok/lib/druzhok/instance.ex`

- [ ] **Step 1: Create Sandbox behaviour**

```elixir
defmodule Druzhok.Sandbox do
  @callback start(instance_name :: String.t(), opts :: map()) :: {:ok, pid()} | {:error, term()}
  @callback stop(instance_name :: String.t()) :: :ok
  @callback exec(instance_name :: String.t(), command :: String.t()) :: {:ok, %{stdout: String.t(), stderr: String.t(), exit_code: integer()}} | {:error, term()}
  @callback read_file(instance_name :: String.t(), path :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback write_file(instance_name :: String.t(), path :: String.t(), content :: String.t()) :: :ok | {:error, term()}
  @callback list_dir(instance_name :: String.t(), path :: String.t()) :: {:ok, [map()]} | {:error, term()}

  def impl(sandbox_type) do
    case sandbox_type do
      "docker" -> Druzhok.Sandbox.Docker
      _ -> Druzhok.Sandbox.Local
    end
  end
end
```

- [ ] **Step 2: Create Local implementation**

```elixir
defmodule Druzhok.Sandbox.Local do
  @behaviour Druzhok.Sandbox

  def start(_instance_name, _opts), do: {:ok, self()}
  def stop(_instance_name), do: :ok

  def exec(_instance_name, command) do
    case System.cmd("bash", ["-c", command], stderr_to_stdout: false, into: IO.stream()) do
      {output, code} -> {:ok, %{stdout: output, stderr: "", exit_code: code}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def read_file(_instance_name, path) do
    File.read(path)
  end

  def write_file(_instance_name, path, content) do
    File.mkdir_p!(Path.dirname(path))
    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def list_dir(_instance_name, path) do
    case File.ls(path) do
      {:ok, entries} ->
        items = Enum.map(entries, fn name ->
          full = Path.join(path, name)
          stat = File.stat!(full)
          %{name: name, is_dir: stat.type == :directory, size: stat.size}
        end)
        {:ok, items}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

- [ ] **Step 3: Add migration + schema field**

Migration adds `sandbox` column to instances. Instance schema adds `field :sandbox, :string, default: "local"` and includes in changeset.

- [ ] **Step 4: Run migration and tests**

```bash
cd v3 && mix ecto.migrate && mix test
```

- [ ] **Step 5: Commit**

```bash
git commit -m "add Sandbox behaviour and Local implementation"
```

---

### Task 4: DockerClient GenServer

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/sandbox/docker_client.ex`
- Test: `v3/apps/druzhok/test/druzhok/sandbox/docker_client_test.exs`

- [ ] **Step 1: Implement DockerClient**

A GenServer that:
- Starts a Docker container on init
- Connects to agent binary via TCP with retry + auth
- Provides `call/2` for synchronous request/response
- Handles exec streaming via `call_stream/3`
- Multiplexes via request IDs
- Stops container on terminate
- Cleans up persistent_term on terminate

Key state: `%{socket: socket, container_name: name, instance_name: name, pending: %{id => from}}`

```elixir
def init(opts) do
  instance_name = opts.instance_name
  secret = :crypto.strong_rand_bytes(16) |> Base.encode64()
  container_name = "druzhok-#{instance_name}"

  case start_container(container_name, secret) do
    {:ok, port} ->
      case connect_with_retry("127.0.0.1", port, secret) do
        {:ok, socket} ->
          {:ok, %{socket: socket, container: container_name, instance_name: instance_name, pending: %{}, counter: 0}}
        {:error, reason} ->
          cleanup_container(container_name)
          {:stop, reason}
      end
    {:error, reason} ->
      {:stop, reason}
  end
end

def terminate(_reason, state) do
  cleanup_container(state.container)
  :ok
end
```

- [ ] **Step 2: Write test (requires Docker)**

Tag test with `@tag :docker` so it can be skipped when Docker isn't available:

```elixir
@tag :docker
test "starts container and executes command" do
  {:ok, pid} = DockerClient.start_link(%{instance_name: "test-dc-#{:rand.uniform(100000)}"})
  {:ok, result} = DockerClient.exec(pid, "echo hello")
  assert result.stdout =~ "hello"
  assert result.exit_code == 0
  GenServer.stop(pid)
end
```

- [ ] **Step 3: Run test**

```bash
cd v3 && mix test apps/druzhok/test/druzhok/sandbox/docker_client_test.exs --trace
```

- [ ] **Step 4: Commit**

```bash
git commit -m "add DockerClient GenServer for sandbox communication"
```

---

### Task 5: Docker Sandbox Implementation

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/sandbox/docker.ex`

- [ ] **Step 1: Implement Docker sandbox**

Wraps DockerClient, implements the Sandbox behaviour. Delegates to the DockerClient GenServer registered in the Registry:

```elixir
defmodule Druzhok.Sandbox.Docker do
  @behaviour Druzhok.Sandbox

  def start(instance_name, _opts) do
    # DockerClient is started as a child of Instance.Sup — this is called by Instance.Sup init
    {:ok, :started}
  end

  def stop(instance_name) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 10_000)
      [] -> :ok
    end
  end

  def exec(instance_name, command) do
    with_client(instance_name, fn pid ->
      Druzhok.Sandbox.DockerClient.exec(pid, command)
    end)
  end

  def read_file(instance_name, path) do
    with_client(instance_name, fn pid ->
      Druzhok.Sandbox.DockerClient.read_file(pid, path)
    end)
  end

  def write_file(instance_name, path, content) do
    with_client(instance_name, fn pid ->
      Druzhok.Sandbox.DockerClient.write_file(pid, path, content)
    end)
  end

  def list_dir(instance_name, path) do
    with_client(instance_name, fn pid ->
      Druzhok.Sandbox.DockerClient.list_dir(pid, path)
    end)
  end

  defp with_client(instance_name, fun) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, "Sandbox not running"}
    end
  end
end
```

- [ ] **Step 2: Commit**

```bash
git commit -m "add Docker sandbox implementation"
```

---

### Task 6: Modify Tools to Use Sandbox

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/tools/bash.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/read.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/write.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/edit.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/find.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/grep.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/tools/send_file.ex`
- Modify: `v3/apps/pi_core/lib/pi_core/memory/search.ex`

- [ ] **Step 1: Update each tool's execute function**

Each tool checks `context[:sandbox]` for sandbox function references. If present, use them. If nil, use current local behavior.

Example for bash:
```elixir
def execute(%{"command" => command}, context) do
  case context[:sandbox] do
    %{exec: exec_fn} ->
      case exec_fn.(command) do
        {:ok, %{stdout: out, exit_code: 0}} -> {:ok, out}
        {:ok, %{stdout: out, stderr: err, exit_code: code}} ->
          {:error, "Exit code #{code}: #{err}\n#{out}"}
        {:error, reason} -> {:error, reason}
      end
    nil ->
      # Current local behavior
      ...
  end
end
```

Example for read:
```elixir
def execute(%{"path" => path}, %{workspace: workspace} = context) do
  case context[:sandbox] do
    %{read_file: read_fn} ->
      full_path = if Path.type(path) == :absolute, do: path, else: "/workspace/#{path}"
      read_fn.(full_path)
    nil ->
      # Current local behavior with PathGuard
      ...
  end
end
```

For `send_file`: read file via sandbox, write to host temp, send via Telegram.
For `memory_search`: read memory files via sandbox `read_file`/`list_dir` functions.

- [ ] **Step 2: Run all tests — must pass with sandbox: nil (local mode)**

```bash
cd v3 && mix test
```

All existing tests should pass unchanged because `context[:sandbox]` is nil.

- [ ] **Step 3: Commit**

```bash
git commit -m "route tools through sandbox when available"
```

---

### Task 7: Instance.Sup + Dashboard Integration

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`
- Modify: `v3/apps/druzhok/lib/druzhok/instance_manager.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Build sandbox functions in Instance.Sup**

In `Instance.Sup.init/1`, build the `sandbox` map for `extra_tool_context` based on instance config:

```elixir
sandbox_fns = case config[:sandbox] do
  "docker" ->
    name = config.name
    %{
      exec: fn command ->
        Druzhok.Sandbox.Docker.exec(name, command)
      end,
      read_file: fn path ->
        Druzhok.Sandbox.Docker.read_file(name, path)
      end,
      write_file: fn path, content ->
        Druzhok.Sandbox.Docker.write_file(name, path, content)
      end,
      list_dir: fn path ->
        Druzhok.Sandbox.Docker.list_dir(name, path)
      end,
    }
  _ -> nil
end

# Add to persistent_term config:
extra_tool_context: %{send_file_fn: send_file_fn, sandbox: sandbox_fns}
```

Add DockerClient as a child when `sandbox == "docker"`:
```elixir
children = [
  telegram_child,
  session_sup_child,
  scheduler_child,
] ++ if config[:sandbox] == "docker" do
  [{Druzhok.Sandbox.DockerClient, %{
    instance_name: config.name,
    registry_name: {:via, Registry, {Druzhok.Registry, {config.name, :sandbox}}},
  }}]
else
  []
end
```

- [ ] **Step 2: Update InstanceManager.create to pass sandbox config**

Read `sandbox` from instance DB record and pass to config.

- [ ] **Step 3: Copy workspace template via sandbox**

When sandbox is "docker" and instance is new, copy workspace template files via `write_file` commands instead of `File.cp_r!`.

- [ ] **Step 4: Update dashboard file browser**

Dashboard file browser needs to route through sandbox for Docker instances. Read `sandbox` field from instance, if "docker" use sandbox functions, otherwise direct filesystem.

Add sandbox mode display in instance top bar.

- [ ] **Step 5: Run tests**

```bash
cd v3 && mix test
```

- [ ] **Step 6: Commit**

```bash
git commit -m "integrate sandbox into Instance.Sup and dashboard"
```

---

### Task 8: Integration Tests + Smoke Test

**Files:**
- Create: `v3/apps/druzhok/test/druzhok/sandbox_test.exs`

- [ ] **Step 1: Write Local sandbox tests**

```elixir
defmodule Druzhok.SandboxTest do
  use ExUnit.Case, async: false

  alias Druzhok.Sandbox.Local

  test "local exec runs command" do
    {:ok, result} = Local.exec("test", "echo hello")
    assert result.stdout =~ "hello"
    assert result.exit_code == 0
  end

  test "local read_file works" do
    path = Path.join(System.tmp_dir!(), "sandbox_test_read_#{:rand.uniform(100000)}")
    File.write!(path, "test content")
    {:ok, content} = Local.read_file("test", path)
    assert content == "test content"
    File.rm!(path)
  end

  test "local write_file works" do
    path = Path.join(System.tmp_dir!(), "sandbox_test_write_#{:rand.uniform(100000)}")
    :ok = Local.write_file("test", path, "written")
    assert File.read!(path) == "written"
    File.rm!(path)
  end

  test "local list_dir works" do
    {:ok, items} = Local.list_dir("test", System.tmp_dir!())
    assert is_list(items)
    assert Enum.all?(items, &Map.has_key?(&1, :name))
  end
end
```

- [ ] **Step 2: Write Docker sandbox tests (tagged @tag :docker)**

```elixir
@tag :docker
test "docker exec runs command in container" do
  # Create instance with sandbox: "docker"
  # Verify command runs inside container (check hostname differs from host)
end
```

- [ ] **Step 3: Verify all existing tests pass (backward compat)**

```bash
cd v3 && mix test --exclude docker
```

- [ ] **Step 4: Manual smoke test with Docker**

```bash
# Start server
mix phx.server
# Create instance in dashboard with sandbox: docker
# Send message to bot
# Check logs — tool calls should show exec via sandbox
# Verify files created inside container, not on host
```

- [ ] **Step 5: Commit**

```bash
git commit -m "add sandbox tests and verify backward compatibility"
```
