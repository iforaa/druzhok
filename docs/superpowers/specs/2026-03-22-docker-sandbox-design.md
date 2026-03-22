# Docker Sandbox — Design Spec

## Goal

Isolate agent tool execution inside Docker containers so agents can't access the host filesystem or processes. Workspace files live inside the container. Communication via TCP with a Go agent binary.

## Architecture

```
Druzhok (BEAM, runs on host)
  │
  TCP (JSON line protocol, port 9999)
  │
  Docker container "igor-sandbox"
  ├── Agent binary (Go, listens on :9999)
  ├── /workspace (agent's home, files live here)
  ├── Python3, Node.js, git, curl
  └── No API keys, no DB access
```

One container per instance. Container starts with the instance, stops when instance stops.

## Agent Binary (Go)

A static Go binary (~5MB) that runs inside the container. Listens on TCP port 9999. Handles file and shell operations.

### Protocol

JSON line protocol — one JSON object per line, newline-delimited (`\n`).

**Request format:**
```json
{"id": "req-1", "type": "exec", "command": "ls -la"}
{"id": "req-2", "type": "read", "path": "/workspace/file.txt"}
{"id": "req-3", "type": "write", "path": "/workspace/file.txt", "content": "hello"}
{"id": "req-4", "type": "mkdir", "path": "/workspace/subdir"}
{"id": "req-5", "type": "ls", "path": "/workspace"}
{"id": "req-6", "type": "stat", "path": "/workspace/file.txt"}
```

**Response format:**
```json
{"id": "req-1", "type": "stdout", "data": "file1.txt\nfile2.txt\n"}
{"id": "req-1", "type": "stderr", "data": "warning: something\n"}
{"id": "req-1", "type": "exit", "code": 0}
{"id": "req-2", "type": "result", "data": "file content here"}
{"id": "req-2", "type": "error", "message": "file not found"}
```

**Exec streaming:** For `exec` commands, stdout/stderr are streamed as multiple `stdout`/`stderr` messages as they arrive. The final `exit` message signals completion with the exit code. This enables real-time streaming of long-running commands.

**Request IDs:** Each request has a unique `id`. Responses include the same `id` for correlation. This allows concurrent requests over a single connection.

### Commands

| Type | Description | Response |
|------|-------------|----------|
| `exec` | Run shell command via `bash -c` | Stream `stdout`/`stderr` chunks, then `exit` with code |
| `read` | Read file content | `result` with file content, or `error` |
| `write` | Write content to file (creates dirs) | `result` with `"ok"`, or `error` |
| `mkdir` | Create directory recursively | `result` with `"ok"`, or `error` |
| `ls` | List directory entries | `result` with JSON array of `{name, is_dir, size}` |
| `stat` | Get file info | `result` with `{size, is_dir, modified}`, or `error` |

### Timeouts

- `exec`: 5 minute timeout per command (configurable). If exceeded, process is killed and `exit` with code -1 is sent.
- `read`/`write`/other: 30 second timeout.

### Working directory

All commands execute with `/workspace` as the working directory. Relative paths in `exec` commands resolve relative to `/workspace`.

## Agent Binary Security

### Authentication

The agent binary requires authentication on connect. A random secret is generated per container (passed via `SANDBOX_SECRET` env var). The first message from the client must be `{"type": "auth", "secret": "..."}`. The agent responds with `{"type": "auth_ok"}` or closes the connection. All subsequent messages without prior auth are rejected.

### Path restriction

The agent binary enforces that all `read`, `write`, `mkdir`, `ls`, `stat` paths resolve to under `/workspace` after symlink resolution (`filepath.EvalSymlinks` in Go). Paths outside `/workspace` return an error. `exec` commands are not path-restricted — the agent runs them as-is via `bash -c`, but the container filesystem limits what's accessible.

### Single connection

The agent accepts only one TCP connection at a time. If a second connection arrives, it is rejected. This prevents other processes on the host from connecting.

## Container Image

Dockerfile:
```dockerfile
FROM alpine:3.20

RUN apk add --no-cache \
    bash python3 py3-pip nodejs npm git curl wget \
    build-base openssh-client jq

COPY sandbox-agent /usr/local/bin/sandbox-agent

WORKDIR /workspace
EXPOSE 9999

ENTRYPOINT ["sandbox-agent"]
```

Image is built once, shared by all instances. Each instance gets its own container from the same image.

## Tool Routing

### Tools that run inside the container

| Tool | Implementation |
|------|---------------|
| `bash` | Send `exec` command to agent |
| `read` | Send `read` command to agent |
| `write` | Send `write` command to agent |
| `edit` | `read` via agent, compute diff on host, `write` via agent |
| `find` | Send `exec` with `find` command to agent |
| `grep` | Send `exec` with `grep` command to agent |

### Tools that stay on the host

| Tool | Reason |
|------|--------|
| `memory_search` | Needs embeddings API call + BM25 computation. Reads memory files via agent `read` command. |
| `set_reminder` | Needs DB access |
| `send_file` | Reads file via agent, then sends to Telegram API |

### PathGuard

`PiCore.Tools.PathGuard` becomes unnecessary for sandboxed tools — the container filesystem IS the sandbox. PathGuard only applies in `local` mode.

## Tool-Sandbox Interface (Dependency Solution)

`pi_core` tools cannot depend on `Druzhok.Sandbox` (that would be a circular dependency). Instead, sandbox functions are injected via `extra_tool_context`, the same pattern already used for `send_file_fn`.

Tools receive a `sandbox` map in context with function references:

```elixir
# In extra_tool_context (built by Instance.Sup):
%{
  sandbox: %{
    exec: fn command -> ... end,
    exec_stream: fn command, on_output -> ... end,
    read_file: fn path -> ... end,
    write_file: fn path, content -> ... end,
    list_dir: fn path -> ... end,
  }
}
```

When `sandbox` is nil (local mode), tools use direct `System.cmd` / `File.read` as they do today. When `sandbox` is set, tools call the sandbox functions instead.

Each tool checks:
```elixir
def execute(%{"command" => cmd}, context) do
  case context[:sandbox] do
    %{exec: exec_fn} -> exec_fn.(cmd)
    nil -> System.cmd("bash", ["-c", cmd], ...) # current behavior
  end
end
```

This keeps pi_core decoupled — it never imports Druzhok modules.

## Sandbox Behaviour

```elixir
defmodule Druzhok.Sandbox do
  @callback start(instance_name :: String.t(), opts :: map()) :: {:ok, pid()} | {:error, term()}
  @callback stop(instance_name :: String.t()) :: :ok
  @callback exec(instance_name :: String.t(), command :: String.t()) :: {:ok, %{stdout: String.t(), stderr: String.t(), exit_code: integer()}} | {:error, term()}
  @callback exec_stream(instance_name :: String.t(), command :: String.t(), on_output :: (String.t() -> any())) :: {:ok, integer()} | {:error, term()}
  @callback read_file(instance_name :: String.t(), path :: String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback write_file(instance_name :: String.t(), path :: String.t(), content :: String.t()) :: :ok | {:error, term()}
  @callback list_dir(instance_name :: String.t(), path :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback file_exists?(instance_name :: String.t(), path :: String.t()) :: boolean()
end
```

### Implementations

**`Druzhok.Sandbox.Local`** — current behavior. Tools execute directly on host. No container. Default for dev.

**`Druzhok.Sandbox.Docker`** — creates Docker container, connects via TCP to agent binary. Tools execute inside container.

**`Druzhok.Sandbox.Firecracker`** — future. Same protocol over vsock instead of TCP.

### Configuration

Per-instance `sandbox` field in the `instances` table. Values: `"local"`, `"docker"`. Default: `"local"`.

Dashboard shows a sandbox selector per instance. Admin can change it (requires instance restart).

## Druzhok.Sandbox.Docker Implementation

### Container lifecycle

```elixir
def start(instance_name, opts) do
  container_name = "druzhok-#{instance_name}"
  secret = :crypto.strong_rand_bytes(16) |> Base.encode64()

  # Check Docker is available
  case System.find_executable("docker") do
    nil -> {:error, "Docker not installed"}
    _ ->
      # Create and start container with auth secret
      {_, 0} = System.cmd("docker", [
        "run", "-d",
        "--name", container_name,
        "--memory", "1g",
        "--cpus", "1",
        "--cap-drop", "ALL",
        "--cap-add", "CHOWN", "--cap-add", "SETUID", "--cap-add", "SETGID",
        "--security-opt", "no-new-privileges",
        "-e", "SANDBOX_SECRET=#{secret}",
        "-p", "0:9999",
        "druzhok-sandbox:latest"
      ])

      # Get assigned port
      {port_str, 0} = System.cmd("docker", ["port", container_name, "9999"])
      port = parse_port(port_str)

      # Connect TCP with retry (container may still be starting)
      socket = connect_with_retry("127.0.0.1", port, secret, 10, 500)

      {:ok, socket}
  end
end

defp connect_with_retry(_host, _port, _secret, 0, _delay), do: {:error, "connection timeout"}
defp connect_with_retry(host, port, secret, retries, delay) do
  case :gen_tcp.connect(~c"#{host}", port, [:binary, packet: :line, active: false], 2_000) do
    {:ok, socket} ->
      # Authenticate
      :gen_tcp.send(socket, Jason.encode!(%{type: "auth", secret: secret}) <> "\n")
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, line} ->
          case Jason.decode!(String.trim(line)) do
            %{"type" => "auth_ok"} -> {:ok, socket}
            _ -> {:error, "auth failed"}
          end
        _ -> {:error, "auth timeout"}
      end
    {:error, _} ->
      Process.sleep(delay)
      connect_with_retry(host, port, secret, retries - 1, delay)
  end
end
```

### Connection management

The TCP connection is managed by a `Druzhok.Sandbox.DockerClient` GenServer per instance. It:
- Maintains the TCP connection
- Handles reconnection if the connection drops
- Multiplexes concurrent requests via request IDs
- Is supervised under the instance's Supervisor
- On `start`, checks `System.find_executable("docker")` and returns `{:error, "Docker not installed"}` if missing

### Copy workspace template on first start

When the container starts fresh (no existing workspace):
1. Agent binary creates `/workspace` if it doesn't exist
2. Druzhok copies workspace template files into the container via `write` commands
3. AGENTS.md, SOUL.md, IDENTITY.md, etc. are written via the agent protocol

### File access from dashboard

The dashboard file browser uses the Sandbox behaviour:
```elixir
# Instead of:
File.ls!(workspace_path)

# Now:
Druzhok.Sandbox.list_dir(instance_name, "/workspace")
```

### send_file flow

1. Session calls `send_file` tool
2. Tool calls `Sandbox.read_file(instance_name, path)` to get file content from container
3. Writes to a temp file on host
4. Sends via Telegram API
5. Deletes temp file

### save_incoming_file flow

1. Telegram receives file from user
2. Downloads via Telegram API to host temp file
3. Calls `Sandbox.write_file(instance_name, "/workspace/inbox/filename", content)` to write into container
4. Deletes host temp file

### memory_search in sandbox mode

Memory files live inside the container. `memory_search` needs to read them:
1. `Sandbox.read_file(instance_name, "/workspace/MEMORY.md")`
2. `Sandbox.list_dir(instance_name, "/workspace/memory")`
3. Read each memory file via `Sandbox.read_file`
4. Run BM25 + embeddings on host
5. Return results

This is slower than direct file access but acceptable since memory_search is not a hot path.

## Instance.Sup Changes

Add `Druzhok.Sandbox.DockerClient` as a child of the instance Supervisor:

```
Instance.Sup
├── Telegram
├── SessionSup
├── Scheduler
└── DockerClient (only when sandbox == "docker")
```

## Data Model

Add to `instances` table:
```sql
ALTER TABLE instances ADD COLUMN sandbox TEXT DEFAULT 'local';
```

## Dashboard Changes

- Instance detail top bar: show sandbox mode (local/docker)
- Settings or instance config: dropdown to change sandbox mode
- File browser: route through Sandbox behaviour instead of direct filesystem

## Testing

1. **Agent binary unit tests** (Go) — exec, read, write, ls, stat, streaming
2. **SandboxClient connection test** — connect, send command, receive response
3. **Tool execution via sandbox** — bash tool sends exec to sandbox, gets result
4. **File operations via sandbox** — read/write/edit through sandbox
5. **Container lifecycle** — start, stop, restart
6. **Local sandbox backward compat** — all existing tests still pass with `sandbox: "local"`

## Files

### New (Go agent)
- `services/sandbox-agent/main.go` — agent binary
- `services/sandbox-agent/Dockerfile` — container image
- `services/sandbox-agent/go.mod`

### New (Elixir)
- `apps/druzhok/lib/druzhok/sandbox.ex` — behaviour
- `apps/druzhok/lib/druzhok/sandbox/local.ex` — current behavior, no container
- `apps/druzhok/lib/druzhok/sandbox/docker.ex` — Docker implementation
- `apps/druzhok/lib/druzhok/sandbox/docker_client.ex` — TCP connection GenServer

### Modified
- `apps/pi_core/lib/pi_core/tools/bash.ex` — route through sandbox
- `apps/pi_core/lib/pi_core/tools/read.ex` — route through sandbox
- `apps/pi_core/lib/pi_core/tools/write.ex` — route through sandbox
- `apps/pi_core/lib/pi_core/tools/edit.ex` — route through sandbox
- `apps/pi_core/lib/pi_core/tools/find.ex` — route through sandbox
- `apps/pi_core/lib/pi_core/tools/grep.ex` — route through sandbox
- `apps/pi_core/lib/pi_core/tools/send_file.ex` — read via sandbox
- `apps/pi_core/lib/pi_core/memory/search.ex` — read memory files via sandbox
- `apps/druzhok/lib/druzhok/instance.ex` — add sandbox field
- `apps/druzhok/lib/druzhok/instance/sup.ex` — add DockerClient child
- `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` — file browser via sandbox
- Migration for sandbox column
