# Druzhok Test Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pin down the current behaviour of druzhok's LLM proxy, manager bot and bot lifecycle with tests, so the later migration to ruoc-gateway can be done connector by connector with a green suite proving Hermes sees no difference.

**Architecture:** Characterization tests, not redesign. Every upstream HTTP dependency (OpenRouter, OpenAI TTS, Telegram Bot API) is replaced in tests by a local Bypass server so the real request bodies and response handling are exercised end to end. Two small seams are added to production code (configurable OpenAI and Telegram base URLs, a `name` option on the ManagerBot GenServer); nothing else in `lib/` changes behaviour.

**Tech Stack:** Elixir 1.18 umbrella, ExUnit, `bypass` 2.1 (test-only HTTP stub), Phoenix.ConnTest, SQLite via Ecto sandbox, `test/support/fake_hermes.sh` as the bot process.

**Spec:** none. Requirements come from the review discussion on 2026-09-05 and are restated in *Requirements* below.

## Requirements

1. `DruzhokWebWeb.LlmProxyController` reaches at least 80% line coverage. Every connector has tests: chat sync, chat stream, transcription, TTS, search, embeddings, image generation, Responses API.
2. `Druzhok.ManagerBot` reaches at least 80% line coverage, driven as a real GenServer against a stub Telegram API, covering `/start`, the create flow, "Мои боты", delete with ownership check, the `managed_bot` provisioning trigger and the 2-bot limit.
3. `Druzhok.BotManager` create / start / stop / restart / delete are covered against `Host.Process` and `fake_hermes.sh`, including the "never wipe outside the data root" rule.
4. `mix test --cover` enforces a threshold in both apps so coverage cannot silently regress.
5. Tests assert on what is sent upstream and what comes back to the client. That is the contract the ruoc-gateway migration must keep.

## Global Constraints

- Commit with short imperative messages, no attribution trailers (repo rule, `/my-commit`).
- Never write to `/data/tenants` or any real bot directory. Every test that touches disk uses a `System.tmp_dir!()` subdirectory and sets `DRUZHOK_DATA_ROOT` to it.
- Tests that mutate `Application` env or `System` env are `async: false` and restore the previous value in `on_exit`.
- Run the suite from the umbrella root: `mix test` (both apps) or `mix test apps/<app>/test/<path>` for one file. Running `mix test apps/druzhok` alone prints nothing; always give a file path or run everything.
- `Druzhok.Repo` in the core app runs in sandbox `:auto` mode (no checkout); tests there clean up rows in `on_exit`. In `druzhok_web`, `ConnCase` owns a sandbox and rolls back.
- Existing tests must stay green after every task: `mix test` → `0 failures` in both apps.

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `apps/druzhok_web/test/support/proxy_case.ex` | ExUnit case template for proxy tests: starts Bypass, points OpenRouter and OpenAI URLs at it, sets a fake OpenRouter key, inserts an instance, builds an authenticated conn, restores env. Exposes `create_instance/1`, `json_response!/2`, `usage_logs/1`, `spent_today/1`. |
| `apps/druzhok_web/test/support/upstream_stub.ex` | Builders for fake upstream responses: `chat_completion/2`, `sse_stream/2`, `openrouter_usage/3`. Pure functions returning maps or iodata. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs` | Non-streaming chat completions. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_stream_test.exs` | Streaming chat completions and the mimo fake-stream path. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/transcription_test.exs` | `/v1/audio/transcriptions`. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/tts_test.exs` | `/v1/audio/speech`. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/search_test.exs` | `/v2/search`. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/embeddings_test.exs` | `/v1/embeddings`. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/image_gen_test.exs` | `/v1/images/generations`. |
| `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/responses_test.exs` | `/v1/responses`. |
| `apps/druzhok/test/support/telegram_stub.ex` | Bypass-backed fake Telegram Bot API with an update queue and a call log. |
| `apps/druzhok/test/support/bot_fixtures.ex` | `with_tmp_data_root/0` setup helper and `delete_instances/1` cleanup shared by ManagerBot and BotManager tests. |
| `apps/druzhok/test/druzhok/telegram/api_test.exs` | `Druzhok.Telegram.API` request encoding and response decoding. |
| `apps/druzhok/test/druzhok/manager_bot_test.exs` | ManagerBot GenServer end to end. |
| `apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs` | BotManager create/start/stop/restart/delete. |

**Modified**

| File | Change |
|---|---|
| `apps/druzhok_web/mix.exs` | add `{:bypass, "~> 2.1", only: :test}`; add `test_coverage` threshold. |
| `apps/druzhok/mix.exs` | add `{:bypass, "~> 2.1", only: :test}`; add `elixirc_paths` so `test/support/*.ex` compiles; add `test_coverage` threshold. |
| `apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:419` | TTS URL from `Application.get_env(:druzhok, :openai_api_url)`. |
| `apps/druzhok/lib/druzhok/telegram/api.ex` | base URL from `Application.get_env(:druzhok, :telegram_api_base)`. |
| `apps/druzhok/lib/druzhok/manager_bot.ex:21` | `start_link/1` honours `opts[:name]`. |
| `config/runtime.exs` | `openai_api_url` env passthrough. |
| `CLAUDE.md` | one line on `mix test --cover`. |

---

### Task 1: Proxy test harness

**Files:**
- Modify: `apps/druzhok_web/mix.exs:58` (deps)
- Create: `apps/druzhok_web/test/support/upstream_stub.ex`
- Create: `apps/druzhok_web/test/support/proxy_case.ex`
- Test: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs`

**Interfaces:**
- Produces: `DruzhokWebWeb.ProxyCase` (case template; `use DruzhokWebWeb.ProxyCase` gives `%{conn, bypass, instance, base_url}` in context). Functions: `create_instance(attrs :: map) :: %Druzhok.Instance{}`, `authed(conn, instance) :: Plug.Conn.t()`, `usage_logs(instance) :: [%Druzhok.Usage{}]`, `spent_today(instance) :: integer`.
- Produces: `DruzhokWebWeb.UpstreamStub.chat_completion(content :: String.t(), opts :: keyword) :: map` with keys `usage` (default `prompt_tokens: 10, completion_tokens: 5, cost: 0.02`), `model`, `tool_calls`; `sse_stream(deltas :: [String.t()], opts) :: [String.t()]` list of `"data: ...\n\n"` lines ending with `[DONE]`; `send_sse(conn, lines) :: Plug.Conn.t()`.

- [ ] **Step 1: Add bypass to druzhok_web deps**

In `apps/druzhok_web/mix.exs`, inside `deps/0`, after the `{:floki, ...}` line add:

```elixir
      {:bypass, "~> 2.1", only: :test},
```

Run: `mix deps.get`
Expected: `bypass 2.1.x` and `plug_cowboy`/`ranch` fetched, no errors.

- [ ] **Step 2: Write the upstream response builders**

Create `apps/druzhok_web/test/support/upstream_stub.ex`:

```elixir
defmodule DruzhokWebWeb.UpstreamStub do
  @moduledoc """
  Builders for the JSON and SSE bodies a fake OpenRouter returns in proxy
  tests. Shapes copied from real OpenRouter responses so the controller's
  parsing is exercised against what production actually sees.
  """

  @doc "A non-streaming chat completion body (a map, not encoded)."
  def chat_completion(content, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => 0.02})
    model = Keyword.get(opts, :model, "z-ai/glm-5.3-flash")
    tool_calls = Keyword.get(opts, :tool_calls)

    message =
      if tool_calls,
        do: %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls},
        else: %{"role" => "assistant", "content" => content}

    %{
      "id" => "gen-test-1",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
      "usage" => usage
    }
  end

  @doc """
  SSE lines for a streamed completion: one chunk per delta, then a usage
  chunk (unless `usage: nil`), then `[DONE]`. Each element is a full
  `"data: ...\\n\\n"` string.
  """
  def sse_stream(deltas, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{"prompt_tokens" => 10, "completion_tokens" => 5, "cost" => 0.02})
    model = Keyword.get(opts, :model, "z-ai/glm-5.3-flash")

    content_chunks =
      Enum.map(deltas, fn text ->
        chunk(%{
          "id" => "gen-test-1",
          "object" => "chat.completion.chunk",
          "model" => model,
          "choices" => [%{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => nil}]
        })
      end)

    final =
      chunk(%{
        "id" => "gen-test-1",
        "object" => "chat.completion.chunk",
        "model" => model,
        "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
      })

    usage_chunk =
      if usage,
        do: [chunk(%{"id" => "gen-test-1", "object" => "chat.completion.chunk", "model" => model, "choices" => [], "usage" => usage})],
        else: []

    content_chunks ++ [final] ++ usage_chunk ++ ["data: [DONE]\n\n"]
  end

  @doc "Send a list of SSE lines as a chunked text/event-stream response from a Bypass handler."
  def send_sse(conn, lines) do
    conn =
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_chunked(200)

    Enum.reduce(lines, conn, fn line, conn ->
      {:ok, conn} = Plug.Conn.chunk(conn, line)
      conn
    end)
  end

  defp chunk(map), do: "data: " <> Jason.encode!(map) <> "\n\n"
end
```

- [ ] **Step 3: Write the ProxyCase template**

Create `apps/druzhok_web/test/support/proxy_case.ex`:

```elixir
defmodule DruzhokWebWeb.ProxyCase do
  @moduledoc """
  Case template for LLM proxy tests.

  Starts a Bypass server and points both OpenRouter (`:openrouter_api_url`)
  and OpenAI (`:openai_api_url`) at it, sets a fake OpenRouter key in app
  env, inserts one instance with a tenant key and returns a conn already
  carrying `Authorization: Bearer <tenant_key>`.

  Tests are `async: false` because they mutate application env.
  """
  use ExUnit.CaseTemplate

  alias Druzhok.{Instance, Repo, Usage, Budget}

  using do
    quote do
      use DruzhokWebWeb.ConnCase, async: false
      import DruzhokWebWeb.ProxyCase
      import DruzhokWebWeb.UpstreamStub
    end
  end

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}/v1"

    prev = %{
      openrouter_api_url: Application.get_env(:druzhok, :openrouter_api_url),
      openrouter_api_key: Application.get_env(:druzhok, :openrouter_api_key),
      openai_api_url: Application.get_env(:druzhok, :openai_api_url)
    }

    Application.put_env(:druzhok, :openrouter_api_url, base_url)
    Application.put_env(:druzhok, :openrouter_api_key, "test-or-key")
    Application.put_env(:druzhok, :openai_api_url, base_url)

    on_exit(fn ->
      for {k, v} <- prev do
        if v, do: Application.put_env(:druzhok, k, v), else: Application.delete_env(:druzhok, k)
      end
    end)

    instance = create_instance(%{})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    %{bypass: bypass, base_url: base_url, instance: instance, conn: conn}
  end

  @doc "Insert an instance with sensible defaults; override any field via attrs."
  def create_instance(attrs) do
    name = attrs[:name] || "px-#{System.unique_integer([:positive])}"

    defaults = %{
      name: name,
      model: "z-ai/glm-5.3-flash",
      workspace: Path.join([System.tmp_dir!(), "druzhok-proxy-test", name, "workspace"]),
      tenant_key: Instance.generate_tenant_key(name),
      timezone: "UTC",
      daily_budget_cents: 0
    }

    %Instance{}
    |> Instance.changeset(Map.merge(defaults, Map.new(attrs)))
    |> Repo.insert!()
  end

  @doc "Conn with the instance's tenant key as bearer token."
  def authed(conn, %Instance{tenant_key: key}) do
    Plug.Conn.put_req_header(conn, "authorization", "Bearer #{key}")
  end

  def usage_logs(%Instance{id: id}) do
    import Ecto.Query
    Repo.all(from(u in Usage, where: u.instance_id == ^id, order_by: u.id))
  end

  def spent_today(%Instance{id: id}), do: Budget.spent_today_cents(id)
end
```

- [ ] **Step 4: Write the first characterization test (sync chat happy path)**

Create `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs`:

```elixir
defmodule DruzhokWebWeb.LlmProxy.ChatSyncTest do
  use DruzhokWebWeb.ProxyCase

  @body %{
    "model" => "z-ai/glm-5.3-flash",
    "messages" => [%{"role" => "user", "content" => "ping"}]
  }

  test "forwards to OpenRouter with the server key and returns the body verbatim",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      assert sent["model"] == "z-ai/glm-5.3-flash"
      assert sent["messages"] == @body["messages"]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("pong")))
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert conn.status == 200
    assert get_in(json_response(conn, 200), ["choices", Access.at(0), "message", "content"]) == "pong"
  end
end
```

- [ ] **Step 5: Run it, expect failure on the missing support modules**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs`
Expected: compile error `module DruzhokWebWeb.ProxyCase is not available` **only if** `test/support` is not on the compile path. `apps/druzhok_web/mix.exs` already has `elixirc_paths(:test), do: ["lib", "test/support"]`, so the expected result is actually PASS: 1 test, 0 failures. If it fails on `:openai_api_url`, that is fine here; the seam is added in Task 5.

- [ ] **Step 6: Run the full suite to confirm nothing else broke**

Run: `mix test`
Expected: both apps `0 failures`.

- [ ] **Step 7: Commit**

```bash
git add apps/druzhok_web/mix.exs mix.lock apps/druzhok_web/test/support/proxy_case.ex apps/druzhok_web/test/support/upstream_stub.ex apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs
git commit -m "add Bypass-backed proxy test harness"
```

---

### Task 2: Chat completions, non-streaming

**Files:**
- Modify: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs`

**Interfaces:**
- Consumes: `ProxyCase`, `UpstreamStub.chat_completion/2`.

- [ ] **Step 1: Add the remaining sync tests**

Append inside the module in `chat_sync_test.exs` (keep the first test):

```elixir
  test "injects max_tokens=4096 and usage.include when the client sent neither",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["max_tokens"] == 4096
      assert sent["usage"] == %{"include" => true}
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/chat/completions", @body).status == 200
  end

  test "keeps the client's own max_tokens", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["max_tokens"] == 77
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/chat/completions", Map.put(@body, "max_tokens", 77)).status == 200
  end

  test "logs usage with OpenRouter's reported cost and deducts the budget",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      body = chat_completion("pong", usage: %{"prompt_tokens" => 120, "completion_tokens" => 30, "cost" => 0.0451})
      Plug.Conn.resp(req, 200, Jason.encode!(body))
    end)

    post(conn, "/v1/chat/completions", @body)

    assert [log] = usage_logs(instance)
    assert log.prompt_tokens == 120
    assert log.completion_tokens == 30
    assert log.total_tokens == 150
    assert log.cost_cents == 5
    assert log.request_type == "chat"
    assert log.provider == "openrouter"
    assert log.model == "z-ai/glm-5.3-flash"
    assert log.prompt_preview == "ping"
    assert log.response_preview == "pong"
    assert Jason.decode!(log.request_body)["messages"] == @body["messages"]
    assert spent_today(instance) == 5
  end

  test "falls back to the catalog price when usage.cost is absent",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      # glm-5.3-flash: 8 cents/M in, 25 cents/M out → 1M in = 8 cents
      body = chat_completion("x", usage: %{"prompt_tokens" => 1_000_000, "completion_tokens" => 0})
      Plug.Conn.resp(req, 200, Jason.encode!(body))
    end)

    post(conn, "/v1/chat/completions", @body)
    assert [%{cost_cents: 8}] = usage_logs(instance)
  end

  test "does not log when the upstream reports zero tokens",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x", usage: %{"prompt_tokens" => 0, "completion_tokens" => 0})))
    end)

    post(conn, "/v1/chat/completions", @body)
    assert usage_logs(instance) == []
  end

  test "relays an upstream error status and body unchanged", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 429, Jason.encode!(%{"error" => %{"message" => "slow down"}}))
    end)

    conn = post(conn, "/v1/chat/completions", @body)
    assert conn.status == 429
    assert json_response(conn, 429)["error"]["message"] == "slow down"
  end

  test "answers 502 when the upstream is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)

    conn = post(conn, "/v1/chat/completions", @body)
    assert json_response(conn, 502) == %{"error" => %{"message" => "Provider unavailable", "type" => "server_error"}}
  end

  test "refuses with 429 budget_exceeded before touching the upstream when today's spend hit the limit",
       %{bypass: bypass} do
    instance = create_instance(%{daily_budget_cents: 50})
    Druzhok.Budget.deduct(instance.id, 50)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    # No Bypass expectation: any upstream call would fail the test with "unexpected request".

    conn = post(conn, "/v1/chat/completions", @body)
    resp = json_response(conn, 429)
    assert resp["error"]["type"] == "budget_exceeded"
    assert resp["error"]["message"] =~ "0.50"
  end

  test "rejects an unknown tenant key with 401" do
    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer dk-nobody-xxxx")
      |> post("/v1/chat/completions", @body)

    assert json_response(conn, 401)["error"]["type"] == "authentication_error"
  end

  test "rejects a missing Authorization header with 401" do
    conn = post(Phoenix.ConnTest.build_conn(), "/v1/chat/completions", @body)
    assert json_response(conn, 401)["error"]["message"] == "Missing Authorization header"
  end

  test "strips image parts for a model on the non-vision list", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      [msg] = Jason.decode!(raw)["messages"]
      assert msg["content"] == "look"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    body = %{
      "model" => "deepseek/deepseek-v3.2",
      "messages" => [%{"role" => "user", "content" => [
        %{"type" => "text", "text" => "look"},
        %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA"}}
      ]}]
    }

    assert post(conn, "/v1/chat/completions", body).status == 200
  end
```

- [ ] **Step 2: Run the file**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs`
Expected: 12 tests, 0 failures. If `budget_exceeded_message` assertion on `"0.50"` fails, read the actual message in the failure output and assert on the exact substring it prints for a 50-cent limit; the point is that the limit appears in the message.

- [ ] **Step 3: Commit**

```bash
git add apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_sync_test.exs
git commit -m "characterize non-streaming chat proxy"
```

---

### Task 3: Chat completions, streaming

**Files:**
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_stream_test.exs`

**Interfaces:**
- Consumes: `UpstreamStub.sse_stream/2`, `UpstreamStub.send_sse/2`, `UpstreamStub.chat_completion/2`.

- [ ] **Step 1: Write the streaming tests**

```elixir
defmodule DruzhokWebWeb.LlmProxy.ChatStreamTest do
  use DruzhokWebWeb.ProxyCase

  @body %{
    "model" => "z-ai/glm-5.3-flash",
    "stream" => true,
    "messages" => [%{"role" => "user", "content" => "ping"}]
  }

  defp sse_payloads(resp_body) do
    resp_body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "data: "))
    |> Enum.map(&String.trim_leading(&1, "data: "))
  end

  test "relays SSE chunks verbatim as text/event-stream", %{conn: conn, bypass: bypass} do
    lines = sse_stream(["po", "ng"])

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["stream"] == true
      send_sse(req, lines)
    end)

    conn = post(conn, "/v1/chat/completions", @body)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/event-stream"
    assert conn.resp_body == Enum.join(lines)
  end

  test "captures the trailing usage chunk and meters it",
       %{conn: conn, bypass: bypass, instance: instance} do
    usage = %{"prompt_tokens" => 40, "completion_tokens" => 8, "cost" => 0.031}

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      send_sse(req, sse_stream(["a", "b"], usage: usage))
    end)

    post(conn, "/v1/chat/completions", @body)

    assert [log] = usage_logs(instance)
    assert log.prompt_tokens == 40
    assert log.completion_tokens == 8
    assert log.cost_cents == 3
    assert log.response_preview == nil
    assert spent_today(instance) == 3
  end

  test "logs nothing when the stream carries no usage chunk",
       %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      send_sse(req, sse_stream(["a"], usage: nil))
    end)

    post(conn, "/v1/chat/completions", @body)
    assert usage_logs(instance) == []
  end

  test "still returns 200 with whatever arrived when the upstream dies mid-stream",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      req = req |> Plug.Conn.put_resp_content_type("text/event-stream") |> Plug.Conn.send_chunked(200)
      {:ok, req} = Plug.Conn.chunk(req, hd(sse_stream(["partial"], usage: nil)))
      # Kill the connection without finishing the stream.
      Bypass.pass(bypass)
      Plug.Conn.halt(req)
    end)

    conn = post(conn, "/v1/chat/completions", @body)
    assert conn.status == 200
    assert conn.resp_body =~ "partial"
  end

  describe "mimo-v2-pro fake stream" do
    @mimo Map.put(@body, "model", "xiaomi/mimo-v2-pro")

    test "asks the upstream for a non-streaming reply and synthesizes SSE",
         %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        sent = Jason.decode!(raw)
        assert sent["stream"] == false
        refute Map.has_key?(sent, "stream_options")
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hello", model: "xiaomi/mimo-v2-pro")))
      end)

      conn = post(conn, "/v1/chat/completions", @mimo)

      payloads = sse_payloads(conn.resp_body)
      assert List.last(payloads) == "[DONE]"
      [first, second | _] = Enum.map(Enum.drop(payloads, -1), &Jason.decode!/1)
      assert get_in(first, ["choices", Access.at(0), "delta", "content"]) == "hello"
      assert get_in(second, ["choices", Access.at(0), "finish_reason"]) == "stop"
    end

    test "emits a usage chunk only when stream_options.include_usage was requested",
         %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hi", usage: %{"prompt_tokens" => 3, "completion_tokens" => 2, "cost" => 0.0})))
      end)

      body = Map.put(@mimo, "stream_options", %{"include_usage" => true})
      conn = post(conn, "/v1/chat/completions", body)

      usage_chunk =
        conn.resp_body
        |> sse_payloads()
        |> Enum.reject(&(&1 == "[DONE]"))
        |> Enum.map(&Jason.decode!/1)
        |> Enum.find(&Map.has_key?(&1, "usage"))

      assert usage_chunk["usage"] == %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    end

    test "synthesizes a tool_calls delta when the reply is a tool call", %{conn: conn, bypass: bypass} do
      calls = [%{"id" => "c1", "type" => "function", "function" => %{"name" => "f", "arguments" => "{}"}}]

      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(nil, tool_calls: calls)))
      end)

      conn = post(conn, "/v1/chat/completions", @mimo)
      [first | _] = conn.resp_body |> sse_payloads() |> Enum.reject(&(&1 == "[DONE]")) |> Enum.map(&Jason.decode!/1)
      assert get_in(first, ["choices", Access.at(0), "delta", "tool_calls"]) == calls
    end

    test "relays an upstream error inside the SSE stream", %{conn: conn, bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        Plug.Conn.resp(req, 500, ~s({"error":"boom"}))
      end)

      conn = post(conn, "/v1/chat/completions", @mimo)
      assert conn.status == 200
      assert sse_payloads(conn.resp_body) == [~s({"error":"boom"}), "[DONE]"]
    end
  end
end
```

- [ ] **Step 2: Run the file**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_stream_test.exs`
Expected: 8 tests, 0 failures. The "dies mid-stream" test documents current behaviour; if it errors rather than returning 200, replace its assertions with what the controller actually does (the `{:error, _} -> conn` branch in `stream_proxy`) and keep the test, since the migration must preserve it.

- [ ] **Step 3: Commit**

```bash
git add apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/chat_stream_test.exs
git commit -m "characterize streaming chat proxy"
```

---

### Task 4: Audio transcription

**Files:**
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/transcription_test.exs`

- [ ] **Step 1: Write the tests**

```elixir
defmodule DruzhokWebWeb.LlmProxy.TranscriptionTest do
  use DruzhokWebWeb.ProxyCase

  setup do
    path = Path.join(System.tmp_dir!(), "voice-#{System.unique_integer([:positive])}.oga")
    File.write!(path, "OggS-fake-bytes")
    on_exit(fn -> File.rm(path) end)
    %{upload: %Plug.Upload{path: path, filename: "voice.oga", content_type: "audio/ogg"}}
  end

  test "wraps the file as an input_audio part with format ogg and the pinned prompt",
       %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "google/gemini-2.5-flash"
      [%{"role" => "user", "content" => [text, audio]}] = sent["messages"]
      assert text["type"] == "text"
      assert text["text"] =~ "Transcribe the audio VERBATIM"
      assert audio == %{"type" => "input_audio", "input_audio" => %{"data" => Base.encode64("OggS-fake-bytes"), "format" => "ogg"}}
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("  привет мир \n")))
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload, "model" => "whisper-1"})

    assert json_response(conn, 200) == %{"text" => "привет мир"}
  end

  test "returns plain text when response_format=text", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hello")))
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload, "response_format" => "text"})
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
    assert conn.resp_body == "hello"
  end

  test "uses the transcription_model setting when set", %{conn: conn, bypass: bypass, upload: upload} do
    Druzhok.Settings.set("transcription_model", "google/gemini-3-flash-preview")

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["model"] == "google/gemini-3-flash-preview"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x")))
    end)

    assert post(conn, "/v1/audio/transcriptions", %{"file" => upload}).status == 200
  end

  test "maps filename extensions to OpenRouter formats", %{conn: conn, bypass: bypass, upload: upload} do
    for {filename, format} <- [{"a.mp3", "mp3"}, {"a.wav", "wav"}, {"a.opus", "ogg"}, {"a.m4a", "m4a"}, {"noext", "mp3"}] do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
        {:ok, raw, req} = Plug.Conn.read_body(req)
        [%{"content" => [_, audio]}] = Jason.decode!(raw)["messages"]
        assert audio["input_audio"]["format"] == format, "#{filename} → #{format}"
        Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x")))
      end)

      assert post(conn, "/v1/audio/transcriptions", %{"file" => %{upload | filename: filename}}).status == 200
    end
  end

  test "meters the call as request_type audio", %{conn: conn, bypass: bypass, upload: upload, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x", usage: %{"prompt_tokens" => 200, "completion_tokens" => 10, "cost" => 0.012})))
    end)

    post(conn, "/v1/audio/transcriptions", %{"file" => upload})

    assert [log] = usage_logs(instance)
    assert log.request_type == "audio"
    assert log.model == "google/gemini-2.5-flash"
    assert log.cost_cents == 1
    assert spent_today(instance) == 1
  end

  test "400 when no file is attached", %{conn: conn} do
    conn = post(conn, "/v1/audio/transcriptions", %{"model" => "whisper-1"})
    assert json_response(conn, 400)["error"]["type"] == "invalid_request"
  end

  test "503 when no OpenRouter key is configured", %{conn: conn, upload: upload} do
    Application.delete_env(:druzhok, :openrouter_api_key)
    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 503)["error"]["message"] == "Audio transcription not configured"
  end

  test "relays upstream errors", %{conn: conn, bypass: bypass, upload: upload} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 400, ~s({"error":{"message":"bad audio"}}))
    end)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 400)["error"]["message"] == "bad audio"
  end

  test "429 when the daily budget is spent", %{bypass: _bypass, upload: upload} do
    instance = create_instance(%{daily_budget_cents: 10})
    Druzhok.Budget.deduct(instance.id, 10)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    conn = post(conn, "/v1/audio/transcriptions", %{"file" => upload})
    assert json_response(conn, 429)["error"]["type"] == "budget_exceeded"
  end
end
```

- [ ] **Step 2: Run the file**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/transcription_test.exs`
Expected: 9 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/transcription_test.exs
git commit -m "characterize transcription proxy"
```

---

### Task 5: Text to speech, with the OpenAI URL seam

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:419`
- Modify: `config/runtime.exs` (the `config :druzhok,` block near line 97)
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/tts_test.exs`

**Interfaces:**
- Produces: app env key `:openai_api_url` under `:druzhok`, default `"https://api.openai.com/v1"`; the controller requests `<openai_api_url>/audio/speech`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule DruzhokWebWeb.LlmProxy.TtsTest do
  use DruzhokWebWeb.ProxyCase

  @body %{"model" => "gpt-4o-mini-tts", "voice" => "alloy", "input" => "Привет, как дела?"}

  setup do
    Druzhok.Settings.set("openai_api_key", "sk-test-openai")
    :ok
  end

  test "forwards the body to OpenAI with the OpenAI key and returns the audio bytes",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw) == @body
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer sk-test-openai"]

      req
      |> Plug.Conn.put_resp_content_type("audio/mpeg")
      |> Plug.Conn.resp(200, <<0xFF, 0xFB, 0x90, 0x00>>)
    end)

    conn = post(conn, "/v1/audio/speech", @body)

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "audio/mpeg"
    assert conn.resp_body == <<0xFF, 0xFB, 0x90, 0x00>>
  end

  test "meters characters as prompt_tokens at 0.00006 cents each",
       %{conn: conn, bypass: bypass, instance: instance} do
    long = String.duplicate("а", 50_000)

    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      Plug.Conn.resp(req, 200, "mp3")
    end)

    post(conn, "/v1/audio/speech", Map.put(@body, "input", long))

    assert [log] = usage_logs(instance)
    assert log.request_type == "tts"
    assert log.provider == "openai"
    assert log.prompt_tokens == 50_000
    assert log.cost_cents == 3
    assert log.prompt_preview == String.slice(long, 0, 500)
  end

  test "503 when no OpenAI key is configured", %{conn: conn} do
    Druzhok.Settings.set("openai_api_key", "")
    conn = post(conn, "/v1/audio/speech", @body)
    assert json_response(conn, 503)["error"]["message"] == "Text-to-speech not configured"
  end

  test "relays upstream errors", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/audio/speech", fn req ->
      Plug.Conn.resp(req, 401, ~s({"error":{"message":"bad key"}}))
    end)

    conn = post(conn, "/v1/audio/speech", @body)
    assert json_response(conn, 401)["error"]["message"] == "bad key"
  end

  test "502 when OpenAI is unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/audio/speech", @body)
    assert json_response(conn, 502)["error"]["message"] == "TTS provider unavailable"
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/tts_test.exs`
Expected: FAIL. The controller still calls `https://api.openai.com`, so the first test either times out or gets a real 401 and the Bypass expectation reports "No HTTP request arrived at Bypass".

- [ ] **Step 3: Add the seam**

In `llm_proxy_controller.ex`, inside `do_audio_speech/3`, replace

```elixir
    url = "https://api.openai.com/v1/audio/speech"
```

with

```elixir
    url = openai_api_url() <> "/audio/speech"
```

and add next to `json_error/4` at the bottom of the module:

```elixir
  defp openai_api_url do
    Application.get_env(:druzhok, :openai_api_url) || "https://api.openai.com/v1"
  end
```

In `config/runtime.exs`, in the `config :druzhok,` block that sets `openrouter_api_key`, add a line:

```elixir
  openai_api_url: System.get_env("OPENAI_API_URL") || "https://api.openai.com/v1",
```

- [ ] **Step 4: Run again**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/tts_test.exs`
Expected: 5 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex config/runtime.exs apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/tts_test.exs
git commit -m "characterize TTS proxy; make OpenAI base URL configurable"
```

---

### Task 6: Web search

**Files:**
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/search_test.exs`

- [ ] **Step 1: Write the tests**

```elixir
defmodule DruzhokWebWeb.LlmProxy.SearchTest do
  use DruzhokWebWeb.ProxyCase

  @results [
    %{"title" => "Нанорубль", "url" => "https://ru.wikipedia.org/x", "description" => "Одна миллиардная рубля."},
    %{"title" => "Second", "url" => "https://b.example", "snippet" => "uses snippet key"}
  ]

  defp expect_search(bypass, content, opts \\ []) do
    usage = Keyword.get(opts, :usage, %{"prompt_tokens" => 50, "completion_tokens" => 80, "cost" => 0.008})

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      send(self(), {:sent, Jason.decode!(raw)})
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(content, usage: usage, model: "perplexity/sonar")))
    end)
  end

  test "asks perplexity/sonar for a JSON array and returns the Firecrawl shape",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "perplexity/sonar"
      assert sent["usage"] == %{"include" => true}
      [system, user] = sent["messages"]
      assert system["role"] == "system"
      assert system["content"] =~ "web search API"
      assert user["content"] =~ "что такое нанорубль"
      assert user["content"] =~ "up to 2 results"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion(Jason.encode!(@results), model: "perplexity/sonar")))
    end)

    conn = post(conn, "/v2/search", %{"query" => "что такое нанорубль", "limit" => 2})

    assert %{"success" => true, "data" => %{"web" => web}} = json_response(conn, 200)
    assert web == [
      %{"title" => "Нанорубль", "url" => "https://ru.wikipedia.org/x", "description" => "Одна миллиардная рубля.", "position" => 1},
      %{"title" => "Second", "url" => "https://b.example", "description" => "uses snippet key", "position" => 2}
    ]
  end

  test "accepts results wrapped in {results: [...]} or {web: [...]}", %{conn: conn, bypass: bypass} do
    for key <- ["results", "web"] do
      expect_search(bypass, Jason.encode!(%{key => @results}))
      conn = post(conn, "/v2/search", %{"query" => "q"})
      assert length(json_response(conn, 200)["data"]["web"]) == 2
    end
  end

  test "digs a JSON array out of surrounding prose", %{conn: conn, bypass: bypass} do
    expect_search(bypass, "Here you go:\n" <> Jason.encode!(@results) <> "\nHope this helps.")
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert length(json_response(conn, 200)["data"]["web"]) == 2
  end

  test "returns an empty list when the model answers with no array", %{conn: conn, bypass: bypass} do
    expect_search(bypass, "I could not find anything.")
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert json_response(conn, 200)["data"]["web"] == []
  end

  test "truncates to limit and clamps limit to 1..20 (default 5)", %{conn: conn, bypass: bypass} do
    many = Enum.map(1..30, &%{"title" => "t#{&1}", "url" => "u#{&1}", "description" => "d"})

    for {given, expected} <- [{1, 1}, {"3", 3}, {25, 5}, {0, 5}, {"x", 5}, {nil, 5}] do
      expect_search(bypass, Jason.encode!(many))
      body = if given, do: %{"query" => "q", "limit" => given}, else: %{"query" => "q"}
      conn = post(conn, "/v2/search", body)
      assert length(json_response(conn, 200)["data"]["web"]) == expected, "limit #{inspect(given)}"
    end
  end

  test "400 on an empty query", %{conn: conn} do
    conn = post(conn, "/v2/search", %{"query" => ""})
    assert json_response(conn, 400) == %{"success" => false, "error" => "query is required"}
  end

  test "meters as request_type search with the query as preview",
       %{conn: conn, bypass: bypass, instance: instance} do
    expect_search(bypass, Jason.encode!(@results), usage: %{"prompt_tokens" => 50, "completion_tokens" => 80, "cost" => 0.011})
    post(conn, "/v2/search", %{"query" => "нанорубль"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "search"
    assert log.model == "perplexity/sonar"
    assert log.cost_cents == 1
    assert log.prompt_preview == "нанорубль"
    assert spent_today(instance) == 1
  end

  test "relays upstream failures in the Firecrawl error shape", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 503, "nope") end)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert json_response(conn, 503) == %{"success" => false, "error" => "upstream error"}
  end

  test "429 in the Firecrawl shape when the budget is spent" do
    instance = create_instance(%{daily_budget_cents: 5})
    Druzhok.Budget.deduct(instance.id, 5)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)
    conn = post(conn, "/v2/search", %{"query" => "q"})
    assert json_response(conn, 429) == %{"success" => false, "error" => "Token budget exceeded"}
  end
end
```

- [ ] **Step 2: Run the file**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/search_test.exs`
Expected: 9 tests, 0 failures.

- [ ] **Step 3: Commit**

```bash
git add apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/search_test.exs
git commit -m "characterize search proxy"
```

---

### Task 7: Embeddings and image generation

**Files:**
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/embeddings_test.exs`
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/image_gen_test.exs`

- [ ] **Step 1: Write the embeddings tests**

```elixir
defmodule DruzhokWebWeb.LlmProxy.EmbeddingsTest do
  use DruzhokWebWeb.ProxyCase

  @body %{"model" => "openai/text-embedding-3-small", "input" => ["a", "b"]}
  @upstream %{
    "object" => "list",
    "data" => [%{"embedding" => [0.1, 0.2], "index" => 0}, %{"embedding" => [0.3, 0.4], "index" => 1}],
    "usage" => %{"prompt_tokens" => 6, "total_tokens" => 6}
  }

  test "forwards to /embeddings and returns the body verbatim", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw) == @body
      assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer test-or-key"]
      Plug.Conn.resp(req, 200, Jason.encode!(@upstream))
    end)

    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 200) == @upstream
  end

  test "logs usage as request_type embedding with zero cost", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> Plug.Conn.resp(req, 200, Jason.encode!(@upstream)) end)
    post(conn, "/v1/embeddings", @body)

    assert [log] = usage_logs(instance)
    assert log.request_type == "embedding"
    assert log.prompt_tokens == 6
    assert log.total_tokens == 6
    assert log.cost_cents == 0
    assert spent_today(instance) == 0
  end

  test "relays non-200 without logging", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/embeddings", fn req -> Plug.Conn.resp(req, 400, ~s({"error":"bad"})) end)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 400) == %{"error" => "bad"}
    assert usage_logs(instance) == []
  end

  test "502 when unreachable", %{conn: conn, bypass: bypass} do
    Bypass.down(bypass)
    conn = post(conn, "/v1/embeddings", @body)
    assert json_response(conn, 502)["error"]["message"] == "Embeddings provider unavailable"
  end
end
```

- [ ] **Step 2: Write the image generation tests**

```elixir
defmodule DruzhokWebWeb.LlmProxy.ImageGenTest do
  use DruzhokWebWeb.ProxyCase

  @png_b64 Base.encode64("\x89PNG-fake")

  defp image_reply(model, usage \\ %{"prompt_tokens" => 20, "completion_tokens" => 0, "cost" => 0.014}) do
    %{
      "id" => "gen-img",
      "model" => model,
      "choices" => [%{"index" => 0, "message" => %{
        "role" => "assistant",
        "content" => "",
        "images" => [%{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64," <> @png_b64}}]
      }, "finish_reason" => "stop"}],
      "usage" => usage
    }
  end

  test "ignores the client's model, uses the catalog default, asks for image modality only",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "black-forest-labs/flux.2-klein-4b"
      assert sent["modalities"] == ["image"]
      assert sent["messages"] == [%{"role" => "user", "content" => "a red fox"}]
      assert sent["usage"] == %{"include" => true}
      Plug.Conn.resp(req, 200, Jason.encode!(image_reply("black-forest-labs/flux.2-klein-4b")))
    end)

    conn = post(conn, "/v1/images/generations", %{"model" => "dall-e-3", "prompt" => "a red fox"})

    assert %{"created" => created, "data" => [%{"b64_json" => b64}]} = json_response(conn, 200)
    assert is_integer(created)
    assert b64 == @png_b64
  end

  test "uses the instance's image_gen_model and adds text modality for google models", %{bypass: bypass} do
    instance = create_instance(%{image_gen_model: "google/gemini-2.5-flash-image"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "google/gemini-2.5-flash-image"
      assert sent["modalities"] == ["image", "text"]
      Plug.Conn.resp(req, 200, Jason.encode!(image_reply("google/gemini-2.5-flash-image")))
    end)

    assert post(conn, "/v1/images/generations", %{"prompt" => "x"}).status == 200
  end

  test "meters as request_type image_gen using the reported cost", %{conn: conn, bypass: bypass, instance: instance} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(image_reply("black-forest-labs/flux.2-klein-4b", %{"prompt_tokens" => 20, "completion_tokens" => 0, "cost" => 0.034})))
    end)

    post(conn, "/v1/images/generations", %{"prompt" => "x"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "image_gen"
    assert log.cost_cents == 3
    assert log.total_tokens == 0
    assert spent_today(instance) == 3
  end

  test "tolerates leading whitespace in the upstream body", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, "\n\n  " <> Jason.encode!(image_reply("black-forest-labs/flux.2-klein-4b")))
    end)

    assert [%{"b64_json" => _}] = json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 200)["data"]
  end

  test "returns an empty data list when the reply carries no images", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("no image for you")))
    end)

    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 200)["data"] == []
  end

  test "relays upstream errors and 429 on spent budget", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 402, ~s({"error":"pay"})) end)
    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 402) == %{"error" => "pay"}

    instance = create_instance(%{daily_budget_cents: 1})
    Druzhok.Budget.deduct(instance.id, 1)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)
    assert json_response(post(conn, "/v1/images/generations", %{"prompt" => "x"}), 429)["error"]["type"] == "budget_exceeded"
  end
end
```

- [ ] **Step 3: Run both files**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/embeddings_test.exs apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/image_gen_test.exs`
Expected: 10 tests, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/embeddings_test.exs apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/image_gen_test.exs
git commit -m "characterize embeddings and image generation proxy"
```

---

### Task 8: Responses API conversion

**Files:**
- Create: `apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/responses_test.exs`

- [ ] **Step 1: Write the tests**

```elixir
defmodule DruzhokWebWeb.LlmProxy.ResponsesTest do
  use DruzhokWebWeb.ProxyCase

  @input [
    %{"role" => "developer", "content" => "be brief"},
    %{"role" => "user", "content" => [
      %{"type" => "input_text", "text" => "what is this?"},
      %{"type" => "input_image", "image_url" => "data:image/png;base64,AAAA", "detail" => "low"}
    ]}
  ]

  test "converts the Responses input into a chat request on the instance's vision model",
       %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["model"] == "google/gemini-2.5-flash-lite"
      assert sent["max_tokens"] == 1024
      assert sent["stream"] == false
      assert sent["usage"] == %{"include" => true}
      [system, user] = sent["messages"]
      assert system == %{"role" => "system", "content" => "be brief"}
      assert user["content"] == [
        %{"type" => "input_text", "text" => "what is this?"},
        %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAAA", "detail" => "low"}}
      ]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("a cat", usage: %{"prompt_tokens" => 300, "completion_tokens" => 4, "cost" => 0.0})))
    end)

    conn = post(conn, "/v1/responses", %{"model" => "gpt-4o", "input" => @input})

    assert %{
      "id" => "resp_proxy",
      "object" => "response",
      "status" => "completed",
      "model" => "gpt-4o",
      "output" => [%{"type" => "message", "role" => "assistant", "content" => [%{"type" => "output_text", "text" => "a cat"}]}],
      "usage" => %{"input_tokens" => 300, "output_tokens" => 4}
    } = json_response(conn, 200)
  end

  test "honours max_output_tokens and a bare string input", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      sent = Jason.decode!(raw)
      assert sent["max_tokens"] == 50
      assert sent["messages"] == [%{"role" => "user", "content" => "hi"}]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("hey")))
    end)

    assert post(conn, "/v1/responses", %{"model" => "m", "input" => "hi", "max_output_tokens" => 50}).status == 200
  end

  test "sends a default prompt when input is empty", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["messages"] == [%{"role" => "user", "content" => "Describe this image."}]
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("ok")))
    end)

    assert post(conn, "/v1/responses", %{"model" => "m"}).status == 200
  end

  test "uses the instance image_model and meters as request_type image", %{bypass: bypass} do
    instance = create_instance(%{image_model: "openai/gpt-5.4-mini"})
    conn = authed(Phoenix.ConnTest.build_conn(), instance)

    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["model"] == "openai/gpt-5.4-mini"
      Plug.Conn.resp(req, 200, Jason.encode!(chat_completion("x", usage: %{"prompt_tokens" => 10, "completion_tokens" => 2, "cost" => 0.02})))
    end)

    post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"})

    assert [log] = usage_logs(instance)
    assert log.request_type == "image"
    assert log.model == "openai/gpt-5.4-mini"
    assert log.cost_cents == 2
  end

  test "streams the full text as a Responses SSE event sequence", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req ->
      {:ok, raw, req} = Plug.Conn.read_body(req)
      assert Jason.decode!(raw)["stream"] == true
      send_sse(req, sse_stream(["a ", "cat"], usage: %{"prompt_tokens" => 7, "completion_tokens" => 2, "cost" => 0.0}))
    end)

    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi", "stream" => true})

    assert conn.status == 200
    events =
      conn.resp_body
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data: "))
      |> Enum.map(&(&1 |> String.trim_leading("data: ") |> Jason.decode!()))

    assert Enum.map(events, & &1["type"]) == [
      "response.output_item.added",
      "response.output_text.delta",
      "response.output_text.done",
      "response.output_item.done",
      "response.completed"
    ]
    assert Enum.at(events, 1)["delta"] == "a cat"
    assert List.last(events)["response"]["usage"] == %{"input_tokens" => 7, "output_tokens" => 2}
  end

  test "passes a non-JSON upstream error body through unchanged", %{conn: conn, bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn req -> Plug.Conn.resp(req, 500, "boom") end)
    conn = post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"})
    assert conn.status == 500
    assert conn.resp_body == "boom"
  end

  test "429 when the budget is spent" do
    instance = create_instance(%{daily_budget_cents: 1})
    Druzhok.Budget.deduct(instance.id, 1)
    conn = authed(Phoenix.ConnTest.build_conn(), instance)
    assert json_response(post(conn, "/v1/responses", %{"model" => "m", "input" => "hi"}), 429)["error"]["type"] == "insufficient_quota"
  end
end
```

- [ ] **Step 2: Run the file**

Run: `mix test apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/responses_test.exs`
Expected: 7 tests, 0 failures.

- [ ] **Step 3: Check proxy coverage**

Run: `mix test --cover 2>&1 | grep -E "LlmProxyController|LlmFormat"`
Expected: `LlmProxyController` ≥ 80%. If below, the coverage HTML tells you which lines: run `mix test --cover --export-coverage default` then `mix test.coverage` in `apps/druzhok_web` and open `cover/Elixir.DruzhokWebWeb.LlmProxyController.html`. Add a test for each uncovered branch, following the patterns above, until 80% is reached.

- [ ] **Step 4: Commit**

```bash
git add apps/druzhok_web/test/druzhok_web_web/controllers/llm_proxy/responses_test.exs
git commit -m "characterize Responses API proxy"
```

---

### Task 9: Telegram stub and Telegram.API tests

**Files:**
- Modify: `apps/druzhok/mix.exs` (deps and `elixirc_paths`)
- Modify: `apps/druzhok/lib/druzhok/telegram/api.ex`
- Create: `apps/druzhok/test/support/telegram_stub.ex`
- Create: `apps/druzhok/test/druzhok/telegram/api_test.exs`

**Interfaces:**
- Produces: app env key `:telegram_api_base` under `:druzhok`, default `"https://api.telegram.org"`.
- Produces: `Druzhok.TelegramStub` with
  - `start(token :: String.t()) :: %{bypass: Bypass.t(), base: String.t(), calls: pid, updates: pid}` — stubs every method ManagerBot uses; sets `:telegram_api_base` to the Bypass URL and restores it on exit.
  - `push_update(stub, update :: map) :: :ok` — the next `getUpdates` returns it.
  - `calls(stub, method :: String.t()) :: [map]` — decoded request params in arrival order.
  - `await_call(stub, method, pred :: (map -> boolean), timeout_ms \\ 3_000) :: map` — polls until a matching call arrives, raises otherwise.
  - `set_managed_bot_token(stub, token :: String.t())` — what `getManagedBotToken` returns.

- [ ] **Step 1: Add bypass and test/support compilation to the core app**

In `apps/druzhok/mix.exs`:

In `project/0` add after `elixir: "~> 1.18",`:

```elixir
      elixirc_paths: elixirc_paths(Mix.env()),
```

Add to the module (before `defp deps`):

```elixir
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
```

In `deps/0` add:

```elixir
      {:bypass, "~> 2.1", only: :test},
```

Run: `mix deps.get`
Expected: no new packages (already fetched for druzhok_web), lockfile unchanged.

- [ ] **Step 2: Write the failing Telegram.API test**

Create `apps/druzhok/test/druzhok/telegram/api_test.exs`:

```elixir
defmodule Druzhok.Telegram.APITest do
  use ExUnit.Case, async: false

  alias Druzhok.Telegram.API

  setup do
    bypass = Bypass.open()
    prev = Application.get_env(:druzhok, :telegram_api_base)
    Application.put_env(:druzhok, :telegram_api_base, "http://localhost:#{bypass.port}")
    on_exit(fn ->
      if prev, do: Application.put_env(:druzhok, :telegram_api_base, prev), else: Application.delete_env(:druzhok, :telegram_api_base)
    end)
    %{bypass: bypass}
  end

  test "posts JSON to /bot<token>/<method> and unwraps result", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/sendMessage", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Jason.decode!(raw) == %{"chat_id" => 5, "text" => "hi", "parse_mode" => "Markdown"}
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 9}}))
    end)

    assert {:ok, %{"message_id" => 9}} = API.send_message("TOK", 5, "hi", %{parse_mode: "Markdown"})
  end

  test "returns {:error, body} when Telegram says ok=false", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getMe", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "description" => "Unauthorized"}))
    end)

    assert {:error, %{"ok" => false, "description" => "Unauthorized"}} = API.get_me("TOK")
  end

  test "returns {:error, body} on a non-200 status", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getUpdates", fn conn -> Plug.Conn.resp(conn, 401, "nope") end)
    assert {:error, "nope"} = API.get_updates("TOK", 0, 1)
  end

  test "returns {:error, reason} when unreachable", %{bypass: bypass} do
    Bypass.down(bypass)
    assert {:error, %Mint.TransportError{}} = API.get_me("TOK")
  end

  test "get_managed_bot_token sends user_id", %{bypass: bypass} do
    Bypass.expect_once(bypass, "POST", "/botTOK/getManagedBotToken", fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(raw) == %{"user_id" => 777}
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => true, "result" => "777:SECRET"}))
    end)

    assert {:ok, "777:SECRET"} = API.get_managed_bot_token("TOK", 777)
  end

  test "download_file fetches from /file/bot<token>/<path>", %{bypass: bypass} do
    Bypass.expect_once(bypass, "GET", "/file/botTOK/voice/1.oga", fn conn -> Plug.Conn.resp(conn, 200, "bytes") end)
    assert {:ok, "bytes"} = API.download_file("TOK", "voice/1.oga")
  end
end
```

- [ ] **Step 3: Run it, expect failure**

Run: `mix test apps/druzhok/test/druzhok/telegram/api_test.exs`
Expected: FAIL — requests go to `https://api.telegram.org`, Bypass reports no request arrived.

- [ ] **Step 4: Add the base URL seam**

In `apps/druzhok/lib/druzhok/telegram/api.ex` replace

```elixir
  @base_url "https://api.telegram.org/bot"
```

with

```elixir
  # Overridable so tests can point the client at a local stub.
  defp base_url, do: Application.get_env(:druzhok, :telegram_api_base) || "https://api.telegram.org"
  defp bot_url(token, method), do: "#{base_url()}/bot#{token}/#{method}"
```

Then replace every URL construction:

- in `send_document/4`: `url = "#{@base_url}#{token}/sendDocument"` → `url = bot_url(token, "sendDocument")`
- in `send_photo/4`: `url = "#{@base_url}#{token}/sendPhoto"` → `url = bot_url(token, "sendPhoto")`
- in `download_file/2`: `url = "https://api.telegram.org/file/bot#{token}/#{file_path}"` → `url = "#{base_url()}/file/bot#{token}/#{file_path}"`
- in `call/3`: `url = "#{@base_url}#{token}/#{method}"` → `url = bot_url(token, method)`

Since `defp` must come after the module attribute uses are gone, place the two `defp`s right above `defp call`.

- [ ] **Step 5: Run again**

Run: `mix test apps/druzhok/test/druzhok/telegram/api_test.exs`
Expected: 6 tests, 0 failures.

- [ ] **Step 6: Write the TelegramStub**

Create `apps/druzhok/test/support/telegram_stub.ex`:

```elixir
defmodule Druzhok.TelegramStub do
  @moduledoc """
  A fake Telegram Bot API on Bypass for driving `Druzhok.ManagerBot`.

  `getUpdates` long-polls an in-memory queue: `push_update/2` makes the next
  poll return that update, otherwise the poll waits 30 ms and returns `[]`
  (so the GenServer's loop stays cheap). Every call is recorded with its
  decoded params and can be waited on with `await_call/4`.
  """

  @poll_idle_ms 30

  def start(token) do
    bypass = Bypass.open()
    base = "http://localhost:#{bypass.port}"
    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, updates} = Agent.start_link(fn -> %{queue: [], managed_token: "999:MANAGED"} end)

    prev = Application.get_env(:druzhok, :telegram_api_base)
    Application.put_env(:druzhok, :telegram_api_base, base)

    ExUnit.Callbacks.on_exit(fn ->
      if prev, do: Application.put_env(:druzhok, :telegram_api_base, prev), else: Application.delete_env(:druzhok, :telegram_api_base)
    end)

    stub = %{bypass: bypass, base: base, calls: calls, updates: updates, token: token}

    Bypass.stub(bypass, "POST", "/bot#{token}/getMe", fn conn ->
      record(stub, "getMe", conn) |> reply(%{"id" => 1, "is_bot" => true, "username" => "test_manager_bot"})
    end)

    Bypass.stub(bypass, "POST", "/bot#{token}/getUpdates", fn conn ->
      conn = record(stub, "getUpdates", conn)
      batch = Agent.get_and_update(updates, fn s -> {s.queue, %{s | queue: []}} end)
      if batch == [], do: Process.sleep(@poll_idle_ms)
      reply(conn, batch)
    end)

    for method <- ["sendMessage", "editMessageText"] do
      Bypass.stub(bypass, "POST", "/bot#{token}/#{method}", fn conn ->
        record(stub, method, conn)
        |> reply(%{"message_id" => System.unique_integer([:positive]), "chat" => %{"id" => 1}})
      end)
    end

    Bypass.stub(bypass, "POST", "/bot#{token}/answerCallbackQuery", fn conn ->
      record(stub, "answerCallbackQuery", conn) |> reply(true)
    end)

    Bypass.stub(bypass, "POST", "/bot#{token}/getManagedBotToken", fn conn ->
      conn = record(stub, "getManagedBotToken", conn)
      reply(conn, Agent.get(updates, & &1.managed_token))
    end)

    stub
  end

  def push_update(%{updates: updates}, update) do
    Agent.update(updates, fn s -> %{s | queue: s.queue ++ [update]} end)
  end

  def set_managed_bot_token(%{updates: updates}, token) do
    Agent.update(updates, fn s -> %{s | managed_token: token} end)
  end

  def calls(%{calls: calls}, method) do
    calls |> Agent.get(& &1) |> Enum.reverse() |> Enum.filter(&(&1.method == method)) |> Enum.map(& &1.params)
  end

  def await_call(stub, method, pred, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(stub, method, pred, deadline)
  end

  defp do_await(stub, method, pred, deadline) do
    case Enum.find(calls(stub, method), pred) do
      nil ->
        if System.monotonic_time(:millisecond) > deadline do
          raise "no #{method} call matched within timeout; calls seen: #{inspect(calls(stub, method))}"
        end
        Process.sleep(20)
        do_await(stub, method, pred, deadline)

      params ->
        params
    end
  end

  defp record(%{calls: calls}, method, conn) do
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    params = if raw == "", do: %{}, else: Jason.decode!(raw)
    Agent.update(calls, &[%{method: method, params: params} | &1])
    conn
  end

  defp reply(conn, result) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => result}))
  end
end
```

- [ ] **Step 7: Compile and run the whole core suite**

Run: `mix test apps/druzhok/test/druzhok/telegram/api_test.exs` then `mix test`
Expected: compiles (`test/support` now on the path), all green.

- [ ] **Step 8: Commit**

```bash
git add apps/druzhok/mix.exs mix.lock apps/druzhok/lib/druzhok/telegram/api.ex apps/druzhok/test/support/telegram_stub.ex apps/druzhok/test/druzhok/telegram/api_test.exs
git commit -m "test Telegram.API against Bypass; add TelegramStub for manager bot tests"
```

---

### Task 10: Shared bot fixtures and BotManager lifecycle

**Files:**
- Create: `apps/druzhok/test/support/bot_fixtures.ex`
- Create: `apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs`

**Interfaces:**
- Produces: `Druzhok.BotFixtures.with_tmp_data_root/0 :: %{data_root: String.t()}` — creates a tmp dir, sets `DRUZHOK_DATA_ROOT`, restores and deletes on exit.
- Produces: `Druzhok.BotFixtures.cleanup_instance/1` — `BotManager.delete/1` wrapped in `on_exit`.
- Produces: `Druzhok.BotFixtures.eventually/2` — polls a predicate every 50 ms up to `tries` (default 40).

- [ ] **Step 1: Write the fixtures module**

```elixir
defmodule Druzhok.BotFixtures do
  @moduledoc "Setup helpers for tests that create real instances and run fake_hermes.sh."

  import ExUnit.Callbacks, only: [on_exit: 1]

  def with_tmp_data_root do
    root = Path.join(System.tmp_dir!(), "druzhok-root-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    prev = System.get_env("DRUZHOK_DATA_ROOT")
    System.put_env("DRUZHOK_DATA_ROOT", root)

    on_exit(fn ->
      if prev, do: System.put_env("DRUZHOK_DATA_ROOT", prev), else: System.delete_env("DRUZHOK_DATA_ROOT")
      File.rm_rf!(root)
    end)

    %{data_root: root}
  end

  @doc "Guarantee the bot's process and row are gone after the test, whatever happened."
  def cleanup_instance(name) do
    on_exit(fn ->
      Druzhok.Host.destroy(name)
      case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
        nil -> :ok
        inst -> Druzhok.Repo.delete(inst)
      end
    end)
  end

  def eventually(fun, tries \\ 40) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50); eventually(fun, tries - 1)
    end
  end
end
```

- [ ] **Step 2: Write the lifecycle tests**

```elixir
defmodule Druzhok.BotManagerLifecycleTest do
  # async: false — DRUZHOK_DATA_ROOT and real OS processes.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{BotManager, Instance, Repo, TokenPool}

  setup do
    ctx = with_tmp_data_root()
    name = "lc#{System.unique_integer([:positive])}"
    cleanup_instance(name)
    Map.put(ctx, :name, name)
  end

  describe "create/2" do
    test "inserts the row, seeds the workspace and starts the process", %{name: name, data_root: root} do
      assert {:ok, %{name: ^name, model: "z-ai/glm-5.3-flash"}} =
               BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1:A", owner_telegram_id: 42})

      inst = Repo.get_by!(Instance, name: name)
      assert inst.active
      assert inst.telegram_token == "1:A"
      assert inst.owner_telegram_id == 42
      assert String.starts_with?(inst.tenant_key, "dk-#{name}-")
      assert inst.workspace == Path.join([root, name, "workspace"])

      assert File.exists?(Path.join([root, name, "config.yaml"]))
      assert File.exists?(Path.join([root, name, "workspace", "AGENTS.md"]))
      assert File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "z-ai/glm-5.3-flash")

      assert eventually(fn -> BotManager.status(name) == "active" end)
      assert BotManager.logs(name, 5) =~ "TELEGRAM_BOT_TOKEN=1:A"
    end

    test "takes a token from the pool when none is given", %{name: name} do
      {:ok, pooled} = TokenPool.add("2:POOLED", "pooled_bot")
      on_exit(fn -> Repo.delete(pooled) end)

      assert {:ok, _} = BotManager.create(name, %{model: "z-ai/glm-5.3-flash"})
      assert Repo.get_by!(Instance, name: name).telegram_token == "2:POOLED"
      assert Repo.reload!(pooled).instance_id == Repo.get_by!(Instance, name: name).id
    end

    test "fails cleanly when the pool is empty", %{name: name} do
      assert {:error, "No Telegram tokens available in pool"} = BotManager.create(name, %{model: "m"})
      assert Repo.get_by(Instance, name: name) == nil
    end
  end

  describe "stop/1, start/1, restart/1" do
    setup %{name: name} do
      {:ok, _} = BotManager.create(name, %{model: "z-ai/glm-5.3-flash", telegram_token: "1:A"})
      assert eventually(fn -> BotManager.status(name) == "active" end)
      :ok
    end

    test "stop marks inactive and kills the process", %{name: name} do
      assert :ok = BotManager.stop(name)
      refute Repo.get_by!(Instance, name: name).active
      assert BotManager.status(name) == "inactive"
    end

    test "start after stop brings it back and re-syncs config from the DB", %{name: name, data_root: root} do
      :ok = BotManager.stop(name)
      Repo.get_by!(Instance, name: name) |> Instance.changeset(%{model: "openai/gpt-5.4-nano"}) |> Repo.update!()

      assert {:ok, ^name} = BotManager.start(name)
      assert Repo.get_by!(Instance, name: name).active
      assert File.read!(Path.join([root, name, "config.yaml"])) =~ ~s(default: "openai/gpt-5.4-nano")
      assert eventually(fn -> BotManager.status(name) == "active" end)
    end

    test "restart is stop then start", %{name: name} do
      assert {:ok, ^name} = BotManager.restart(name)
      assert Repo.get_by!(Instance, name: name).active
      assert eventually(fn -> BotManager.status(name) == "active" end)
    end

    test "start of an unknown name is an error" do
      assert {:error, :not_found} = BotManager.start("no-such-bot")
    end
  end

  describe "delete/1" do
    test "wipes the data dir under the root, releases the token and drops the row", %{name: name, data_root: root} do
      {:ok, pooled} = TokenPool.add("3:POOLED")
      on_exit(fn -> Repo.delete(pooled) end)
      {:ok, _} = BotManager.create(name, %{model: "m"})
      dir = Path.join(root, name)
      assert File.dir?(dir)

      assert :ok = BotManager.delete(name)

      refute File.exists?(dir)
      assert Repo.get_by(Instance, name: name) == nil
      assert Repo.reload!(pooled).instance_id == nil
      assert BotManager.status(name) == "inactive"
    end

    test "refuses to wipe a workspace outside the data root", %{name: name} do
      outside = Path.join(System.tmp_dir!(), "outside-#{name}")
      File.mkdir_p!(Path.join(outside, "workspace"))
      File.write!(Path.join(outside, "keep.txt"), "precious")
      on_exit(fn -> File.rm_rf!(outside) end)

      %Instance{}
      |> Instance.changeset(%{name: name, model: "m", workspace: Path.join(outside, "workspace"), tenant_key: "dk-x"})
      |> Repo.insert!()

      assert :ok = BotManager.delete(name)

      assert File.read!(Path.join(outside, "keep.txt")) == "precious"
      assert Repo.get_by(Instance, name: name) == nil
    end

    test "delete of an unknown name is a no-op" do
      assert :ok = BotManager.delete("no-such-bot")
    end
  end
end
```

- [ ] **Step 3: Run the file**

Run: `mix test apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs`
Expected: 10 tests, 0 failures. If `TokenPool.add/2` collides with a token left by an aborted earlier run, the unique constraint error names it; delete that row from `data/druzhok_test.db` with `sqlite3 data/druzhok_test.db "delete from tokens"`.

- [ ] **Step 4: Commit**

```bash
git add apps/druzhok/test/support/bot_fixtures.ex apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs
git commit -m "test BotManager lifecycle against Host.Process"
```

---

### Task 11: ManagerBot end to end

**Files:**
- Modify: `apps/druzhok/lib/druzhok/manager_bot.ex:21-23`
- Create: `apps/druzhok/test/druzhok/manager_bot_test.exs`

**Interfaces:**
- Consumes: `Druzhok.TelegramStub`, `Druzhok.BotFixtures`.
- Produces: `Druzhok.ManagerBot.start_link(name: atom)` starts an unregistered-by-default-name instance for tests.

- [ ] **Step 1: Write the failing test file**

```elixir
defmodule Druzhok.ManagerBotTest do
  # async: false — app env, DRUZHOK_DATA_ROOT, global Settings row.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{ManagerBot, Instance, Repo, TelegramStub}

  @token "111:MANAGER"
  @owner 4242

  setup do
    ctx = with_tmp_data_root()
    stub = TelegramStub.start(@token)
    Druzhok.Settings.set("manager_bot_token", @token)
    on_exit(fn -> Druzhok.Settings.set("manager_bot_token", "") end)

    {:ok, pid} = ManagerBot.start_link(name: :"manager_#{System.unique_integer([:positive])}")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # Started as @test_manager_bot: getMe was called and polling began.
    TelegramStub.await_call(stub, "getMe", fn _ -> true end)

    Map.merge(ctx, %{stub: stub, pid: pid})
  end

  defp message(text, uid \\ @owner) do
    %{"update_id" => System.unique_integer([:positive]),
      "message" => %{"message_id" => 1, "from" => %{"id" => uid}, "chat" => %{"id" => uid}, "text" => text}}
  end

  defp callback(data, uid \\ @owner, message_id \\ 55) do
    %{"update_id" => System.unique_integer([:positive]),
      "callback_query" => %{"id" => "cb#{System.unique_integer([:positive])}", "from" => %{"id" => uid}, "data" => data,
        "message" => %{"message_id" => message_id, "chat" => %{"id" => uid}}}}
  end

  defp sent_texts(stub), do: Enum.map(TelegramStub.calls(stub, "sendMessage"), & &1["text"])

  test "stays idle and polls nothing when no token is configured", %{stub: stub} do
    Druzhok.Settings.set("manager_bot_token", "")
    {:ok, pid} = ManagerBot.start_link(name: :idle_manager)
    Process.sleep(100)
    assert Process.alive?(pid)
    GenServer.stop(pid)
    # Only the instance from setup called getMe.
    assert length(TelegramStub.calls(stub, "getMe")) == 1
  end

  test "/start replies with the welcome text and the two-button reply keyboard", %{stub: stub} do
    TelegramStub.push_update(stub, message("/start"))

    params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
    keyboard = Jason.decode!(params["reply_markup"])
    assert keyboard["keyboard"] == [[%{"text" => "🤖 Создать бота"}, %{"text" => "📋 Мои боты"}]]
    assert keyboard["resize_keyboard"] == true
  end

  test "unknown text outside a flow shows the main menu", %{stub: stub} do
    TelegramStub.push_update(stub, message("blah"))
    assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
  end

  test "create flow: name → language keyboard → confirm with a t.me/newbot link", %{stub: stub} do
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))

    TelegramStub.push_update(stub, message("Вася"))
    lang = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:"))
    assert Jason.decode!(lang["reply_markup"])["inline_keyboard"] == [[
      %{"text" => "🇷🇺 Русский", "callback_data" => "lang:ru"},
      %{"text" => "🇬🇧 English", "callback_data" => "lang:en"}
    ]]

    TelegramStub.push_update(stub, callback("lang:ru"))
    TelegramStub.await_call(stub, "answerCallbackQuery", fn _ -> true end)
    confirm = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Вася"))
    assert confirm["message_id"] == 55
    assert confirm["parse_mode"] == "Markdown"
    assert confirm["text"] =~ "Язык: Русский"
    [[button]] = Jason.decode!(confirm["reply_markup"])["inline_keyboard"]
    assert button["url"] =~ ~r{^https://t\.me/newbot/test_manager_bot/vasya_[0-9a-f]{4}_bot\?name=}
  end

  test "empty name re-prompts; stray text at the language step re-shows the keyboard", %{stub: stub} do
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    TelegramStub.push_update(stub, message("   "))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "не может быть пустым"))

    TelegramStub.push_update(stub, message("Kot"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:"))
    TelegramStub.push_update(stub, message("hello?"))
    # Session has no message_id yet (the language keyboard was sent, not edited), so a fresh keyboard is sent.
    assert eventually(fn -> Enum.count(sent_texts(stub), &(&1 == "Язык:")) == 2 end)
  end

  test "managed_bot update provisions a bot for the creator", %{stub: stub, data_root: root} do
    TelegramStub.set_managed_bot_token(stub, "555:NEWBOT")
    cleanup_instance("kot_1a2b")

    # Walk the flow so the session carries name + language.
    TelegramStub.push_update(stub, message("🤖 Создать бота"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    TelegramStub.push_update(stub, message("Кот"))
    TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:"))
    TelegramStub.push_update(stub, callback("lang:en"))
    TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Кот"))

    TelegramStub.push_update(stub, %{
      "update_id" => System.unique_integer([:positive]),
      "managed_bot" => %{"user" => %{"id" => @owner}, "bot" => %{"id" => 555, "username" => "kot_1a2b_bot"}}
    })

    assert TelegramStub.await_call(stub, "getManagedBotToken", &(&1["user_id"] == 555), 10_000)
    done = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "создан и запущен"), 15_000)
    assert done["chat_id"] == @owner
    assert done["text"] =~ "https://t.me/kot_1a2b_bot"

    inst = Repo.get_by!(Instance, name: "kot_1a2b")
    assert inst.telegram_token == "555:NEWBOT"
    assert inst.owner_telegram_id == @owner
    assert inst.language == "en"
    assert inst.model == "z-ai/glm-5.3-flash"
    assert inst.mention_only
    assert File.read!(Path.join([root, "kot_1a2b", "SOUL.md"])) =~ "Тебя зовут Кот"
  end

  test "provisioning failure is reported to the creator", %{stub: stub} do
    Bypass.stub(stub.bypass, "POST", "/bot#{@token}/getManagedBotToken", fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{"ok" => false, "description" => "BOT_NOT_MANAGED"}))
    end)

    TelegramStub.push_update(stub, %{
      "update_id" => 1, "managed_bot" => %{"user" => %{"id" => @owner}, "bot" => %{"id" => 556, "username" => "ghost_bot"}}
    })

    assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Ошибка создания бота"), 10_000)
    assert Repo.get_by(Instance, name: "ghost") == nil
  end

  describe "with two existing bots" do
    setup %{data_root: _} do
      for n <- ["own1", "own2"] do
        %Instance{}
        |> Instance.changeset(%{name: n, model: "m", workspace: "/tmp/#{n}/ws", tenant_key: "dk-#{n}",
                                owner_telegram_id: @owner, trigger_name: "#{n}_bot", daily_budget_cents: 100})
        |> Repo.insert!()
      end
      on_exit(fn -> Repo.delete_all(Ecto.Query.from(i in Instance, where: i.name in ["own1", "own2"])) end)
      :ok
    end

    test "creating a third is refused", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "уже 2 бота"))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "Мои боты lists them with budget and a delete button each", %{stub: stub} do
      TelegramStub.push_update(stub, message("📋 Мои боты"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Твои боты"))
      assert params["text"] =~ "*own1*"
      assert params["text"] =~ "$0.00 / $1.00 (0%)"
      rows = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert length(rows) == 2
      [[open, del]] = Enum.take(rows, 1)
      assert open["url"] == "https://t.me/own1_bot"
      assert del["callback_data"] =~ ~r/^del:\d+$/
    end

    test "delete asks for confirmation, then deletes only the owner's bot", %{stub: stub} do
      id = Repo.get_by!(Instance, name: "own1").id
      cleanup_instance("own1")

      TelegramStub.push_update(stub, callback("del:#{id}"))
      ask = TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Точно удалить @own1_bot"))
      [[yes, no]] = Jason.decode!(ask["reply_markup"])["inline_keyboard"]
      assert yes["callback_data"] == "delyes:#{id}"
      assert no["callback_data"] == "delno"

      TelegramStub.push_update(stub, callback("delno"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "Отменено."))
      assert Repo.get(Instance, id)

      TelegramStub.push_update(stub, callback("delyes:#{id}"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "✅ Бот @own1_bot удалён."), 10_000)
      assert Repo.get(Instance, id) == nil
    end

    test "a stranger cannot delete someone else's bot", %{stub: stub} do
      id = Repo.get_by!(Instance, name: "own2").id
      TelegramStub.push_update(stub, callback("del:#{id}", 999))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Это не твой бот."))
      assert Repo.get(Instance, id)
    end

    test "deleting an unknown id says not found", %{stub: stub} do
      TelegramStub.push_update(stub, callback("del:999999"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Бот не найден."))
    end
  end

  test "a callback whose message is inaccessible is acknowledged and ignored", %{stub: stub} do
    TelegramStub.push_update(stub, %{"update_id" => 7, "callback_query" => %{"id" => "cbx", "from" => %{"id" => @owner}, "data" => "lang:ru"}})
    assert TelegramStub.await_call(stub, "answerCallbackQuery", &(&1["callback_query_id"] == "cbx"))
    Process.sleep(50)
    assert TelegramStub.calls(stub, "sendMessage") == []
  end
end
```

- [ ] **Step 2: Run it, expect failure**

Run: `mix test apps/druzhok/test/druzhok/manager_bot_test.exs`
Expected: FAIL in setup: `{:error, {:already_started, pid}}` because `start_link/1` ignores `opts[:name]` and registers as `Druzhok.ManagerBot`, which the application already started.

- [ ] **Step 3: Add the name option**

In `apps/druzhok/lib/druzhok/manager_bot.ex` replace

```elixir
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
```

with

```elixir
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end
```

- [ ] **Step 4: Run again**

Run: `mix test apps/druzhok/test/druzhok/manager_bot_test.exs`
Expected: 14 tests, 0 failures. Two things that can legitimately differ and should be corrected in the test, not the code:
- the exact welcome/limit strings live in `Druzhok.ManagerBot.Onboarding`; copy them from there if an `=~` fails;
- the budget line format comes from `Onboarding.format_budget/2`; match what it prints.

- [ ] **Step 5: Check ManagerBot coverage**

Run: `mix test --cover 2>&1 | grep -E "ManagerBot|Telegram.API|BotManager"`
Expected: `Druzhok.ManagerBot` ≥ 80%, `Druzhok.ManagerBot.Provisioner` ≥ 80%, `Druzhok.BotManager` ≥ 80%, `Druzhok.Telegram.API` ≥ 50% (the photo/document multipart senders are not used by the manager bot and are out of scope).

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok/lib/druzhok/manager_bot.ex apps/druzhok/test/druzhok/manager_bot_test.exs
git commit -m "test ManagerBot end to end against a stub Telegram API"
```

---

### Task 12: Coverage gate

**Files:**
- Modify: `apps/druzhok/mix.exs` (`project/0`)
- Modify: `apps/druzhok_web/mix.exs` (`project/0`)
- Modify: `CLAUDE.md` (Development section)

- [ ] **Step 1: Measure**

Run: `mix test --cover 2>&1 | grep -E "^\s+[0-9.]+% \| Total"`
Expected: two lines, core around 60% and web around 45%. Note both numbers.

- [ ] **Step 2: Set thresholds**

In `apps/druzhok/mix.exs` `project/0`, add:

```elixir
      test_coverage: [summary: [threshold: 55]],
```

In `apps/druzhok_web/mix.exs` `project/0`, add:

```elixir
      test_coverage: [
        summary: [threshold: 40],
        ignore_modules: [
          ~r/^DruzhokWebWeb\.Live\.Components\./,
          DruzhokWebWeb.ErrorsLive,
          DruzhokWebWeb.UsageLive,
          DruzhokWebWeb.Layouts,
          DruzhokWebWeb.Telemetry,
          DruzhokWeb.Application
        ]
      ],
```

Replace `55` and `40` with the measured totals from Step 1 rounded **down** to the nearest multiple of 5. The gate is there to stop regressions, not to be aspirational; it gets raised each time coverage grows.

- [ ] **Step 3: Verify the gate passes and would fail on regression**

Run: `mix test --cover`
Expected: both apps print `Coverage: NN%` with no `threshold not met`.

Temporarily change the core threshold to `95`, run `mix test --cover` again.
Expected: `Coverage test failed, threshold not met` for druzhok and a non-zero exit code. Restore the real number.

- [ ] **Step 4: Document**

In `CLAUDE.md`, in the "Development (macOS, no Docker)" code block, after `mix deps.get && mix compile && mix test` add a line:

```bash
mix test --cover        # enforces per-app thresholds set in each mix.exs; raise them when coverage grows
```

- [ ] **Step 5: Commit**

```bash
git add apps/druzhok/mix.exs apps/druzhok_web/mix.exs CLAUDE.md
git commit -m "enforce coverage thresholds"
```

---

## Self-review

**Requirement coverage**

| Requirement | Tasks |
|---|---|
| 1. Proxy ≥ 80%, every connector | 1–8 |
| 2. ManagerBot ≥ 80%, all flows | 9 (stub), 11 |
| 3. BotManager lifecycle incl. wipe guard | 10 |
| 4. Coverage threshold enforced | 12 |
| 5. Assertions on upstream request and client response | every proxy test reads the Bypass request body and asserts on it |

**Seams introduced in `lib/`**: `openai_api_url` (Task 5), `telegram_api_base` (Task 9), `ManagerBot.start_link(name:)` (Task 11). All three default to today's behaviour.

**Known soft spots**
- Task 3 "dies mid-stream" and Task 2 budget-message assertion may need their expected values copied from actual output. That is by design for characterization tests; the plan says so at those steps.
- `Bypass.stub` with a path containing the token: Bypass matches literal paths, so the token must not contain characters Plug.Router treats specially. `111:MANAGER` and `TOK` are safe.
- The application's own `Druzhok.ManagerBot` (registered name) is also running in the test VM and re-reads the `manager_bot_token` setting every 60 s. Tests set the token only for their own duration and blank it in `on_exit`; a test file that runs longer than 60 s could wake the global instance, which would then also poll the stub. If that ever shows up as duplicated `sendMessage` calls, stop the global instance in `test_helper.exs` with `GenServer.stop(Druzhok.ManagerBot)` after `ExUnit.start()`.
