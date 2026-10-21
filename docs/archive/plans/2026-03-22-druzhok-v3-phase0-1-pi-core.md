# Druzhok v3 Phase 0+1: Repo Reorg + pi_core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move v2 to subdirectory, create the Elixir umbrella app, and build pi_core — a standalone agent loop library that can call LLMs, execute tools, and manage sessions. Validated against real Nebius API.

**Architecture:** Elixir umbrella app with pi_core as the first app. Pi_core is a standalone library: GenServer for session management, pure function for the agent loop, Finch for HTTP/SSE streaming. No Telegram, no Phoenix — just the agent core.

**Tech Stack:** Elixir 1.17+, OTP 27+, Finch, Jason, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-22-druzhok-v3-elixir-design.md`

**Environment:** `NEBIUS_API_KEY` and `NEBIUS_BASE_URL` must be set for integration tests.

---

## File Structure

```
druzhok/
├── v2/                              # current TypeScript project (moved here)
├── v3/                              # new Elixir project
│   ├── mix.exs                      # umbrella root
│   ├── config/
│   │   ├── config.exs
│   │   └── runtime.exs
│   ├── apps/
│   │   └── pi_core/
│   │       ├── mix.exs
│   │       ├── lib/
│   │       │   ├── pi_core.ex               # public API module
│   │       │   ├── pi_core/
│   │       │   │   ├── session.ex           # GenServer: state, parallelism
│   │       │   │   ├── loop.ex              # pure function: agent loop
│   │       │   │   ├── llm/
│   │       │   │   │   ├── client.ex        # Finch HTTP POST + streaming
│   │       │   │   │   └── sse_parser.ex    # parse SSE data lines
│   │       │   │   ├── tools/
│   │       │   │   │   ├── tool.ex          # struct definition
│   │       │   │   │   ├── schema.ex        # serialize to OpenAI format
│   │       │   │   │   ├── bash.ex          # bash tool
│   │       │   │   │   ├── read.ex          # read file tool
│   │       │   │   │   ├── write.ex         # write file tool
│   │       │   │   │   └── edit.ex          # find/replace tool
│   │       │   │   ├── workspace_loader.ex  # behaviour + default impl
│   │       │   │   └── session_store.ex     # JSONL persistence
│   │       └── test/
│   │           ├── test_helper.exs
│   │           ├── pi_core/
│   │           │   ├── llm/
│   │           │   │   ├── client_test.exs
│   │           │   │   └── sse_parser_test.exs
│   │           │   ├── tools/
│   │           │   │   ├── schema_test.exs
│   │           │   │   ├── bash_test.exs
│   │           │   │   ├── read_test.exs
│   │           │   │   └── write_test.exs
│   │           │   ├── loop_test.exs
│   │           │   ├── session_test.exs
│   │           │   ├── workspace_loader_test.exs
│   │           │   └── session_store_test.exs
│   │           └── integration/
│   │               └── nebius_test.exs      # real API calls
├── docs/                            # shared (stays at root)
└── workspace-template/              # shared (stays at root)
```

---

### Task 1: Repo Reorg

**Files:**
- Move: entire project except `docs/`, `workspace-template/`, `.git/`, `.claude/` → `v2/`
- Create: `v3/` umbrella structure

- [ ] **Step 1: Move v2 code**

```bash
mkdir v2
# Move everything except docs, workspace-template, .git, .claude, .gitignore
for item in packages src services docker tests *.json *.yaml *.ts .env* druzhok.json; do
  [ -e "$item" ] && mv "$item" v2/
done
```

- [ ] **Step 2: Create umbrella app**

```bash
cd v3 # (will be created by mix)
cd ..
mix new v3 --umbrella
cd v3
```

- [ ] **Step 3: Create pi_core app**

```bash
cd v3/apps
mix new pi_core
```

- [ ] **Step 4: Configure umbrella mix.exs**

`v3/mix.exs` — verify it has:
```elixir
def project do
  [
    apps_path: "apps",
    version: "0.1.0",
    start_permanent: Mix.env() == :prod,
    deps: deps()
  ]
end
```

- [ ] **Step 5: Add dependencies to pi_core**

`v3/apps/pi_core/mix.exs`:
```elixir
defp deps do
  [
    {:finch, "~> 0.19"},
    {:jason, "~> 1.4"},
  ]
end
```

- [ ] **Step 6: Create runtime config**

`v3/config/config.exs`:
```elixir
import Config
config :pi_core, :default_api_url, "https://api.tokenfactory.us-central1.nebius.com/v1"
```

`v3/config/runtime.exs`:
```elixir
import Config
config :pi_core, :api_key, System.get_env("NEBIUS_API_KEY")
config :pi_core, :api_url, System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"
```

- [ ] **Step 7: Start Finch in pi_core application**

`v3/apps/pi_core/lib/pi_core/application.ex`:
```elixir
defmodule PiCore.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Finch, name: PiCore.Finch}
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: PiCore.Supervisor)
  end
end
```

Update `v3/apps/pi_core/mix.exs` to add `mod: {PiCore.Application, []}` to `application/0`.

- [ ] **Step 8: Verify build**

```bash
cd v3
mix deps.get
mix compile
mix test
```

- [ ] **Step 9: Commit**

```bash
git add v2/ v3/
git commit -m "reorg: move v2 to subdirectory, create v3 Elixir umbrella with pi_core"
```

---

### Task 2: SSE Parser

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/llm/sse_parser.ex`
- Create: `v3/apps/pi_core/test/pi_core/llm/sse_parser_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/pi_core/llm/sse_parser_test.exs
defmodule PiCore.LLM.SSEParserTest do
  use ExUnit.Case

  alias PiCore.LLM.SSEParser

  test "parses single data line" do
    {events, rest} = SSEParser.parse("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n", "")
    assert length(events) == 1
    assert hd(events)["choices"] |> hd() |> get_in(["delta", "content"]) == "hi"
  end

  test "parses multiple events" do
    input = """
    data: {"choices":[{"delta":{"content":"hel"}}]}

    data: {"choices":[{"delta":{"content":"lo"}}]}

    """
    {events, _rest} = SSEParser.parse(input, "")
    assert length(events) == 2
  end

  test "handles [DONE]" do
    {events, _rest} = SSEParser.parse("data: [DONE]\n\n", "")
    assert events == [:done]
  end

  test "handles partial data across chunks" do
    {events1, rest} = SSEParser.parse("data: {\"ch", "")
    assert events1 == []

    {events2, _rest} = SSEParser.parse("oices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", rest)
    assert length(events2) == 1
  end

  test "ignores non-data lines" do
    {events, _rest} = SSEParser.parse("event: message\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", "")
    assert length(events) == 1
  end

  test "handles reasoning_content" do
    input = ~s(data: {"choices":[{"delta":{"content":"","reasoning_content":"thinking..."}}]}\n\n)
    {events, _rest} = SSEParser.parse(input, "")
    assert length(events) == 1
    delta = hd(events)["choices"] |> hd() |> Map.get("delta")
    assert delta["reasoning_content"] == "thinking..."
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd v3 && mix test test/pi_core/llm/sse_parser_test.exs
```

- [ ] **Step 3: Implement sse_parser.ex**

```elixir
# lib/pi_core/llm/sse_parser.ex
defmodule PiCore.LLM.SSEParser do
  @doc """
  Parse SSE stream data. Returns {parsed_events, remaining_buffer}.
  Events are decoded JSON maps or :done atom.
  """
  def parse(chunk, buffer) do
    full = buffer <> chunk
    lines = String.split(full, "\n")

    # Last element might be incomplete
    {complete_lines, [rest]} = Enum.split(lines, -1)

    events =
      complete_lines
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&String.trim_leading(&1, "data: "))
      |> Enum.flat_map(fn
        "[DONE]" -> [:done]
        json_str ->
          case Jason.decode(json_str) do
            {:ok, data} -> [data]
            _ -> []
          end
      end)

    {events, rest}
  end
end
```

- [ ] **Step 4: Run tests**

```bash
cd v3 && mix test test/pi_core/llm/sse_parser_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add v3/apps/pi_core/lib/pi_core/llm/ v3/apps/pi_core/test/pi_core/llm/
git commit -m "add SSE parser for LLM streaming"
```

---

### Task 3: LLM Client

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/llm/client.ex`
- Create: `v3/apps/pi_core/test/pi_core/llm/client_test.exs`
- Create: `v3/apps/pi_core/test/integration/nebius_test.exs`

- [ ] **Step 1: Write unit test with mock**

```elixir
# test/pi_core/llm/client_test.exs
defmodule PiCore.LLM.ClientTest do
  use ExUnit.Case

  alias PiCore.LLM.Client

  test "build_request creates correct body" do
    request = Client.build_request(%{
      model: "zai-org/GLM-5",
      api_url: "https://example.com/v1",
      api_key: "test-key",
      system_prompt: "You are helpful",
      messages: [%{role: "user", content: "hello"}],
      tools: [],
      max_tokens: 1000,
      stream: true
    })

    assert request.url == "https://example.com/v1/chat/completions"
    assert request.headers["authorization"] == "Bearer test-key"

    body = Jason.decode!(request.body)
    assert body["model"] == "zai-org/GLM-5"
    assert body["stream"] == true
    assert body["max_tokens"] == 1000
    assert length(body["messages"]) == 2
    assert hd(body["messages"])["role"] == "system"
  end

  test "build_request includes tools when present" do
    tools = [%{
      type: "function",
      function: %{
        name: "bash",
        description: "Run command",
        parameters: %{type: "object", properties: %{command: %{type: "string"}}, required: ["command"]}
      }
    }]

    request = Client.build_request(%{
      model: "test", api_url: "https://example.com/v1", api_key: "k",
      system_prompt: "test", messages: [], tools: tools, max_tokens: 100, stream: false
    })

    body = Jason.decode!(request.body)
    assert length(body["tools"]) == 1
    assert hd(body["tools"])["function"]["name"] == "bash"
  end
end
```

- [ ] **Step 2: Write integration test**

```elixir
# test/integration/nebius_test.exs
defmodule PiCore.Integration.NebiusTest do
  use ExUnit.Case

  @moduletag :integration

  @tag :integration
  test "streaming completion with Nebius" do
    api_key = System.get_env("NEBIUS_API_KEY")
    api_url = System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"

    if is_nil(api_key) do
      IO.puts("Skipping: NEBIUS_API_KEY not set")
    else
      {:ok, result} = PiCore.LLM.Client.completion(%{
        model: "Qwen/Qwen3-235B-A22B-Instruct-2507",
        api_url: api_url,
        api_key: api_key,
        system_prompt: "Reply in one word only.",
        messages: [%{role: "user", content: "Say hello"}],
        tools: [],
        max_tokens: 100,
        stream: true,
        on_delta: fn delta -> IO.write(delta) end
      })

      assert is_binary(result.content)
      assert String.length(result.content) > 0
    end
  end

  @tag :integration
  test "non-streaming completion" do
    api_key = System.get_env("NEBIUS_API_KEY")
    api_url = System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"

    if is_nil(api_key) do
      IO.puts("Skipping: NEBIUS_API_KEY not set")
    else
      {:ok, result} = PiCore.LLM.Client.completion(%{
        model: "Qwen/Qwen3-235B-A22B-Instruct-2507",
        api_url: api_url,
        api_key: api_key,
        system_prompt: "Reply in one word only.",
        messages: [%{role: "user", content: "Say hello"}],
        tools: [],
        max_tokens: 100,
        stream: false
      })

      assert is_binary(result.content)
      assert String.length(result.content) > 0
    end
  end

  @tag :integration
  test "tool calling" do
    api_key = System.get_env("NEBIUS_API_KEY")
    api_url = System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"

    if is_nil(api_key) do
      IO.puts("Skipping: NEBIUS_API_KEY not set")
    else
      tools = [%{
        type: "function",
        function: %{
          name: "read",
          description: "Read a file",
          parameters: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]}
        }
      }]

      {:ok, result} = PiCore.LLM.Client.completion(%{
        model: "Qwen/Qwen3-235B-A22B-Instruct-2507",
        api_url: api_url,
        api_key: api_key,
        system_prompt: "You have access to tools. Use them when needed.",
        messages: [%{role: "user", content: "Read the file test.txt"}],
        tools: tools,
        max_tokens: 500,
        stream: true
      })

      assert length(result.tool_calls) > 0
      assert hd(result.tool_calls)["function"]["name"] == "read"
    end
  end
end
```

- [ ] **Step 3: Implement client.ex**

```elixir
# lib/pi_core/llm/client.ex
defmodule PiCore.LLM.Client do
  alias PiCore.LLM.SSEParser

  defmodule Request do
    defstruct [:url, :headers, :body]
  end

  defmodule Result do
    defstruct content: "", tool_calls: [], reasoning: ""
  end

  def build_request(opts) do
    messages = [%{role: "system", content: opts.system_prompt} | opts.messages]

    body = %{
      model: opts.model,
      messages: messages,
      max_tokens: opts.max_tokens,
      stream: opts.stream
    }

    body = if opts.tools != [] do
      Map.put(body, :tools, opts.tools)
    else
      body
    end

    %Request{
      url: "#{String.trim_trailing(opts.api_url, "/")}/chat/completions",
      headers: %{
        "content-type" => "application/json",
        "authorization" => "Bearer #{opts.api_key}",
        "accept-encoding" => "identity"
      },
      body: Jason.encode!(body)
    }
  end

  def completion(opts) do
    request = build_request(opts)

    if opts.stream do
      stream_completion(request, opts[:on_delta])
    else
      sync_completion(request)
    end
  end

  defp stream_completion(request, on_delta) do
    ref = Finch.build(:post, request.url, Map.to_list(request.headers), request.body)

    result = %Result{}
    buffer = ""

    Finch.stream(ref, PiCore.Finch, {result, buffer}, fn
      {:status, status}, {result, buffer} when status in 200..299 ->
        {result, buffer}

      {:status, status}, {_result, buffer} ->
        {%Result{content: "HTTP error: #{status}"}, buffer}

      {:headers, _headers}, acc ->
        acc

      {:data, data}, {result, buffer} ->
        {events, new_buffer} = SSEParser.parse(data, buffer)

        new_result = Enum.reduce(events, result, fn
          :done, acc -> acc
          event, acc -> process_stream_event(event, acc, on_delta)
        end)

        {new_result, new_buffer}
    end)
    |> case do
      {:ok, {result, _buffer}} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_stream_event(event, result, on_delta) do
    choices = event["choices"] || []

    Enum.reduce(choices, result, fn choice, acc ->
      delta = choice["delta"] || %{}

      # Text content
      acc = if delta["content"] && delta["content"] != "" do
        new_content = acc.content <> delta["content"]
        if on_delta, do: on_delta.(delta["content"])
        %{acc | content: new_content}
      else
        acc
      end

      # Reasoning content
      acc = if delta["reasoning_content"] && delta["reasoning_content"] != "" do
        %{acc | reasoning: acc.reasoning <> delta["reasoning_content"]}
      else
        acc
      end

      # Tool calls
      acc = if delta["tool_calls"] do
        merge_tool_calls(acc, delta["tool_calls"])
      else
        acc
      end

      # Final message (non-streaming format in some events)
      acc = if choice["message"] do
        msg = choice["message"]
        acc = if msg["content"], do: %{acc | content: msg["content"]}, else: acc
        acc = if msg["tool_calls"], do: %{acc | tool_calls: msg["tool_calls"]}, else: acc
        acc
      else
        acc
      end

      acc
    end)
  end

  defp merge_tool_calls(result, incoming_calls) do
    Enum.reduce(incoming_calls, result, fn call, acc ->
      index = call["index"] || 0
      existing = Enum.at(acc.tool_calls, index)

      if existing do
        # Merge arguments
        updated = Map.update!(existing, "function", fn f ->
          Map.update!(f, "arguments", fn args ->
            args <> (get_in(call, ["function", "arguments"]) || "")
          end)
        end)
        %{acc | tool_calls: List.replace_at(acc.tool_calls, index, updated)}
      else
        # New tool call
        new_call = %{
          "id" => call["id"],
          "type" => "function",
          "function" => %{
            "name" => get_in(call, ["function", "name"]) || "",
            "arguments" => get_in(call, ["function", "arguments"]) || ""
          }
        }
        %{acc | tool_calls: acc.tool_calls ++ [new_call]}
      end
    end)
  end

  defp sync_completion(request) do
    case Finch.build(:post, request.url, Map.to_list(request.headers), request.body)
         |> Finch.request(PiCore.Finch) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        data = Jason.decode!(body)
        choice = hd(data["choices"])
        message = choice["message"]
        {:ok, %Result{
          content: message["content"] || "",
          tool_calls: message["tool_calls"] || [],
          reasoning: message["reasoning_content"] || ""
        }}

      {:ok, %{status: status, body: body}} ->
        {:error, "HTTP #{status}: #{body}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run unit tests**

```bash
cd v3 && mix test test/pi_core/llm/client_test.exs
```

- [ ] **Step 5: Run integration tests**

```bash
cd v3 && NEBIUS_API_KEY=your_key mix test test/integration/ --include integration
```

- [ ] **Step 6: Commit**

```bash
git commit -m "add LLM client with streaming SSE and tool call support"
```

---

### Task 4: Tool System

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/tools/tool.ex`
- Create: `v3/apps/pi_core/lib/pi_core/tools/schema.ex`
- Create: `v3/apps/pi_core/lib/pi_core/tools/bash.ex`
- Create: `v3/apps/pi_core/lib/pi_core/tools/read.ex`
- Create: `v3/apps/pi_core/lib/pi_core/tools/write.ex`
- Create: `v3/apps/pi_core/lib/pi_core/tools/edit.ex`
- Create: `v3/apps/pi_core/test/pi_core/tools/schema_test.exs`
- Create: `v3/apps/pi_core/test/pi_core/tools/bash_test.exs`
- Create: `v3/apps/pi_core/test/pi_core/tools/read_test.exs`
- Create: `v3/apps/pi_core/test/pi_core/tools/write_test.exs`

- [ ] **Step 1: Write tool struct and schema tests**

```elixir
# test/pi_core/tools/schema_test.exs
defmodule PiCore.Tools.SchemaTest do
  use ExUnit.Case

  alias PiCore.Tools.{Tool, Schema}

  test "converts tool to OpenAI format" do
    tool = %Tool{
      name: "bash",
      description: "Run a bash command",
      parameters: %{
        command: %{type: :string, description: "Command to run"}
      },
      execute: fn _args, _ctx -> {:ok, "output"} end
    }

    openai = Schema.to_openai(tool)
    assert openai["type"] == "function"
    assert openai["function"]["name"] == "bash"
    assert openai["function"]["parameters"]["properties"]["command"]["type"] == "string"
    assert "command" in openai["function"]["parameters"]["required"]
  end

  test "converts list of tools" do
    tools = [
      %Tool{name: "bash", description: "Run cmd", parameters: %{command: %{type: :string}}, execute: fn _, _ -> {:ok, ""} end},
      %Tool{name: "read", description: "Read file", parameters: %{path: %{type: :string}}, execute: fn _, _ -> {:ok, ""} end},
    ]

    openai_list = Schema.to_openai_list(tools)
    assert length(openai_list) == 2
    names = Enum.map(openai_list, & &1["function"]["name"])
    assert "bash" in names
    assert "read" in names
  end
end
```

- [ ] **Step 2: Write tool execution tests**

```elixir
# test/pi_core/tools/bash_test.exs
defmodule PiCore.Tools.BashTest do
  use ExUnit.Case

  test "executes command and returns output" do
    tool = PiCore.Tools.Bash.new()
    {:ok, output} = tool.execute.(%{"command" => "echo hello"}, %{workspace: "/tmp"})
    assert String.trim(output) == "hello"
  end

  test "returns error for failed command" do
    tool = PiCore.Tools.Bash.new()
    {:error, _} = tool.execute.(%{"command" => "exit 1"}, %{workspace: "/tmp"})
  end
end

# test/pi_core/tools/read_test.exs
defmodule PiCore.Tools.ReadTest do
  use ExUnit.Case

  setup do
    dir = System.tmp_dir!() |> Path.join("pi_core_test_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "test.txt"), "hello world")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "reads file content", %{workspace: ws} do
    tool = PiCore.Tools.Read.new()
    {:ok, content} = tool.execute.(%{"path" => "test.txt"}, %{workspace: ws})
    assert content == "hello world"
  end

  test "returns error for missing file", %{workspace: ws} do
    tool = PiCore.Tools.Read.new()
    {:error, _} = tool.execute.(%{"path" => "missing.txt"}, %{workspace: ws})
  end

  test "blocks path traversal", %{workspace: ws} do
    tool = PiCore.Tools.Read.new()
    {:error, msg} = tool.execute.(%{"path" => "../../../etc/passwd"}, %{workspace: ws})
    assert msg =~ "denied"
  end
end

# test/pi_core/tools/write_test.exs
defmodule PiCore.Tools.WriteTest do
  use ExUnit.Case

  setup do
    dir = System.tmp_dir!() |> Path.join("pi_core_write_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "writes file", %{workspace: ws} do
    tool = PiCore.Tools.Write.new()
    {:ok, _} = tool.execute.(%{"path" => "out.txt", "content" => "hello"}, %{workspace: ws})
    assert File.read!(Path.join(ws, "out.txt")) == "hello"
  end

  test "creates subdirectories", %{workspace: ws} do
    tool = PiCore.Tools.Write.new()
    {:ok, _} = tool.execute.(%{"path" => "sub/dir/file.txt", "content" => "deep"}, %{workspace: ws})
    assert File.read!(Path.join(ws, "sub/dir/file.txt")) == "deep"
  end

  test "blocks path traversal", %{workspace: ws} do
    tool = PiCore.Tools.Write.new()
    {:error, msg} = tool.execute.(%{"path" => "../../etc/evil", "content" => "bad"}, %{workspace: ws})
    assert msg =~ "denied"
  end
end
```

- [ ] **Step 3: Implement tool.ex, schema.ex, bash.ex, read.ex, write.ex, edit.ex**

```elixir
# lib/pi_core/tools/tool.ex
defmodule PiCore.Tools.Tool do
  defstruct [:name, :description, :parameters, :execute]
end

# lib/pi_core/tools/schema.ex
defmodule PiCore.Tools.Schema do
  alias PiCore.Tools.Tool

  def to_openai(%Tool{} = tool) do
    properties = Map.new(tool.parameters, fn {name, spec} ->
      prop = %{"type" => to_string(spec[:type] || spec.type)}
      prop = if spec[:description], do: Map.put(prop, "description", spec[:description] || spec.description), else: prop
      {to_string(name), prop}
    end)

    required = Map.keys(tool.parameters) |> Enum.map(&to_string/1)

    %{
      "type" => "function",
      "function" => %{
        "name" => tool.name,
        "description" => tool.description,
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => required
        }
      }
    }
  end

  def to_openai_list(tools), do: Enum.map(tools, &to_openai/1)
end

# lib/pi_core/tools/bash.ex
defmodule PiCore.Tools.Bash do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "bash",
      description: "Run a bash command. Use for shell commands, installing packages, running scripts.",
      parameters: %{command: %{type: :string, description: "Bash command to execute"}},
      execute: &execute/2
    }
  end

  def execute(%{"command" => command}, %{workspace: workspace}) do
    case System.cmd("bash", ["-c", command], cd: workspace, stderr_to_stdout: true, into: "", timeout: 60_000) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "Exit code #{code}: #{output}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end

# lib/pi_core/tools/read.ex
defmodule PiCore.Tools.Read do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "read",
      description: "Read a file from the workspace.",
      parameters: %{path: %{type: :string, description: "File path relative to workspace"}},
      execute: &execute/2
    }
  end

  def execute(%{"path" => path}, %{workspace: workspace}) do
    full_path = Path.join(workspace, path) |> Path.expand()
    workspace_abs = Path.expand(workspace)

    if String.starts_with?(full_path, workspace_abs) do
      case File.read(full_path) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
      end
    else
      {:error, "Access denied: path outside workspace"}
    end
  end
end

# lib/pi_core/tools/write.ex
defmodule PiCore.Tools.Write do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "write",
      description: "Write content to a file in the workspace. Creates directories if needed.",
      parameters: %{
        path: %{type: :string, description: "File path relative to workspace"},
        content: %{type: :string, description: "Content to write"}
      },
      execute: &execute/2
    }
  end

  def execute(%{"path" => path, "content" => content}, %{workspace: workspace}) do
    full_path = Path.join(workspace, path) |> Path.expand()
    workspace_abs = Path.expand(workspace)

    if String.starts_with?(full_path, workspace_abs) do
      File.mkdir_p!(Path.dirname(full_path))
      File.write!(full_path, content)
      {:ok, "Written: #{path}"}
    else
      {:error, "Access denied: path outside workspace"}
    end
  end
end

# lib/pi_core/tools/edit.ex
defmodule PiCore.Tools.Edit do
  alias PiCore.Tools.Tool

  def new do
    %Tool{
      name: "edit",
      description: "Find and replace text in a file.",
      parameters: %{
        path: %{type: :string, description: "File path"},
        old_string: %{type: :string, description: "Text to find"},
        new_string: %{type: :string, description: "Replacement text"}
      },
      execute: &execute/2
    }
  end

  def execute(%{"path" => path, "old_string" => old, "new_string" => new}, %{workspace: workspace}) do
    full_path = Path.join(workspace, path) |> Path.expand()
    workspace_abs = Path.expand(workspace)

    if String.starts_with?(full_path, workspace_abs) do
      case File.read(full_path) do
        {:ok, content} ->
          if String.contains?(content, old) do
            File.write!(full_path, String.replace(content, old, new, global: false))
            {:ok, "Edited: #{path}"}
          else
            {:error, "String not found in #{path}"}
          end
        {:error, reason} -> {:error, "Cannot read #{path}: #{reason}"}
      end
    else
      {:error, "Access denied: path outside workspace"}
    end
  end
end
```

- [ ] **Step 4: Run all tool tests**

```bash
cd v3 && mix test test/pi_core/tools/
```

- [ ] **Step 5: Commit**

```bash
git commit -m "add tool system with bash, read, write, edit"
```

---

### Task 5: Agent Loop

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/loop.ex`
- Create: `v3/apps/pi_core/test/pi_core/loop_test.exs`

- [ ] **Step 1: Write loop tests with mock LLM**

```elixir
# test/pi_core/loop_test.exs
defmodule PiCore.LoopTest do
  use ExUnit.Case

  alias PiCore.Loop
  alias PiCore.LLM.Client.Result

  # Mock LLM that returns a text response
  defp mock_llm_text(text) do
    fn _opts -> {:ok, %Result{content: text, tool_calls: []}} end
  end

  # Mock LLM that first returns a tool call, then text
  defp mock_llm_with_tool(tool_name, tool_args, tool_result_text, final_text) do
    call_count = :counters.new(1, [:atomics])
    fn _opts ->
      count = :counters.get(call_count, 1)
      :counters.add(call_count, 1, 1)
      if count == 0 do
        {:ok, %Result{content: "", tool_calls: [
          %{"id" => "call_1", "function" => %{"name" => tool_name, "arguments" => Jason.encode!(tool_args)}}
        ]}}
      else
        {:ok, %Result{content: final_text, tool_calls: []}}
      end
    end
  end

  test "simple text response" do
    result = Loop.run(%{
      system_prompt: "Be brief.",
      messages: [%{role: "user", content: "Hi"}],
      tools: [],
      llm_fn: mock_llm_text("Hello!"),
    })

    assert {:ok, messages} = result
    assistant_msg = Enum.find(messages, & &1.role == "assistant")
    assert assistant_msg.content == "Hello!"
  end

  test "tool call loop" do
    read_tool = %PiCore.Tools.Tool{
      name: "read",
      description: "Read file",
      parameters: %{path: %{type: :string}},
      execute: fn %{"path" => _path}, _ctx ->
        {:ok, "file content here"}
      end
    }

    result = Loop.run(%{
      system_prompt: "Use tools.",
      messages: [%{role: "user", content: "Read test.txt"}],
      tools: [read_tool],
      tool_context: %{workspace: "/tmp"},
      llm_fn: mock_llm_with_tool("read", %{path: "test.txt"}, "file content here", "The file contains: file content here"),
    })

    assert {:ok, messages} = result
    # Should have: user, assistant (tool call), tool_result, assistant (final)
    roles = Enum.map(messages, & &1.role)
    assert "toolResult" in roles
    final = List.last(messages)
    assert final.content =~ "file content"
  end

  test "unknown tool returns error" do
    result = Loop.run(%{
      system_prompt: "test",
      messages: [%{role: "user", content: "test"}],
      tools: [],
      llm_fn: fn _opts ->
        {:ok, %Result{content: "", tool_calls: [
          %{"id" => "call_1", "function" => %{"name" => "unknown_tool", "arguments" => "{}"}}
        ]}}
      end,
    })

    assert {:ok, messages} = result
    tool_result = Enum.find(messages, & &1.role == "toolResult")
    assert tool_result.content =~ "not found"
  end
end
```

- [ ] **Step 2: Implement loop.ex**

```elixir
# lib/pi_core/loop.ex
defmodule PiCore.Loop do
  alias PiCore.Tools.Schema

  defmodule Message do
    defstruct [:role, :content, :tool_calls, :tool_call_id, :tool_name, :is_error, :timestamp]
  end

  @doc """
  Run the agent loop. Pure function — no GenServer, no side effects except tool execution.

  opts:
    - system_prompt: string
    - messages: list of messages (conversation history)
    - tools: list of PiCore.Tools.Tool
    - tool_context: map passed to tool execute functions (e.g. %{workspace: "..."})
    - llm_fn: function that calls the LLM (injected for testing)
    - on_delta: optional callback for streaming deltas

  Returns {:ok, new_messages} or {:error, reason}
  """
  def run(opts) do
    tools = opts[:tools] || []
    tool_context = opts[:tool_context] || %{}
    openai_tools = Schema.to_openai_list(tools)
    new_messages = []

    loop(opts, openai_tools, tools, tool_context, new_messages, 0)
  end

  defp loop(_opts, _openai_tools, _tools, _tool_context, messages, iterations) when iterations > 20 do
    {:error, "Too many iterations (#{iterations})"}
  end

  defp loop(opts, openai_tools, tools, tool_context, new_messages, iterations) do
    all_messages = opts.messages ++ new_messages

    llm_messages = Enum.map(all_messages, fn msg ->
      case msg do
        %{role: "toolResult"} = m ->
          %{role: "tool", tool_call_id: m.tool_call_id, content: m.content}
        %{role: role} = m when role in ["user", "assistant", "system"] ->
          base = %{role: role, content: m.content || ""}
          if m[:tool_calls] && m.tool_calls != [] do
            Map.put(base, :tool_calls, m.tool_calls)
          else
            base
          end
        other -> other
      end
    end)

    llm_opts = %{
      system_prompt: opts.system_prompt,
      messages: llm_messages,
      tools: openai_tools,
      on_delta: opts[:on_delta]
    }

    case opts.llm_fn.(llm_opts) do
      {:ok, result} ->
        assistant_msg = %Message{
          role: "assistant",
          content: result.content,
          tool_calls: result.tool_calls,
          timestamp: System.os_time(:millisecond)
        }

        new_messages = new_messages ++ [assistant_msg]

        if result.tool_calls == [] do
          {:ok, new_messages}
        else
          # Execute tools
          tool_results = execute_tool_calls(result.tool_calls, tools, tool_context)
          new_messages = new_messages ++ tool_results
          loop(opts, openai_tools, tools, tool_context, new_messages, iterations + 1)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_tool_calls(tool_calls, tools, context) do
    Enum.map(tool_calls, fn call ->
      tool_name = get_in(call, ["function", "name"])
      raw_args = get_in(call, ["function", "arguments"]) || "{}"
      tool_call_id = call["id"]

      tool = Enum.find(tools, & &1.name == tool_name)

      {content, is_error} = if tool do
        case Jason.decode(raw_args) do
          {:ok, args} ->
            case tool.execute.(args, context) do
              {:ok, output} -> {output, false}
              {:error, reason} -> {reason, true}
            end
          {:error, _} -> {"Invalid JSON arguments: #{raw_args}", true}
        end
      else
        {"Tool #{tool_name} not found", true}
      end

      %Message{
        role: "toolResult",
        content: content,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        is_error: is_error,
        timestamp: System.os_time(:millisecond)
      }
    end)
  end
end
```

- [ ] **Step 3: Run tests**

```bash
cd v3 && mix test test/pi_core/loop_test.exs
```

- [ ] **Step 4: Commit**

```bash
git commit -m "add agent loop with tool execution"
```

---

### Task 6: Workspace Loader + Session Store

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/workspace_loader.ex`
- Create: `v3/apps/pi_core/lib/pi_core/session_store.ex`
- Create: `v3/apps/pi_core/test/pi_core/workspace_loader_test.exs`
- Create: `v3/apps/pi_core/test/pi_core/session_store_test.exs`

- [ ] **Step 1: Write tests**

```elixir
# test/pi_core/workspace_loader_test.exs
defmodule PiCore.WorkspaceLoaderTest do
  use ExUnit.Case

  setup do
    dir = System.tmp_dir!() |> Path.join("pi_core_ws_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "AGENTS.md"), "# Instructions\nBe helpful.")
    File.write!(Path.join(dir, "SOUL.md"), "# Soul\nBe genuine.")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "loads workspace files into system prompt", %{workspace: ws} do
    prompt = PiCore.WorkspaceLoader.Default.load(ws, %{})
    assert prompt =~ "Be helpful."
    assert prompt =~ "Be genuine."
  end

  test "handles missing files gracefully", %{workspace: ws} do
    File.rm!(Path.join(ws, "SOUL.md"))
    prompt = PiCore.WorkspaceLoader.Default.load(ws, %{})
    assert prompt =~ "Be helpful."
    refute prompt =~ "Be genuine."
  end

  test "handles empty workspace" do
    dir = System.tmp_dir!() |> Path.join("empty_ws_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    prompt = PiCore.WorkspaceLoader.Default.load(dir, %{})
    assert is_binary(prompt)
    File.rm_rf!(dir)
  end
end

# test/pi_core/session_store_test.exs
defmodule PiCore.SessionStoreTest do
  use ExUnit.Case

  alias PiCore.SessionStore
  alias PiCore.Loop.Message

  setup do
    dir = System.tmp_dir!() |> Path.join("pi_core_store_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "save and load messages", %{dir: dir} do
    messages = [
      %Message{role: "user", content: "hello", timestamp: 1},
      %Message{role: "assistant", content: "hi", timestamp: 2},
    ]

    SessionStore.save(dir, messages)
    loaded = SessionStore.load(dir)
    assert length(loaded) == 2
    assert hd(loaded).content == "hello"
  end

  test "load returns empty for missing file", %{dir: dir} do
    assert SessionStore.load(dir) == []
  end

  test "append adds to existing", %{dir: dir} do
    SessionStore.save(dir, [%Message{role: "user", content: "first", timestamp: 1}])
    SessionStore.append(dir, %Message{role: "assistant", content: "second", timestamp: 2})
    loaded = SessionStore.load(dir)
    assert length(loaded) == 2
  end
end
```

- [ ] **Step 2: Implement**

```elixir
# lib/pi_core/workspace_loader.ex
defmodule PiCore.WorkspaceLoader do
  @callback load(workspace :: String.t(), opts :: map()) :: String.t()
end

defmodule PiCore.WorkspaceLoader.Default do
  @behaviour PiCore.WorkspaceLoader

  @files ["AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md"]

  def load(workspace, _opts) do
    @files
    |> Enum.map(fn file ->
      path = Path.join(workspace, file)
      case File.read(path) do
        {:ok, content} -> content
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> "You are a helpful AI assistant."
      prompt -> prompt
    end
  end
end

# lib/pi_core/session_store.ex
defmodule PiCore.SessionStore do
  alias PiCore.Loop.Message

  @filename "session.jsonl"

  def save(dir, messages) do
    path = Path.join(dir, @filename)
    content = messages
      |> Enum.map(&encode_message/1)
      |> Enum.join("\n")
    File.write!(path, content <> "\n")
  end

  def append(dir, message) do
    path = Path.join(dir, @filename)
    File.write!(path, encode_message(message) <> "\n", [:append])
  end

  def load(dir) do
    path = Path.join(dir, @filename)
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_message/1)
        |> Enum.reject(&is_nil/1)
      {:error, _} -> []
    end
  end

  def clear(dir) do
    path = Path.join(dir, @filename)
    File.rm(path)
  end

  defp encode_message(msg) do
    Jason.encode!(%{
      role: msg.role,
      content: msg.content,
      tool_calls: msg.tool_calls,
      tool_call_id: msg.tool_call_id,
      tool_name: msg.tool_name,
      is_error: msg.is_error,
      timestamp: msg.timestamp
    })
  end

  defp decode_message(line) do
    case Jason.decode(line) do
      {:ok, data} ->
        %Message{
          role: data["role"],
          content: data["content"],
          tool_calls: data["tool_calls"],
          tool_call_id: data["tool_call_id"],
          tool_name: data["tool_name"],
          is_error: data["is_error"],
          timestamp: data["timestamp"]
        }
      _ -> nil
    end
  end
end
```

- [ ] **Step 3: Run tests**

```bash
cd v3 && mix test test/pi_core/workspace_loader_test.exs test/pi_core/session_store_test.exs
```

- [ ] **Step 4: Commit**

```bash
git commit -m "add workspace loader and session store"
```

---

### Task 7: Session GenServer

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/session.ex`
- Create: `v3/apps/pi_core/lib/pi_core.ex`
- Create: `v3/apps/pi_core/test/pi_core/session_test.exs`

- [ ] **Step 1: Write session tests**

```elixir
# test/pi_core/session_test.exs
defmodule PiCore.SessionTest do
  use ExUnit.Case

  setup do
    dir = System.tmp_dir!() |> Path.join("pi_core_session_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "AGENTS.md"), "You are a test agent.")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{workspace: dir}
  end

  test "prompt returns response via message", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws,
      model: "test",
      api_url: "http://unused",
      api_key: "unused",
      llm_fn: fn _opts -> {:ok, %PiCore.LLM.Client.Result{content: "Hello!", tool_calls: []}} end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "Hi")

    assert_receive {:pi_response, %{text: "Hello!"}}, 5000
  end

  test "handles parallel prompts", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws,
      model: "test",
      api_url: "http://unused",
      api_key: "unused",
      llm_fn: fn opts ->
        # Slow response for first prompt, fast for second
        if hd(opts.messages)[:content] =~ "slow" do
          Process.sleep(200)
          {:ok, %PiCore.LLM.Client.Result{content: "Slow done", tool_calls: []}}
        else
          {:ok, %PiCore.LLM.Client.Result{content: "Fast done", tool_calls: []}}
        end
      end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "slow task")
    Process.sleep(50)  # ensure first prompt is running
    PiCore.Session.prompt(pid, "fast question")

    # Should receive both responses
    responses = receive_all(2, 5000)
    texts = Enum.map(responses, & &1.text)
    assert "Fast done" in texts
    assert "Slow done" in texts
  end

  test "reset clears history", %{workspace: ws} do
    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: ws,
      model: "test",
      api_url: "http://unused",
      api_key: "unused",
      llm_fn: fn _opts -> {:ok, %PiCore.LLM.Client.Result{content: "ok", tool_calls: []}} end,
      caller: self()
    })

    PiCore.Session.prompt(pid, "remember this")
    assert_receive {:pi_response, _}, 5000

    PiCore.Session.reset(pid)
    state = :sys.get_state(pid)
    assert state.messages == []
  end

  defp receive_all(0, _timeout), do: []
  defp receive_all(count, timeout) do
    receive do
      {:pi_response, response} -> [response | receive_all(count - 1, timeout)]
    after
      timeout -> []
    end
  end
end
```

- [ ] **Step 2: Implement session.ex**

```elixir
# lib/pi_core/session.ex
defmodule PiCore.Session do
  use GenServer

  alias PiCore.Loop
  alias PiCore.LLM.Client
  alias PiCore.Tools.Schema

  defstruct [
    :workspace, :model, :api_url, :api_key,
    :system_prompt, :tools, :on_delta, :caller, :llm_fn,
    messages: [],
    active_task: nil,
    parallel_tasks: %{}
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def prompt(pid, text) do
    GenServer.cast(pid, {:prompt, text})
  end

  def abort(pid) do
    GenServer.cast(pid, :abort)
  end

  def reset(pid) do
    GenServer.cast(pid, :reset)
  end

  # --- Callbacks ---

  def init(opts) do
    workspace_loader = opts[:workspace_loader] || PiCore.WorkspaceLoader.Default
    system_prompt = workspace_loader.load(opts.workspace, %{})

    tools = opts[:tools] || default_tools()

    state = %__MODULE__{
      workspace: opts.workspace,
      model: opts.model,
      api_url: opts.api_url,
      api_key: opts.api_key,
      system_prompt: system_prompt,
      tools: tools,
      on_delta: opts[:on_delta],
      caller: opts[:caller] || self(),
      llm_fn: opts[:llm_fn],
    }

    {:ok, state}
  end

  def handle_cast({:prompt, text}, state) do
    user_msg = %Loop.Message{role: "user", content: text, timestamp: System.os_time(:millisecond)}

    if state.active_task do
      # Busy — spawn parallel
      task = Task.async(fn ->
        run_prompt(text, state.messages ++ [user_msg], state)
      end)
      parallel_tasks = Map.put(state.parallel_tasks, task.ref, %{user_msg: user_msg})
      {:noreply, %{state | parallel_tasks: parallel_tasks}}
    else
      # Idle — run inline
      state = %{state | messages: state.messages ++ [user_msg]}
      task = Task.async(fn -> run_prompt(text, state.messages, state) end)
      {:noreply, %{state | active_task: task}}
    end
  end

  def handle_cast(:abort, state) do
    if state.active_task do
      Task.shutdown(state.active_task, :brutal_kill)
      {:noreply, %{state | active_task: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:reset, state) do
    PiCore.SessionStore.clear(state.workspace)
    {:noreply, %{state | messages: [], active_task: nil, parallel_tasks: %{}}}
  end

  def handle_info({ref, {:ok, new_messages}}, state) do
    Process.demonitor(ref, [:flush])

    if state.active_task && state.active_task.ref == ref do
      # Main task completed
      state = %{state | messages: state.messages ++ new_messages, active_task: nil}
      last_assistant = Enum.find(Enum.reverse(new_messages), & &1.role == "assistant")
      if last_assistant do
        send(state.caller, {:pi_response, %{text: last_assistant.content, prompt_id: ref}})
      end
      {:noreply, state}
    else
      # Parallel task completed
      case Map.pop(state.parallel_tasks, ref) do
        {%{user_msg: user_msg}, remaining} ->
          # Merge Q&A back into main history
          state = %{state | messages: state.messages ++ [user_msg | new_messages], parallel_tasks: remaining}
          last_assistant = Enum.find(Enum.reverse(new_messages), & &1.role == "assistant")
          if last_assistant do
            send(state.caller, {:pi_response, %{text: last_assistant.content, prompt_id: ref}})
          end
          {:noreply, state}
        {nil, _} ->
          {:noreply, state}
      end
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    if state.active_task && state.active_task.ref == ref do
      send(state.caller, {:pi_response, %{text: "Error: #{inspect(reason)}", prompt_id: ref, error: true}})
      {:noreply, %{state | active_task: nil}}
    else
      parallel_tasks = Map.delete(state.parallel_tasks, ref)
      {:noreply, %{state | parallel_tasks: parallel_tasks}}
    end
  end

  # --- Private ---

  defp run_prompt(_text, messages, state) do
    llm_fn = state.llm_fn || &default_llm_fn(state, &1)

    Loop.run(%{
      system_prompt: state.system_prompt,
      messages: messages,
      tools: state.tools,
      tool_context: %{workspace: state.workspace},
      llm_fn: llm_fn,
      on_delta: state.on_delta,
    })
  end

  defp default_llm_fn(state, opts) do
    Client.completion(%{
      model: state.model,
      api_url: state.api_url,
      api_key: state.api_key,
      system_prompt: opts.system_prompt,
      messages: opts.messages,
      tools: opts.tools,
      max_tokens: 16384,
      stream: true,
      on_delta: opts[:on_delta]
    })
  end

  defp default_tools do
    [
      PiCore.Tools.Bash.new(),
      PiCore.Tools.Read.new(),
      PiCore.Tools.Write.new(),
      PiCore.Tools.Edit.new(),
    ]
  end
end
```

- [ ] **Step 3: Create public API module**

```elixir
# lib/pi_core.ex
defmodule PiCore do
  defdelegate start_session(opts), to: PiCore.Session, as: :start_link
end
```

- [ ] **Step 4: Run tests**

```bash
cd v3 && mix test test/pi_core/session_test.exs
```

- [ ] **Step 5: Run full test suite**

```bash
cd v3 && mix test
```

- [ ] **Step 6: Commit**

```bash
git commit -m "add Session GenServer with parallel prompt support"
```

---

### Task 8: Integration Test — Full Agent Run

**Files:**
- Modify: `v3/apps/pi_core/test/integration/nebius_test.exs`

- [ ] **Step 1: Add end-to-end agent test**

Add to `nebius_test.exs`:

```elixir
@tag :integration
test "full agent run: create file and read it back" do
  api_key = System.get_env("NEBIUS_API_KEY")
  api_url = System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"

  if is_nil(api_key) do
    IO.puts("Skipping: NEBIUS_API_KEY not set")
  else
    dir = System.tmp_dir!() |> Path.join("pi_core_e2e_#{:rand.uniform(100000)}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "AGENTS.md"), "You are a helpful assistant. Use tools when needed.")

    {:ok, pid} = PiCore.Session.start_link(%{
      workspace: dir,
      model: "Qwen/Qwen3-235B-A22B-Instruct-2507",
      api_url: api_url,
      api_key: api_key,
      caller: self()
    })

    PiCore.Session.prompt(pid, "Create a file called hello.txt with the content 'hello from elixir', then read it back and tell me what it says.")

    assert_receive {:pi_response, %{text: text}}, 60_000
    assert text =~ "hello from elixir"
    assert File.exists?(Path.join(dir, "hello.txt"))

    File.rm_rf!(dir)
  end
end
```

- [ ] **Step 2: Run integration test**

```bash
cd v3 && NEBIUS_API_KEY=your_key mix test test/integration/ --include integration
```

- [ ] **Step 3: Commit**

```bash
git commit -m "add end-to-end integration test with real Nebius API"
```

---

## Phase 0+1 Complete Checklist

- [ ] v2 code moved to `v2/` subdirectory
- [ ] Elixir umbrella app created at `v3/`
- [ ] pi_core app with Finch HTTP client
- [ ] SSE parser handles streaming, reasoning_content, [DONE]
- [ ] LLM client: streaming + non-streaming + tool calls
- [ ] Tool system: struct, schema, bash, read, write, edit
- [ ] Agent loop: prompt → LLM → tool calls → execute → loop
- [ ] Workspace loader: reads AGENTS.md, SOUL.md etc. (pluggable)
- [ ] Session store: JSONL save/load/append
- [ ] Session GenServer: state management, parallel prompts, abort, reset
- [ ] Integration tests pass against real Nebius API
- [ ] `mix test` passes all unit tests
