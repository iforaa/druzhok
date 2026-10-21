# V3 Code Quality & Tech Debt Cleanup

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Address all 17 code quality issues identified in the v3 review — DRY violations, hardcoded config, missing timeouts, unsafe code, monolithic modules, and test gaps.

**Architecture:** Refactor bottom-up: shared abstractions first (sandbox protocol, LLM tool assembly, config module), then split monolithic modules (Agent.Telegram, DashboardLive), then add safety nets (timeouts, rate limiting, validation). TDD throughout.

**Tech Stack:** Elixir 1.18, Phoenix 1.7 LiveView, Ecto/SQLite, ExUnit

---

## File Map

### New Files
| File | Responsibility |
|------|---------------|
| `apps/druzhok/lib/druzhok/sandbox/protocol.ex` | Shared TCP JSON-RPC GenServer for sandbox clients |
| `apps/druzhok/lib/druzhok/agent/router.ex` | Message classification & routing (extracted from telegram.ex) |
| `apps/druzhok/lib/druzhok/agent/streamer.ex` | Streaming accumulation & throttled edits (extracted from telegram.ex) |
| `apps/druzhok_web/lib/druzhok_web_web/live/components/event_log.ex` | Event log LiveComponent |
| `apps/druzhok_web/lib/druzhok_web_web/live/components/file_browser.ex` | File browser LiveComponent |
| `apps/druzhok_web/lib/druzhok_web_web/live/components/security_tab.ex` | Security tab LiveComponent |
| `apps/pi_core/lib/pi_core/config.ex` | Centralized configurable constants |
| `apps/pi_core/lib/pi_core/llm/tool_call_assembler.ex` | Shared streaming tool call assembly |
| `apps/druzhok/test/druzhok/sandbox/protocol_test.exs` | Protocol unit tests |
| `apps/druzhok/test/druzhok/agent/router_test.exs` | Router unit tests |
| `apps/druzhok/test/druzhok/agent/streamer_test.exs` | Streamer unit tests |
| `apps/pi_core/test/pi_core/llm/tool_call_assembler_test.exs` | Tool call assembly tests |
| `apps/pi_core/test/pi_core/config_test.exs` | Config tests |
| `apps/druzhok_web/test/druzhok_web_web/live/dashboard_live_test.exs` | Dashboard LiveView tests |
| `apps/druzhok_web/test/druzhok_web_web/controllers/auth_controller_test.exs` | Auth + rate limit tests |

### Modified Files
| File | Changes |
|------|---------|
| `apps/druzhok/lib/druzhok/sandbox/docker_client.ex` | Use Protocol, keep only Docker-specific init/terminate |
| `apps/druzhok/lib/druzhok/sandbox/firecracker_client.ex` | Use Protocol, keep only Firecracker-specific init/terminate |
| `apps/druzhok/lib/druzhok/sandbox/docker.ex` | Also DRY: merge with firecracker.ex pattern |
| `apps/druzhok/lib/druzhok/sandbox/firecracker.ex` | Also DRY: merge with docker.ex pattern |
| `apps/druzhok/lib/druzhok/agent/telegram.ex` | Delegate to Router and Streamer modules |
| `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex` | Use LiveComponents, fix unsafe atom, extract helpers |
| `apps/druzhok_web/lib/druzhok_web_web/controllers/auth_controller.ex` | Add rate limiting |
| `apps/pi_core/lib/pi_core/llm/openai.ex` | Use ToolCallAssembler |
| `apps/pi_core/lib/pi_core/llm/anthropic.ex` | Use ToolCallAssembler, make api_version configurable |
| `apps/pi_core/lib/pi_core/llm/client.ex` | Use explicit provider field |
| `apps/pi_core/lib/pi_core/loop.ex` | Use PiCore.Config for constants |
| `apps/pi_core/lib/pi_core/session.ex` | Use PiCore.Config for constants |
| `apps/pi_core/lib/pi_core/tools/bash.ex` | Add timeout with Task.async |
| `apps/druzhok/lib/druzhok/model.ex` | Return {:error, :not_found} instead of silent "openai" |
| `apps/druzhok/lib/druzhok/telegram/api.ex` | Fix multipart boundary spec compliance |
| `apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex` | Minor masking improvement |

---

## Task 1: Extract `PiCore.Config` — centralized constants

**Files:**
- Create: `apps/pi_core/lib/pi_core/config.ex`
- Create: `apps/pi_core/test/pi_core/config_test.exs`
- Modify: `apps/pi_core/lib/pi_core/loop.ex`
- Modify: `apps/pi_core/lib/pi_core/session.ex`
- Modify: `apps/pi_core/lib/pi_core/llm/anthropic.ex`

- [ ] **Step 1: Write config test**

```elixir
# apps/pi_core/test/pi_core/config_test.exs
defmodule PiCore.ConfigTest do
  use ExUnit.Case, async: true

  test "returns default values" do
    assert PiCore.Config.max_iterations() == 20
    assert PiCore.Config.max_tool_output() == 8_000
    assert PiCore.Config.idle_timeout_ms() == 7_200_000
    assert PiCore.Config.default_max_tokens() == 16_384
    assert PiCore.Config.compaction_max_messages() == 40
    assert PiCore.Config.compaction_keep_recent() == 10
    assert PiCore.Config.bash_timeout_ms() == 300_000
    assert PiCore.Config.anthropic_api_version() == "2023-06-01"
  end

  test "reads overrides from application env" do
    Application.put_env(:pi_core, :max_iterations, 10)
    assert PiCore.Config.max_iterations() == 10
  after
    Application.delete_env(:pi_core, :max_iterations)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/config_test.exs --trace`
Expected: FAIL — module PiCore.Config not found

- [ ] **Step 3: Implement PiCore.Config**

```elixir
# apps/pi_core/lib/pi_core/config.ex
defmodule PiCore.Config do
  @defaults [
    max_iterations: 20,
    max_tool_output: 8_000,
    idle_timeout_ms: 2 * 60 * 60 * 1000,
    default_max_tokens: 16_384,
    compaction_max_messages: 40,
    compaction_keep_recent: 10,
    bash_timeout_ms: 300_000,
    anthropic_api_version: "2023-06-01"
  ]

  for {key, default} <- @defaults do
    def unquote(key)() do
      Application.get_env(:pi_core, unquote(key), unquote(default))
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/config_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Replace hardcoded values in loop.ex**

In `apps/pi_core/lib/pi_core/loop.ex`:
- Replace `@max_iterations 20` with `PiCore.Config.max_iterations()`
- Replace `@max_tool_output 8_000` with `PiCore.Config.max_tool_output()`

- [ ] **Step 6: Replace hardcoded values in session.ex**

In `apps/pi_core/lib/pi_core/session.ex`:
- Replace `@idle_timeout_ms 2 * 60 * 60 * 1000` with `PiCore.Config.idle_timeout_ms()`
- Replace `max_tokens: 16384` with `max_tokens: PiCore.Config.default_max_tokens()`
- Replace `max_messages: 40` with `max_messages: PiCore.Config.compaction_max_messages()`
- Replace `keep_recent: 10` with `keep_recent: PiCore.Config.compaction_keep_recent()`

- [ ] **Step 7: Replace hardcoded api_version in anthropic.ex**

In `apps/pi_core/lib/pi_core/llm/anthropic.ex`:
- Replace `@api_version "2023-06-01"` with `PiCore.Config.anthropic_api_version()`

- [ ] **Step 8: Run full pi_core test suite**

Run: `cd v3 && mix test apps/pi_core/ --trace`
Expected: All existing tests still pass

- [ ] **Step 9: Commit**

```
feat(pi_core): extract PiCore.Config for centralized constants
```

---

## Task 2: Add bash tool timeout

**Files:**
- Modify: `apps/pi_core/lib/pi_core/tools/bash.ex`
- Modify: `apps/pi_core/test/pi_core/tools/bash_test.exs`

- [ ] **Step 1: Write timeout test**

Add to `apps/pi_core/test/pi_core/tools/bash_test.exs`:

```elixir
test "times out long-running commands" do
  tool = PiCore.Tools.Bash.new()
  context = %{workspace: System.tmp_dir!(), bash_timeout_ms: 100}
  result = tool.execute.(%{"command" => "sleep 10"}, context)
  assert {:error, msg} = result
  assert msg =~ "timed out"
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/tools/bash_test.exs --trace`
Expected: FAIL or hangs (current behavior has no timeout)

- [ ] **Step 3: Implement timeout in bash.ex**

Refactor `execute/2` in `apps/pi_core/lib/pi_core/tools/bash.ex` to extract timeout from context and wrap execution. Both sandbox and local paths need timeout support:

```elixir
def execute(%{"command" => command}, context) do
  timeout = Map.get(context, :bash_timeout_ms, PiCore.Config.bash_timeout_ms())

  case context do
    %{sandbox: %{exec: exec_fn}} ->
      run_with_timeout(fn -> exec_fn.(command) end, timeout)
    %{workspace: workspace} ->
      run_with_timeout(fn -> run_local(command, workspace) end, timeout)
  end
end

defp run_local(command, workspace) do
  {output, code} = System.cmd("bash", ["-c", command],
    stderr_to_stdout: true, cd: workspace)
  if code == 0, do: {:ok, output},
  else: {:error, "Exit code #{code}: #{output}"}
end

defp run_with_timeout(fun, timeout) do
  task = Task.async(fun)
  case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
    {:ok, result} -> result
    nil -> {:error, "Command timed out after #{div(timeout, 1000)}s"}
  end
end
```

- [ ] **Step 4: Run bash tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/tools/bash_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```
fix(pi_core): add timeout to bash tool execution (default 5min)
```

---

## Task 3: Fix unsafe `String.to_existing_atom` in DashboardLive

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Replace unsafe atom creation at line ~140**

Find the `handle_event("tab", ...)` handler and replace:
```elixir
# Before
{:noreply, assign(socket, tab: String.to_existing_atom(tab))}

# After
@valid_tabs %{"logs" => :logs, "files" => :files, "security" => :security}

def handle_event("tab", %{"tab" => tab}, socket) do
  case Map.get(@valid_tabs, tab) do
    nil -> {:noreply, socket}
    atom_tab -> {:noreply, assign(socket, tab: atom_tab)}
  end
end
```

- [ ] **Step 2: Run existing dashboard tests (if any) and manual verify**

Run: `cd v3 && mix test apps/druzhok_web/ --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```
fix(web): replace unsafe String.to_existing_atom with validated tab map
```

---

## Task 4: Extract `PiCore.LLM.ToolCallAssembler`

**Files:**
- Create: `apps/pi_core/lib/pi_core/llm/tool_call_assembler.ex`
- Create: `apps/pi_core/test/pi_core/llm/tool_call_assembler_test.exs`
- Modify: `apps/pi_core/lib/pi_core/llm/openai.ex`
- Modify: `apps/pi_core/lib/pi_core/llm/anthropic.ex`

- [ ] **Step 1: Write assembler tests**

```elixir
# apps/pi_core/test/pi_core/llm/tool_call_assembler_test.exs
defmodule PiCore.LLM.ToolCallAssemblerTest do
  use ExUnit.Case, async: true
  alias PiCore.LLM.ToolCallAssembler

  test "new returns empty state" do
    state = ToolCallAssembler.new()
    assert state.calls == []
  end

  test "start_call initializes a new tool call" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "tool_123", "my_tool")
    assert length(state.calls) == 1
    assert hd(state.calls).name == "my_tool"
  end

  test "append_args accumulates JSON fragments" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "tool_1", "bash")
    |> ToolCallAssembler.append_args(0, "{\"com")
    |> ToolCallAssembler.append_args(0, "mand\":\"ls\"}")

    [call] = ToolCallAssembler.finalize(state)
    assert call["function"]["arguments"] == "{\"command\":\"ls\"}"
  end

  test "handles multiple concurrent tool calls by index" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "t1", "bash")
    |> ToolCallAssembler.start_call(1, "t2", "read")
    |> ToolCallAssembler.append_args(0, "{\"a\":1}")
    |> ToolCallAssembler.append_args(1, "{\"b\":2}")

    calls = ToolCallAssembler.finalize(state)
    assert length(calls) == 2
  end

  test "finalize returns OpenAI-format tool_calls" do
    state = ToolCallAssembler.new()
    |> ToolCallAssembler.start_call(0, "call_abc", "read")
    |> ToolCallAssembler.append_args(0, "{\"path\":\"/tmp\"}")

    [call] = ToolCallAssembler.finalize(state)
    assert call["id"] == "call_abc"
    assert call["type"] == "function"
    assert call["function"]["name"] == "read"
    assert call["function"]["arguments"] == "{\"path\":\"/tmp\"}"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/llm/tool_call_assembler_test.exs --trace`
Expected: FAIL — module not found

- [ ] **Step 3: Implement ToolCallAssembler**

```elixir
# apps/pi_core/lib/pi_core/llm/tool_call_assembler.ex
defmodule PiCore.LLM.ToolCallAssembler do
  defstruct calls: []

  def new, do: %__MODULE__{}

  def start_call(%__MODULE__{calls: calls} = state, index, id, name) do
    entry = %{index: index, id: id, name: name, args_json: ""}
    %{state | calls: calls ++ [entry]}
  end

  def append_args(%__MODULE__{calls: calls} = state, index, fragment) do
    calls = Enum.map(calls, fn
      %{index: ^index} = c -> %{c | args_json: c.args_json <> fragment}
      c -> c
    end)
    %{state | calls: calls}
  end

  def finalize(%__MODULE__{calls: calls}) do
    Enum.map(calls, fn c ->
      %{
        "id" => c.id,
        "type" => "function",
        "function" => %{
          "name" => c.name,
          "arguments" => c.args_json
        }
      }
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/llm/tool_call_assembler_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Refactor openai.ex to use ToolCallAssembler**

Replace `merge_tool_calls/2` in `apps/pi_core/lib/pi_core/llm/openai.ex` with calls to `ToolCallAssembler.start_call/4` and `ToolCallAssembler.append_args/3`. Use `ToolCallAssembler.finalize/1` when building the final result.

- [ ] **Step 6: Refactor anthropic.ex to use ToolCallAssembler**

Replace `partial_tc` list and `update_partial_tc/2` / `finalize_stream_result/1` in `apps/pi_core/lib/pi_core/llm/anthropic.ex` with `ToolCallAssembler`. On `content_block_start` with tool_use type → `start_call`. On `input_json_delta` → `append_args`. On stream end → `finalize`.

- [ ] **Step 7: Run full LLM test suite**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/llm/ --trace`
Expected: All tests pass

- [ ] **Step 8: Commit**

```
refactor(pi_core): extract shared ToolCallAssembler from OpenAI/Anthropic clients
```

---

## Task 5: Extract `Druzhok.Sandbox.Protocol` — shared TCP GenServer

**Files:**
- Create: `apps/druzhok/lib/druzhok/sandbox/protocol.ex`
- Create: `apps/druzhok/test/druzhok/sandbox/protocol_test.exs`
- Modify: `apps/druzhok/lib/druzhok/sandbox/docker_client.ex`
- Modify: `apps/druzhok/lib/druzhok/sandbox/firecracker_client.ex`

- [ ] **Step 1: Write protocol test**

```elixir
# apps/druzhok/test/druzhok/sandbox/protocol_test.exs
defmodule Druzhok.Sandbox.ProtocolTest do
  use ExUnit.Case, async: true
  alias Druzhok.Sandbox.Protocol

  test "split_lines splits on newline" do
    assert Protocol.split_lines("a\nb\nc") == {["a", "b"], "c"}
  end

  test "split_lines with trailing newline" do
    assert Protocol.split_lines("a\nb\n") == {["a", "b"], ""}
  end

  test "split_lines with no newline" do
    assert Protocol.split_lines("partial") == {[], "partial"}
  end

  test "build_request creates JSON with id and type" do
    {json, 1} = Protocol.build_request(:exec, %{command: "ls"}, 0)
    decoded = Jason.decode!(json)
    assert decoded["id"] == "req-1"
    assert decoded["type"] == "exec"
    assert decoded["command"] == "ls"
  end

  test "process_line routes stdout to pending using iodata" do
    pending = %{"req-1" => %{from: nil, type: :exec, stdout: [], stderr: []}}
    {action, updated} = Protocol.process_line(
      ~s({"id":"req-1","type":"stdout","data":"hello"}), pending)
    assert action == :continue
    assert IO.iodata_to_binary(updated["req-1"].stdout) =~ "hello"
  end

  test "process_line completes on exit" do
    pending = %{"req-1" => %{from: nil, type: :exec, stdout: ["out"], stderr: []}}
    {action, _updated} = Protocol.process_line(
      ~s({"id":"req-1","type":"exit","code":0}), pending)
    assert {:reply, "req-1", {:ok, %{stdout: _, exit_code: 0}}} = action
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/sandbox/protocol_test.exs --trace`
Expected: FAIL — module not found

- [ ] **Step 3: Implement Protocol module**

Extract from docker_client.ex the shared functions: `split_lines/1`, `process_line/2`, `handle_response/4`, `build_request/3`, `next_id/1`, `send_request/2`, `reply_all_pending/2`, `init_workspace/1`, `copy_workspace_template/1`. These become public functions in `Druzhok.Sandbox.Protocol`.

```elixir
# apps/druzhok/lib/druzhok/sandbox/protocol.ex
defmodule Druzhok.Sandbox.Protocol do
  @moduledoc "Shared TCP JSON-RPC protocol for sandbox clients"
  require Logger

  defstruct [:socket, :instance_name, pending: %{}, counter: 0, buffer: ""]

  def split_lines(buffer) do
    parts = String.split(buffer, "\n")
    case parts do
      [single] -> {[], single}
      many ->
        {complete, [remainder]} = Enum.split(many, -1)
        {complete, remainder}
    end
  end

  def build_request(type, params, counter) do
    id = "req-#{counter + 1}"
    msg = Map.merge(%{"id" => id, "type" => to_string(type)}, stringify_keys(params))
    {Jason.encode!(msg) <> "\n", counter + 1}
  end

  def process_line(line, pending) do
    case Jason.decode(line) do
      {:ok, %{"id" => id, "type" => type} = msg} ->
        handle_response(id, type, msg, pending)
      _ ->
        {:continue, pending}
    end
  end

  def handle_tcp_data(data, %{buffer: buffer} = proto_state) do
    {lines, new_buffer} = split_lines(buffer <> data)
    {replies, new_pending} = Enum.reduce(lines, {[], proto_state.pending}, fn line, {replies, pend} ->
      case process_line(line, pend) do
        {:continue, pend} -> {replies, pend}
        {{:reply, id, result}, pend} -> {[{id, result} | replies], pend}
      end
    end)
    {replies, %{proto_state | buffer: new_buffer, pending: new_pending}}
  end

  def send_request(socket, data) do
    :gen_tcp.send(socket, data)
  end

  def add_pending(proto_state, id, from, type \\ :exec) do
    entry = %{from: from, type: type, stdout: [], stderr: []}
    %{proto_state | pending: Map.put(proto_state.pending, id, entry)}
  end

  def reply_all_pending(pending, reason) do
    Enum.each(pending, fn {_id, %{from: from}} ->
      if from, do: GenServer.reply(from, {:error, reason})
    end)
  end

  # ... handle_response clauses, init_workspace, copy_workspace_template
  # (extracted verbatim from docker_client.ex lines 140-339)

  # Use iodata accumulation (O(1) prepend) — matching existing docker_client.ex pattern
  defp handle_response(id, "stdout", %{"data" => data}, pending) do
    case Map.get(pending, id) do
      nil -> {:continue, pending}
      entry ->
        updated = %{entry | stdout: [entry.stdout | data]}
        {:continue, Map.put(pending, id, updated)}
    end
  end

  defp handle_response(id, "stderr", %{"data" => data}, pending) do
    case Map.get(pending, id) do
      nil -> {:continue, pending}
      entry ->
        updated = %{entry | stderr: [entry.stderr | data]}
        {:continue, Map.put(pending, id, updated)}
    end
  end

  defp handle_response(id, "exit", %{"code" => code}, pending) do
    case Map.pop(pending, id) do
      {nil, pending} -> {:continue, pending}
      {entry, pending} ->
        result = {:ok, %{
          stdout: IO.iodata_to_binary(entry.stdout),
          stderr: IO.iodata_to_binary(entry.stderr),
          exit_code: code
        }}
        {{:reply, id, result}, pending}
    end
  end

  defp handle_response(id, "result", %{"data" => data}, pending) do
    case Map.pop(pending, id) do
      {nil, pending} -> {:continue, pending}
      {_entry, pending} -> {{:reply, id, {:ok, data}}, pending}
    end
  end

  defp handle_response(id, "error", %{"message" => msg}, pending) do
    case Map.pop(pending, id) do
      {nil, pending} -> {:continue, pending}
      {_entry, pending} -> {{:reply, id, {:error, msg}}, pending}
    end
  end

  defp handle_response(_id, _type, _msg, pending), do: {:continue, pending}

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/sandbox/protocol_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Refactor DockerClient to use Protocol**

In `apps/druzhok/lib/druzhok/sandbox/docker_client.ex`:
- Remove duplicated functions: `split_lines`, `process_line`, `handle_response` (all 5 clauses), `next_id`, `reply_all_pending`, `init_workspace`, `copy_workspace_template`
- Add `alias Druzhok.Sandbox.Protocol`
- Keep struct with Docker-specific fields (`:container`, `:secret`) plus embed `proto: %Protocol{}`
- Keep `init/1` (Docker container startup), `terminate/2` (container cleanup), `start_container/2`, `connect_with_retry/5`
- Delegate TCP message handling to `Protocol.handle_tcp_data/2`
- Delegate request building to `Protocol.build_request/3`

- [ ] **Step 6: Refactor FirecrackerClient to use Protocol**

Same approach as DockerClient: keep only Firecracker-specific init (VM setup, vsock), terminate (Port.close, file cleanup), and transport. Delegate protocol handling to `Protocol`.

- [ ] **Step 7: Run full sandbox tests**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/sandbox_test.exs --trace`
Expected: PASS

- [ ] **Step 8: Also DRY the docker.ex / firecracker.ex facade modules**

Both `Druzhok.Sandbox.Docker` and `Druzhok.Sandbox.Firecracker` have identical `with_client/2`, `stop/1` implementations. Extract to a shared macro or function in `Druzhok.Sandbox`:

```elixir
# In sandbox.ex, add:
defmacro __using__(opts) do
  client_module = opts[:client]
  quote do
    @behaviour Druzhok.Sandbox

    @impl true
    def start(_instance_name, _opts), do: {:ok, :started}

    @impl true
    def stop(instance_name) do
      case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
        [{pid, _}] -> GenServer.stop(pid, :normal, 10_000)
        [] -> :ok
      end
    end

    @impl true
    def exec(instance_name, command),
      do: with_client(instance_name, &unquote(client_module).exec(&1, command))

    @impl true
    def read_file(instance_name, path),
      do: with_client(instance_name, &unquote(client_module).read_file(&1, path))

    @impl true
    def write_file(instance_name, path, content),
      do: with_client(instance_name, &unquote(client_module).write_file(&1, path, content))

    @impl true
    def list_dir(instance_name, path),
      do: with_client(instance_name, &unquote(client_module).list_dir(&1, path))

    defp with_client(instance_name, fun) do
      case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
        [{pid, _}] -> fun.(pid)
        [] -> {:error, "Sandbox not running"}
      end
    end
  end
end
```

Then docker.ex becomes: `use Druzhok.Sandbox, client: Druzhok.Sandbox.DockerClient`
And firecracker.ex becomes: `use Druzhok.Sandbox, client: Druzhok.Sandbox.FirecrackerClient`

- [ ] **Step 9: Run all tests**

Run: `cd v3 && mix test --trace`
Expected: All pass

- [ ] **Step 10: Commit**

```
refactor(sandbox): extract shared Protocol module, DRY facade with __using__ macro
```

---

## Task 6: Add logging to `Model.get_provider/1` fallback

**Files:**
- Modify: `apps/druzhok/lib/druzhok/model.ex`

- [ ] **Step 1: Add Logger.debug when falling back to default provider**

In `apps/druzhok/lib/druzhok/model.ex`, add `require Logger` and a debug log when model_id isn't found in DB:

```elixir
def get_provider(model_id) do
  case Druzhok.Repo.get_by(__MODULE__, model_id: model_id) do
    nil ->
      Logger.debug("Model #{model_id} not in DB, defaulting to openai provider")
      "openai"
    m -> m.provider || "openai"
  end
end
```

- [ ] **Step 2: Run tests**

Run: `cd v3 && mix test --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```
fix(model): add debug logging when get_provider falls back to default
```

---

## Task 7: Fix Telegram API multipart boundary

**Files:**
- Modify: `apps/druzhok/lib/druzhok/telegram/api.ex`

- [ ] **Step 1: Verify and fix multipart_body function**

Read `apps/druzhok/lib/druzhok/telegram/api.ex` and verify the multipart structure. Per RFC 2046, each part starts with `--boundary\r\n`, contains headers and body, and the message ends with `--boundary--\r\n`. Verify each part's `\r\n` endings are correct. Only change code if an actual spec violation is found — if the existing code works correctly with Telegram API, add a comment explaining the format and move on.

- [ ] **Step 2: Run tests**

Run: `cd v3 && mix test --trace`
Expected: PASS

- [ ] **Step 3: Commit**

```
fix(telegram): correct multipart boundary formatting per RFC 2046
```

---

## Task 8: Improve LLM provider detection in client.ex

**Files:**
- Modify: `apps/pi_core/lib/pi_core/llm/client.ex`
- Modify: `apps/pi_core/test/pi_core/llm/client_test.exs`

- [ ] **Step 1: Add test for explicit provider field**

Add to `apps/pi_core/test/pi_core/llm/client_test.exs`:

```elixir
test "uses explicit provider when given" do
  opts = %{provider: "anthropic", model: "some-custom-model", api_url: "https://example.com"}
  assert PiCore.LLM.Client.detect_provider(opts) == :anthropic
end

test "falls back to heuristic when no provider" do
  opts = %{model: "claude-sonnet-4-20250514", api_url: "https://api.anthropic.com"}
  assert PiCore.LLM.Client.detect_provider(opts) == :anthropic
end
```

- [ ] **Step 2: Update client.ex to check explicit provider first**

```elixir
def detect_provider(opts) do
  cond do
    opts[:provider] == "anthropic" -> :anthropic
    String.starts_with?(opts.model || "", "claude") -> :anthropic
    String.contains?(opts[:api_url] || "", "anthropic") -> :anthropic
    true -> :openai
  end
end
```

- [ ] **Step 3: Run tests**

Run: `cd v3 && mix test apps/pi_core/test/pi_core/llm/client_test.exs --trace`
Expected: PASS

- [ ] **Step 4: Commit**

```
feat(pi_core): support explicit provider field in LLM client routing
```

---

## Task 9: Add auth rate limiting

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/controllers/auth_controller.ex`
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/auth_controller_test.exs`

- [ ] **Step 1: Create ETS table at app startup**

In `apps/druzhok_web/lib/druzhok_web/application.ex`, add to `start/2` before the supervisor:
```elixir
:ets.new(:auth_rate_limit, [:set, :public, :named_table])
```

- [ ] **Step 2: Write rate limit test**

```elixir
# apps/druzhok_web/test/druzhok_web_web/controllers/auth_controller_test.exs
defmodule DruzhokWebWeb.AuthControllerTest do
  use DruzhokWebWeb.ConnCase

  test "rate limits login attempts after 5 failures", %{conn: conn} do
    for _ <- 1..5 do
      post(conn, "/auth/session", %{email: "bad", password: "bad"})
    end

    conn = post(conn, "/auth/session", %{email: "bad", password: "bad"})
    assert redirected_to(conn) =~ "/login"
    assert get_flash(conn, :error) =~ "Too many"
  end
end
```

- [ ] **Step 3: Implement rate limiter in auth_controller.ex**

In `apps/druzhok_web/lib/druzhok_web_web/controllers/auth_controller.ex`:

```elixir
@max_attempts 5
@window_ms 60_000

defp check_rate_limit(conn) do
  ip = conn.remote_ip |> :inet.ntoa() |> to_string()
  now = System.monotonic_time(:millisecond)

  case :ets.lookup(:auth_rate_limit, ip) do
    [{^ip, count, first_at}] when now - first_at < @window_ms and count >= @max_attempts ->
      :rate_limited
    [{^ip, count, first_at}] when now - first_at < @window_ms ->
      :ets.insert(:auth_rate_limit, {ip, count + 1, first_at})
      :ok
    _ ->
      :ets.insert(:auth_rate_limit, {ip, 1, now})
      :ok
  end
end
```

Add rate limit check at top of `create_session`:
```elixir
def create_session(conn, params) do
  case check_rate_limit(conn) do
    :rate_limited ->
      conn |> put_flash(:error, "Too many login attempts. Try again later.") |> redirect(to: "/login")
    :ok ->
      # existing logic
  end
end
```

- [ ] **Step 4: Run test**

Run: `cd v3 && mix test apps/druzhok_web/test/druzhok_web_web/controllers/auth_controller_test.exs --trace`
Expected: PASS

- [ ] **Step 5: Commit**

```
feat(web): add ETS-based rate limiting to login endpoint
```

---

## Task 10: Split `Agent.Telegram` into Router + Streamer

**Files:**
- Create: `apps/druzhok/lib/druzhok/agent/router.ex`
- Create: `apps/druzhok/lib/druzhok/agent/streamer.ex`
- Create: `apps/druzhok/test/druzhok/agent/router_test.exs`
- Create: `apps/druzhok/test/druzhok/agent/streamer_test.exs`
- Modify: `apps/druzhok/lib/druzhok/agent/telegram.ex`

- [ ] **Step 1: Write router tests**

```elixir
# apps/druzhok/test/druzhok/agent/router_test.exs
defmodule Druzhok.Agent.RouterTest do
  use ExUnit.Case, async: true
  alias Druzhok.Agent.Router

  test "classifies private chat as :dm" do
    update = %{"message" => %{"chat" => %{"type" => "private"}, "from" => %{"id" => 123}}}
    assert Router.classify(update) == {:dm, 123}
  end

  test "classifies group chat" do
    update = %{"message" => %{"chat" => %{"type" => "group", "id" => -100}, "from" => %{"id" => 456}}}
    assert Router.classify(update) == {:group, -100, 456}
  end

  test "extracts text from message" do
    update = %{"message" => %{"text" => "hello", "chat" => %{"type" => "private"}}}
    assert Router.extract_text(update) == "hello"
  end

  test "extracts caption as text" do
    update = %{"message" => %{"caption" => "photo caption", "chat" => %{"type" => "private"}}}
    assert Router.extract_text(update) == "photo caption"
  end

  test "detects bot mention trigger" do
    assert Router.triggered?("@mybot hello", "mybot", nil)
  end

  test "detects name regex trigger" do
    regex = ~r/друг/iu
    assert Router.triggered?("привет друг", nil, regex)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd v3 && mix test apps/druzhok/test/druzhok/agent/router_test.exs --trace`
Expected: FAIL

- [ ] **Step 3: Implement Router — extract from telegram.ex**

Extract `classify/1` (from `handle_update`), `extract_text/1` and `extract_file/1` (from `extract_message`), `triggered?/3` (from trigger detection functions at lines 410-431).

- [ ] **Step 4: Write streamer tests**

```elixir
# apps/druzhok/test/druzhok/agent/streamer_test.exs
defmodule Druzhok.Agent.StreamerTest do
  use ExUnit.Case, async: true
  alias Druzhok.Agent.Streamer

  test "accumulates text deltas" do
    state = Streamer.new()
    state = Streamer.append(state, "Hello ")
    state = Streamer.append(state, "world")
    assert Streamer.text(state) == "Hello world"
  end

  test "should_send? returns false before min chars" do
    state = Streamer.new(min_chars: 30)
    state = Streamer.append(state, "Hi")
    refute Streamer.should_send?(state)
  end

  test "should_send? returns true after min chars" do
    state = Streamer.new(min_chars: 5)
    state = Streamer.append(state, "Hello world, this is long enough")
    assert Streamer.should_send?(state)
  end

  test "throttles edits to 1 per second" do
    state = Streamer.new() |> Streamer.mark_sent(System.monotonic_time(:millisecond))
    refute Streamer.should_edit?(state, System.monotonic_time(:millisecond))
  end
end
```

- [ ] **Step 5: Implement Streamer — extract from telegram.ex**

Extract streaming state (draft_text, draft_message_id, last_edit_at) and functions: `append/2`, `should_send?/1`, `should_edit?/2`, `mark_sent/2`, `reset/1` from the `:pi_delta` and `:pi_response` handlers (lines 143-260).

- [ ] **Step 6: Refactor telegram.ex to delegate**

Replace inline routing logic with `Router.classify/1`, `Router.extract_text/1`, `Router.triggered?/3`. Replace streaming state management with `Streamer` struct operations.

- [ ] **Step 7: Run all druzhok tests**

Run: `cd v3 && mix test apps/druzhok/ --trace`
Expected: PASS

- [ ] **Step 8: Commit**

```
refactor(telegram): extract Router and Streamer from monolithic Agent.Telegram
```

---

## Task 11: Extract DashboardLive into LiveComponents

**Files:**
- Create: `apps/druzhok_web/lib/druzhok_web_web/live/components/event_log.ex`
- Create: `apps/druzhok_web/lib/druzhok_web_web/live/components/file_browser.ex`
- Create: `apps/druzhok_web/lib/druzhok_web_web/live/components/security_tab.ex`
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Create EventLog component**

Extract the event log rendering (lines ~328-349) and event formatting helpers (lines ~432-498) into a stateless function component or LiveComponent:

```elixir
# apps/druzhok_web/lib/druzhok_web_web/live/components/event_log.ex
defmodule DruzhokWebWeb.Live.Components.EventLog do
  use Phoenix.Component

  attr :events, :list, required: true

  def event_log(assigns) do
    ~H"""
    <div class="space-y-1 font-mono text-sm max-h-96 overflow-y-auto">
      <%= for event <- @events do %>
        <div class={"p-2 rounded #{event_bg(event)}"}>
          <span class={"font-bold #{event_color(event)}"}><%= event_label(event) %></span>
          <span class="text-gray-300 ml-2"><%= event.text %></span>
          <span class="text-gray-500 text-xs float-right"><%= event.time %></span>
        </div>
      <% end %>
    </div>
    """
  end

  # Move event_label, event_color, event_bg, event_text helpers here
end
```

- [ ] **Step 2: Create FileBrowser component**

Extract file listing (lines ~351-371) and file content view into a component:

```elixir
# apps/druzhok_web/lib/druzhok_web_web/live/components/file_browser.ex
defmodule DruzhokWebWeb.Live.Components.FileBrowser do
  use Phoenix.Component

  attr :files, :list, required: true
  attr :file_content, :string, default: nil
  attr :instance_name, :string, required: true
  # ... render file list or content view
end
```

- [ ] **Step 3: Create SecurityTab component**

Extract security section (lines ~373-424) into component with pairing and group management.

- [ ] **Step 4: Update DashboardLive to use components**

Replace inline HTML sections with component calls. The render function should shrink from ~230 lines to ~50 lines.

- [ ] **Step 5: Run web tests**

Run: `cd v3 && mix test apps/druzhok_web/ --trace`
Expected: PASS

- [ ] **Step 6: Commit**

```
refactor(web): extract EventLog, FileBrowser, SecurityTab components from DashboardLive
```

---

## Task 12: Add DashboardLive tests

**Files:**
- Create: `apps/druzhok_web/test/druzhok_web_web/live/dashboard_live_test.exs`

- [ ] **Step 1: Write LiveView tests**

```elixir
# apps/druzhok_web/test/druzhok_web_web/live/dashboard_live_test.exs
defmodule DruzhokWebWeb.DashboardLiveTest do
  use DruzhokWebWeb.ConnCase
  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    user = Druzhok.User.create_admin!("test@test.com", "password123")
    conn = conn |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "renders dashboard", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Instances"
  end

  test "tab switching works with valid tabs", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # Use render_click on the tab element to trigger handle_event("tab", ...)
    html = view |> element("[phx-click=tab][phx-value-tab=files]") |> render_click()
    assert html =~ "Files"
  end

  test "invalid tab via handle_event does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    # Push an event with an invalid tab name — should be silently ignored
    html = render_click(view, "tab", %{"tab" => "nonexistent"})
    # Should still render without crashing
    assert html =~ "Instances"
  end
end
```

- [ ] **Step 2: Run test**

Run: `cd v3 && mix test apps/druzhok_web/test/druzhok_web_web/live/dashboard_live_test.exs --trace`
Expected: PASS (may need ConnCase helper for auth)

- [ ] **Step 3: Commit**

```
test(web): add DashboardLive tests for tab switching and rendering
```

---

## Task 13: Improve settings masking

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Improve masking detection**

Replace `"****"` string check in `non_masked/1` with a more robust check. The current approach assumes `****` never appears in real keys. Instead, check if the value matches the masked pattern (starts with 4 chars + contains `*` runs):

```elixir
defp non_masked(value) do
  if value && value != "" && !String.contains?(value, "****") do
    value
  else
    nil
  end
end
```

This is actually fine as-is since API keys never contain `****`. Leave as-is but add a comment explaining why.

- [ ] **Step 2: Commit (skip if no change needed)**

---

## ~~Task 14: Fix list cons in sandbox clients~~ (REMOVED)

The existing `[entry.stdout | data]` pattern is intentional iodata accumulation (O(1) prepend, finalized with `IO.iodata_to_binary/1`). This is the correct Elixir pattern. The Protocol extraction in Task 5 preserves this approach.

---

## Task 15: Add Firecracker rootfs note (documentation only)

This is a performance optimization (copy-on-write for rootfs) that requires infrastructure changes (btrfs/overlayfs). Skip for now — add a TODO comment in firecracker_client.ex near the `File.cp/2` call:

- [ ] **Step 1: Add TODO comment**

```elixir
# TODO: Use copy-on-write (overlayfs/btrfs snapshot) instead of full copy
# Current: ~100MB per instance, grows linearly
File.cp!(base_rootfs, rootfs_path)
```

- [ ] **Step 2: Commit**

```
docs: add TODO for rootfs copy-on-write optimization
```

---

## Task 16: Fix DRY in DashboardLive file listing

This is covered by Task 11 (FileBrowser component extraction). The duplicated `list_workspace_files/1` logic for docker vs local will be consolidated in the component.

---

## Task 17: Anthropic default URL should be configurable

Already handled by Task 1 (PiCore.Config) — the `@api_version` is now configurable. The default URL `"https://api.anthropic.com"` is already read from config/runtime.exs via `Application.get_env(:druzhok, :anthropic_api_url)`, so no additional change needed.

---

## Verification

After all tasks complete:

1. **Run full test suite:**
   ```bash
   cd v3 && mix test --trace
   ```

2. **Run formatter:**
   ```bash
   cd v3 && mix format --check-formatted
   ```

3. **Compile with warnings as errors:**
   ```bash
   cd v3 && mix compile --warnings-as-errors
   ```

4. **Manual smoke test:**
   - Start the app: `cd v3 && mix phx.server`
   - Login to dashboard at localhost:4000
   - Switch tabs (verify no crash on invalid tab)
   - Create an instance (verify sandbox detection)
   - Check event log renders
   - Check file browser works

5. **Verify no regressions:**
   - All 28 existing test files still pass
   - New tests bring total to ~35+ test files
