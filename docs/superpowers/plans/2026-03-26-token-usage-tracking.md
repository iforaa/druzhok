# Token Usage Tracking — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture actual token counts from every LLM API call, store them in a database table, and display on a dashboard page for monitoring and optimization.

**Architecture:** Add `input_tokens`/`output_tokens` to `Client.Result` struct, extract usage from both OpenAI and Anthropic streaming+sync responses, emit counts in Loop's `:llm_done` event, write to `llm_requests` DB table from Instance.Sup's `on_event`, display on a new `/usage` LiveView page.

**Tech Stack:** Elixir/OTP, Ecto (SQLite), Phoenix LiveView

---

### Task 1: Add usage fields to Client.Result

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/llm/client.ex`

- [ ] **Step 1: Add fields to Result struct**

In `v3/apps/pi_core/lib/pi_core/llm/client.ex`, replace line 8:

```elixir
    defstruct content: "", tool_calls: [], reasoning: ""
```

with:

```elixir
    defstruct content: "", tool_calls: [], reasoning: "",
              input_tokens: 0, output_tokens: 0
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```
git add v3/apps/pi_core/lib/pi_core/llm/client.ex
git commit -m "add input_tokens and output_tokens to LLM Client.Result"
```

---

### Task 2: Extract usage from OpenAI client

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/llm/openai.ex`

- [ ] **Step 1: Add stream_options to request body**

In `v3/apps/pi_core/lib/pi_core/llm/openai.ex`, in `build_request/1` (line 13), change:

```elixir
    body = %{model: opts.model, messages: messages, max_tokens: opts.max_tokens, stream: opts.stream}
```

to:

```elixir
    body = %{model: opts.model, messages: messages, max_tokens: opts.max_tokens, stream: opts.stream}
    body = if opts.stream, do: Map.put(body, :stream_options, %{include_usage: true}), else: body
```

- [ ] **Step 2: Parse usage from streaming events**

In `process_stream_event/4` (line 87), the function currently only processes `choices`. Add usage parsing. Replace the entire function:

```elixir
  defp process_stream_event(event, result, tc_asm, on_delta) do
    # Parse usage from final chunk (OpenAI sends usage in the last event when stream_options.include_usage is true)
    result = case event["usage"] do
      %{"prompt_tokens" => input, "completion_tokens" => output} ->
        %{result | input_tokens: input, output_tokens: output}
      _ -> result
    end

    choices = event["choices"] || []

    Enum.reduce(choices, {result, tc_asm}, fn choice, {acc, asm} ->
      delta = choice["delta"] || %{}
      message = choice["message"]

      # Text content from delta
      acc = if delta["content"] && delta["content"] != "" do
        if on_delta, do: on_delta.(delta["content"])
        %{acc | content: acc.content <> delta["content"]}
      else
        acc
      end

      # Reasoning content from delta
      acc = if delta["reasoning_content"] && delta["reasoning_content"] != "" do
        %{acc | reasoning: acc.reasoning <> delta["reasoning_content"]}
      else
        acc
      end

      # Tool calls from delta (streaming assembly)
      asm = if delta["tool_calls"] do
        Enum.reduce(delta["tool_calls"], asm, fn call, a ->
          index = call["index"] || 0
          a = if call["id"] do
            ToolCallAssembler.start_call(a, index, call["id"], get_in(call, ["function", "name"]) || "")
          else
            a
          end
          args_fragment = get_in(call, ["function", "arguments"]) || ""
          if args_fragment != "", do: ToolCallAssembler.append_args(a, index, args_fragment), else: a
        end)
      else
        asm
      end

      # Non-streaming message (some events include full message)
      acc = if message do
        acc = if message["content"], do: %{acc | content: message["content"]}, else: acc
        acc = if message["tool_calls"], do: %{acc | tool_calls: message["tool_calls"]}, else: acc
        acc
      else
        acc
      end

      {acc, asm}
    end)
  end
```

- [ ] **Step 3: Extract usage from sync response**

In `sync_completion/1` (line 138), replace the success clause:

```elixir
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        data = Jason.decode!(body)
        choice = hd(data["choices"])
        message = choice["message"]
        usage = data["usage"] || %{}
        {:ok, %Result{
          content: message["content"] || "",
          tool_calls: message["tool_calls"] || [],
          reasoning: message["reasoning_content"] || "",
          input_tokens: usage["prompt_tokens"] || 0,
          output_tokens: usage["completion_tokens"] || 0
        }}
```

- [ ] **Step 4: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 5: Commit**

```
git add v3/apps/pi_core/lib/pi_core/llm/openai.ex
git commit -m "extract token usage from OpenAI streaming and sync responses"
```

---

### Task 3: Extract usage from Anthropic client

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/llm/anthropic.ex`

- [ ] **Step 1: Handle message_start event for input_tokens**

In `handle_event/6`, the catch-all clause (line 130) currently ignores all unrecognized events. Replace it to capture `message_start` and `message_delta` usage:

```elixir
  defp handle_event(%{"type" => "message_start", "message" => msg}, result, token_sent, tc_asm, _on_delta, _on_event) do
    input_tokens = get_in(msg, ["usage", "input_tokens"]) || 0
    {%{result | input_tokens: input_tokens}, token_sent, tc_asm}
  end

  defp handle_event(%{"type" => "message_delta", "usage" => usage}, result, token_sent, tc_asm, _on_delta, _on_event) do
    output_tokens = usage["output_tokens"] || 0
    {%{result | output_tokens: output_tokens}, token_sent, tc_asm}
  end

  defp handle_event(_event, result, token_sent, tc_asm, _on_delta, _on_event) do
    {result, token_sent, tc_asm}
  end
```

Note: This replaces the single catch-all with three clauses. The `message_start` event from Anthropic looks like `{"type": "message_start", "message": {"usage": {"input_tokens": 25}}}`. The `message_delta` event looks like `{"type": "message_delta", "usage": {"output_tokens": 15}}`.

- [ ] **Step 2: Extract usage from sync response**

In `parse_response/1` (line 161), add usage extraction. Replace:

```elixir
  defp parse_response(%{"content" => content} = data) do
```

with:

```elixir
  defp parse_response(%{"content" => content} = data) do
    usage = data["usage"] || %{}
```

And replace the Result construction at the end (line 178):

```elixir
    %Result{
      content: text,
      tool_calls: tool_calls,
      reasoning: reasoning
    }
```

with:

```elixir
    %Result{
      content: text,
      tool_calls: tool_calls,
      reasoning: reasoning,
      input_tokens: usage["input_tokens"] || 0,
      output_tokens: usage["output_tokens"] || 0
    }
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```
git add v3/apps/pi_core/lib/pi_core/llm/anthropic.ex
git commit -m "extract token usage from Anthropic streaming and sync responses"
```

---

### Task 4: Add token counts to Loop's llm_done event

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/loop.ex`

- [ ] **Step 1: Enhance llm_done event emission**

In `v3/apps/pi_core/lib/pi_core/loop.ex`, replace the `:llm_done` emit call (lines 70-72):

```elixir
        emit(opts, %{type: :llm_done, iteration: iterations, elapsed_ms: elapsed,
                     has_tool_calls: has_tools, content_length: content_len,
                     reasoning_length: String.length(result.reasoning || "")})
```

with:

```elixir
        tool_calls_count = if has_tools, do: length(result.tool_calls), else: 0
        emit(opts, %{type: :llm_done, iteration: iterations, elapsed_ms: elapsed,
                     has_tool_calls: has_tools, tool_calls_count: tool_calls_count,
                     content_length: content_len,
                     reasoning_length: String.length(result.reasoning || ""),
                     input_tokens: result.input_tokens, output_tokens: result.output_tokens,
                     model: opts[:model]})
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```
git add v3/apps/pi_core/lib/pi_core/loop.ex
git commit -m "add token counts and model to llm_done event"
```

---

### Task 5: Create LlmRequest schema and migration

**Files:**
- Create: `v3/apps/druzhok/lib/druzhok/llm_request.ex`
- Create: `v3/apps/druzhok/priv/repo/migrations/20260326000001_create_llm_requests.exs`

- [ ] **Step 1: Create migration**

Create file `v3/apps/druzhok/priv/repo/migrations/20260326000001_create_llm_requests.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.CreateLlmRequests do
  use Ecto.Migration

  def change do
    create table(:llm_requests) do
      add :instance_name, :string
      add :chat_id, :integer
      add :model, :string
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :tool_calls_count, :integer, default: 0
      add :elapsed_ms, :integer
      add :iteration, :integer, default: 0

      timestamps(updated_at: false)
    end

    create index(:llm_requests, [:instance_name, :inserted_at])
    create index(:llm_requests, [:inserted_at])
  end
end
```

- [ ] **Step 2: Create Ecto schema with query helpers**

Create file `v3/apps/druzhok/lib/druzhok/llm_request.ex`:

```elixir
defmodule Druzhok.LlmRequest do
  use Ecto.Schema
  import Ecto.Query

  schema "llm_requests" do
    field :instance_name, :string
    field :chat_id, :integer
    field :model, :string
    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :tool_calls_count, :integer, default: 0
    field :elapsed_ms, :integer
    field :iteration, :integer, default: 0

    timestamps(updated_at: false)
  end

  def log(attrs) do
    Task.start(fn ->
      %__MODULE__{}
      |> Ecto.Changeset.cast(attrs, [:instance_name, :chat_id, :model, :input_tokens, :output_tokens, :tool_calls_count, :elapsed_ms, :iteration])
      |> Druzhok.Repo.insert()
    end)
  end

  def recent(limit \\ 100) do
    from(r in __MODULE__, order_by: [desc: r.inserted_at], limit: ^limit)
    |> Druzhok.Repo.all()
  end

  def recent_filtered(opts) do
    query = from(r in __MODULE__, order_by: [desc: r.inserted_at])

    query = if opts[:instance_name] && opts[:instance_name] != "",
      do: where(query, [r], r.instance_name == ^opts[:instance_name]),
      else: query

    query = if opts[:model] && opts[:model] != "",
      do: where(query, [r], r.model == ^opts[:model]),
      else: query

    query = if opts[:since],
      do: where(query, [r], r.inserted_at >= ^opts[:since]),
      else: query

    query
    |> limit(^(opts[:limit] || 200))
    |> Druzhok.Repo.all()
  end

  def summary_today do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    from(r in __MODULE__,
      where: r.inserted_at >= ^start_of_day,
      group_by: r.instance_name,
      select: %{
        instance_name: r.instance_name,
        total_input: sum(r.input_tokens),
        total_output: sum(r.output_tokens),
        request_count: count(r.id)
      }
    )
    |> Druzhok.Repo.all()
  end

  def summary_by_model do
    today = Date.utc_today()
    start_of_day = DateTime.new!(today, ~T[00:00:00], "Etc/UTC")

    from(r in __MODULE__,
      where: r.inserted_at >= ^start_of_day,
      group_by: r.model,
      select: %{
        model: r.model,
        total_input: sum(r.input_tokens),
        total_output: sum(r.output_tokens),
        request_count: count(r.id)
      },
      order_by: [desc: sum(r.input_tokens)]
    )
    |> Druzhok.Repo.all()
  end

  def cleanup_old do
    cutoff = DateTime.utc_now() |> DateTime.add(-30, :day)
    from(r in __MODULE__, where: r.inserted_at < ^cutoff)
    |> Druzhok.Repo.delete_all()
  end
end
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 4: Run migration**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix ecto.migrate`
Expected: migration runs successfully

- [ ] **Step 5: Commit**

```
git add v3/apps/druzhok/lib/druzhok/llm_request.ex v3/apps/druzhok/priv/repo/migrations/20260326000001_create_llm_requests.exs
git commit -m "add LlmRequest schema and migration for token tracking"
```

---

### Task 6: Write to DB from on_event

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`

- [ ] **Step 1: Add llm_done handler to on_event closure**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, replace the `on_event` closure (lines 32-41):

```elixir
    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
      if event[:type] == :tool_call do
        tool_name = event[:name]
        case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
          [{pid, _}] -> send(pid, {:pi_tool_status, tool_name})
          [] -> :ok
        end
      end
    end
```

with:

```elixir
    on_event = fn event ->
      Druzhok.Events.broadcast(name, event)
      case event[:type] do
        :tool_call ->
          tool_name = event[:name]
          case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
            [{pid, _}] -> send(pid, {:pi_tool_status, tool_name})
            [] -> :ok
          end

        :llm_done ->
          Druzhok.LlmRequest.log(%{
            instance_name: name,
            model: event[:model],
            input_tokens: event[:input_tokens] || 0,
            output_tokens: event[:output_tokens] || 0,
            tool_calls_count: event[:tool_calls_count] || 0,
            elapsed_ms: event[:elapsed_ms],
            iteration: event[:iteration]
          })

        _ -> :ok
      end
    end
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 3: Commit**

```
git add v3/apps/druzhok/lib/druzhok/instance/sup.ex
git commit -m "log LLM token usage to database from on_event"
```

---

### Task 7: Create Usage LiveView page

**Files:**
- Create: `v3/apps/druzhok_web/lib/druzhok_web_web/live/usage_live.ex`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/router.ex`

- [ ] **Step 1: Create UsageLive**

Create file `v3/apps/druzhok_web/lib/druzhok_web_web/live/usage_live.ex`:

```elixir
defmodule DruzhokWebWeb.UsageLive do
  use DruzhokWebWeb, :live_view

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket), do: :timer.send_interval(15_000, self(), :refresh)

    current_user = case session["user_id"] do
      nil -> nil
      id -> Druzhok.Repo.get(Druzhok.User, id)
    end

    instances = Druzhok.Repo.all(Druzhok.Instance) |> Enum.map(& &1.name)

    {:ok, assign(socket,
      current_user: current_user,
      instances: instances,
      filter_instance: "",
      filter_model: "",
      summary_today: Druzhok.LlmRequest.summary_today(),
      summary_by_model: Druzhok.LlmRequest.summary_by_model(),
      requests: Druzhok.LlmRequest.recent(200)
    )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, assign(socket,
      summary_today: Druzhok.LlmRequest.summary_today(),
      summary_by_model: Druzhok.LlmRequest.summary_by_model(),
      requests: load_requests(socket.assigns)
    )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("filter", params, socket) do
    assigns = socket.assigns
    |> Map.put(:filter_instance, params["instance"] || "")
    |> Map.put(:filter_model, params["model"] || "")

    requests = load_requests(assigns)
    {:noreply, assign(socket, filter_instance: assigns.filter_instance, filter_model: assigns.filter_model, requests: requests)}
  end

  defp load_requests(assigns) do
    Druzhok.LlmRequest.recent_filtered(%{
      instance_name: assigns.filter_instance,
      model: assigns.filter_model,
      limit: 200
    })
  end

  defp format_number(n) when is_integer(n) and n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  defp format_number(n) when is_integer(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n) when is_integer(n), do: Integer.to_string(n)
  defp format_number(nil), do: "0"

  defp format_time(dt) do
    Calendar.strftime(dt, "%H:%M:%S")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <div class="w-72 bg-gray-50 border-r border-gray-200 flex flex-col">
        <div class="p-4 border-b border-gray-200">
          <a href="/" class="text-lg font-bold tracking-tight hover:text-gray-600 transition">&larr; Druzhok</a>
        </div>
        <div class="p-4 space-y-4">
          <div class="text-sm font-medium text-gray-500 uppercase tracking-wide">Token Usage</div>

          <form phx-change="filter" class="space-y-2">
            <select name="instance" class="w-full text-sm border border-gray-300 rounded px-2 py-1">
              <option value="">All instances</option>
              <%= for name <- @instances do %>
                <option value={name} selected={@filter_instance == name}><%= name %></option>
              <% end %>
            </select>
          </form>

          <div class="space-y-3">
            <div class="text-xs font-medium text-gray-500 uppercase">Today by Instance</div>
            <%= for s <- @summary_today do %>
              <div class="bg-white rounded p-2 border border-gray-200">
                <div class="text-sm font-medium"><%= s.instance_name %></div>
                <div class="text-xs text-gray-500 mt-1">
                  <span class="text-blue-600"><%= format_number(s.total_input) %> in</span> /
                  <span class="text-green-600"><%= format_number(s.total_output) %> out</span>
                  &middot; <%= s.request_count %> calls
                </div>
              </div>
            <% end %>
            <div :if={@summary_today == []} class="text-xs text-gray-400">No requests today</div>
          </div>

          <div class="space-y-3">
            <div class="text-xs font-medium text-gray-500 uppercase">Today by Model</div>
            <%= for s <- @summary_by_model do %>
              <div class="bg-white rounded p-2 border border-gray-200">
                <div class="text-sm font-medium font-mono truncate"><%= s.model %></div>
                <div class="text-xs text-gray-500 mt-1">
                  <span class="text-blue-600"><%= format_number(s.total_input) %> in</span> /
                  <span class="text-green-600"><%= format_number(s.total_output) %> out</span>
                  &middot; <%= s.request_count %> calls
                </div>
              </div>
            <% end %>
            <div :if={@summary_by_model == []} class="text-xs text-gray-400">No requests today</div>
          </div>
        </div>

        <div :if={@current_user} class="mt-auto p-4 border-t border-gray-200">
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <div class="text-sm font-medium truncate"><%= @current_user.email %></div>
              <div class="text-xs text-gray-400"><%= @current_user.role %></div>
            </div>
            <a href="/auth/logout" class="text-xs text-gray-400 hover:text-gray-900 transition">Logout</a>
          </div>
        </div>
      </div>

      <div class="flex-1 overflow-y-auto p-6">
        <h2 class="text-lg font-bold mb-4">Request Log</h2>
        <div class="overflow-x-auto">
          <table class="w-full text-sm">
            <thead>
              <tr class="border-b border-gray-200 text-left text-xs text-gray-500 uppercase">
                <th class="px-3 py-2">Time</th>
                <th class="px-3 py-2">Instance</th>
                <th class="px-3 py-2">Model</th>
                <th class="px-3 py-2 text-right">Input</th>
                <th class="px-3 py-2 text-right">Output</th>
                <th class="px-3 py-2 text-right">Total</th>
                <th class="px-3 py-2 text-right">Tools</th>
                <th class="px-3 py-2 text-right">Time (ms)</th>
              </tr>
            </thead>
            <tbody>
              <%= for req <- @requests do %>
                <tr class="border-b border-gray-100 hover:bg-gray-50">
                  <td class="px-3 py-2 text-xs text-gray-500 font-mono"><%= format_time(req.inserted_at) %></td>
                  <td class="px-3 py-2"><%= req.instance_name %></td>
                  <td class="px-3 py-2 font-mono text-xs truncate max-w-[200px]"><%= req.model %></td>
                  <td class="px-3 py-2 text-right text-blue-600 font-mono"><%= format_number(req.input_tokens) %></td>
                  <td class="px-3 py-2 text-right text-green-600 font-mono"><%= format_number(req.output_tokens) %></td>
                  <td class="px-3 py-2 text-right font-mono font-medium"><%= format_number((req.input_tokens || 0) + (req.output_tokens || 0)) %></td>
                  <td class="px-3 py-2 text-right"><%= if req.tool_calls_count > 0, do: req.tool_calls_count, else: "-" %></td>
                  <td class="px-3 py-2 text-right text-gray-500 font-mono"><%= req.elapsed_ms %></td>
                </tr>
              <% end %>
            </tbody>
          </table>
          <div :if={@requests == []} class="text-center text-gray-400 py-8">No requests yet</div>
        </div>
      </div>
    </div>
    """
  end
end
```

- [ ] **Step 2: Add route**

In `v3/apps/druzhok_web/lib/druzhok_web_web/router.ex`, add inside the protected scope (after line 34, before `end`):

```elixir
    live "/usage", UsageLive
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix compile`
Expected: compiles with no errors

- [ ] **Step 4: Commit**

```
git add v3/apps/druzhok_web/lib/druzhok_web_web/live/usage_live.ex v3/apps/druzhok_web/lib/druzhok_web_web/router.ex
git commit -m "add token usage dashboard page at /usage"
```

---

### Task 8: Manual integration test

- [ ] **Step 1: Start the server**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v3 && mix ecto.migrate && mix phx.server`

- [ ] **Step 2: Send a message to trigger LLM call**

Send a message to the bot via Telegram. After the response:
- Check the database: `mix run -e "IO.inspect Druzhok.LlmRequest.recent(5)"`
- Verify `input_tokens` and `output_tokens` are non-zero
- Verify `model` and `instance_name` are populated

- [ ] **Step 3: Check the dashboard**

Open `http://localhost:4000/usage` in a browser. Verify:
- Summary cards show today's token usage
- Request log table shows the request with token counts
- Instance filter works

- [ ] **Step 4: Final commit if any cleanup needed**

```
git add -A
git commit -m "token usage tracking integration cleanup"
```
