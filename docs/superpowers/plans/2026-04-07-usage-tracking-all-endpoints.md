# Usage Tracking for All Proxy Endpoints — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track token/duration usage and enforce budgets for image, audio, and embedding proxy endpoints — not just chat completions.

**Architecture:** Extend `usage_logs` table with `request_type` and `audio_duration_ms`. Add `resolve_instance` helper to identify instances from auth headers on unauthenticated endpoints. Add `meter()` calls to all three new endpoints. Add budget checks to image and audio.

**Tech Stack:** Elixir, Phoenix, Ecto, SQLite

**Spec:** `docs/superpowers/specs/2026-04-07-usage-tracking-all-endpoints-design.md`

---

### Task 1: Migration — Add columns to usage_logs

**Files:**
- Create: `v4/druzhok/apps/druzhok/priv/repo/migrations/20260407000001_add_request_type_to_usage_logs.exs`
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/usage.ex`

- [ ] **Step 1: Create migration**

```elixir
defmodule Druzhok.Repo.Migrations.AddRequestTypeToUsageLogs do
  use Ecto.Migration

  def change do
    alter table(:usage_logs) do
      add :request_type, :string, default: "chat"
      add :audio_duration_ms, :integer
    end
  end
end
```

- [ ] **Step 2: Add fields to Usage schema**

In `v4/druzhok/apps/druzhok/lib/druzhok/usage.ex`, add to the schema (after `request_body`):

```elixir
    field :request_type, :string, default: "chat"
    field :audio_duration_ms, :integer
```

And add `:request_type, :audio_duration_ms` to the cast list in `changeset/2`.

- [ ] **Step 3: Run migration and verify**

Run: `cd v4/druzhok && DATABASE_PATH=data/druzhok.db mix ecto.migrate`

- [ ] **Step 4: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `add request_type and audio_duration_ms to usage_logs`

---

### Task 2: PoolConfig — Add auth to audio config

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/pool_config.ex:83-94`

- [ ] **Step 1: Add request.auth block to audio config**

In `pool_config.ex`, the audio config (around line 86-93) currently has no `request` block. Add it matching the image pattern. Change:

```elixir
        "audio" => %{
          "enabled" => true,
          "echoTranscript" => true,
          "models" => [%{
            "provider" => "openai",
            "model" => audio_model,
            "baseUrl" => proxy_url
          }]
        },
```

to:

```elixir
        "audio" => %{
          "enabled" => true,
          "echoTranscript" => true,
          "models" => [%{
            "provider" => "openai",
            "model" => audio_model,
            "baseUrl" => proxy_url
          }],
          "request" => %{
            "auth" => %{"mode" => "authorization-bearer", "token" => first_tenant_key}
          }
        },
```

- [ ] **Step 2: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `PoolConfig: add tenant auth to audio config`

---

### Task 3: LlmProxyController — Shared resolve_instance helper

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex`

- [ ] **Step 1: Add resolve_instance/1 private function**

Add near the bottom of the module (before `json_error`). This replaces `resolve_image_model/1` with a more general helper that returns the full instance:

```elixir
  defp resolve_instance(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        Druzhok.Repo.get_by(Druzhok.Instance, tenant_key: token)
      _ -> nil
    end
  end
```

- [ ] **Step 2: Refactor resolve_image_model to use resolve_instance**

Replace the existing `resolve_image_model/1`:

```elixir
  defp resolve_image_model(conn) do
    case resolve_instance(conn) do
      nil -> @default_image_model
      instance -> instance.image_model || @default_image_model
    end
  end
```

- [ ] **Step 3: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `extract resolve_instance helper from resolve_image_model`

---

### Task 4: Meter image (responses_proxy)

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:203-328`

- [ ] **Step 1: Add budget check and instance resolution to responses_proxy**

In `responses_proxy/2` (line 203), after `image_model = resolve_image_model(conn)`, add instance resolution and budget check:

```elixir
    instance = resolve_instance(conn)

    if instance do
      case Budget.check(instance.id) do
        {:error, :exceeded} ->
          json_error(conn, 429, "Token budget exceeded", "insufficient_quota")
        {:ok, _} ->
          do_responses_proxy(conn, body, image_model, instance)
      end
    else
      do_responses_proxy(conn, body, image_model, nil)
    end
```

Extract the existing proxy logic into `do_responses_proxy/4`.

- [ ] **Step 2: Extract usage from streaming SSE in stream_responses_proxy**

In `stream_responses_proxy/3` (line 264), the SSE parsing loop (lines 285-291) currently only extracts text content. Add usage extraction alongside it. Change the reduce to accumulate both text and usage:

```elixir
        {text, usage} = raw_data
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "data: "))
        |> Enum.map(&String.trim_leading(&1, "data: "))
        |> Enum.reject(&(&1 == "[DONE]"))
        |> Enum.reduce({"", %{prompt_tokens: 0, completion_tokens: 0}}, fn json_str, {text_acc, usage_acc} ->
          case Jason.decode(json_str) do
            {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]} = chunk} when is_binary(content) ->
              new_usage = case chunk do
                %{"usage" => u} when is_map(u) -> LlmFormat.extract_usage(%{"usage" => u})
                _ -> usage_acc
              end
              {text_acc <> content, new_usage}
            {:ok, %{"usage" => u}} when is_map(u) ->
              {text_acc, LlmFormat.extract_usage(%{"usage" => u})}
            _ -> {text_acc, usage_acc}
          end
        end)
```

- [ ] **Step 3: Add meter call after streaming completes**

After the SSE events are sent (after the `for event <- events` block), add:

```elixir
        if instance do
          total = usage.prompt_tokens + usage.completion_tokens
          if total > 0 do
            latency = System.monotonic_time(:millisecond) - started_at
            Budget.deduct(instance.id, total)
            Usage.log(%{
              instance_id: instance.id,
              model: image_model,
              prompt_tokens: usage.prompt_tokens,
              completion_tokens: usage.completion_tokens,
              total_tokens: total,
              request_type: "image",
              requested_model: image_model,
              resolved_model: image_model,
              provider: "openrouter",
              latency_ms: latency
            })
          end
        end
```

Note: `instance`, `image_model`, and `started_at` need to be passed through to `stream_responses_proxy`. Update the function signature to `stream_responses_proxy(conn, request, model, instance, started_at)`.

- [ ] **Step 4: Handle non-streaming responses_proxy metering too**

In the non-streaming branch (`if chat_body["stream"]` else), after sending the response, add the same metering logic. Extract usage from the JSON response body:

```elixir
          decoded = Jason.decode!(trimmed)
          usage = LlmFormat.extract_usage(decoded)
          if instance do
            total = usage.prompt_tokens + usage.completion_tokens
            if total > 0 do
              latency = System.monotonic_time(:millisecond) - started_at
              Budget.deduct(instance.id, total)
              Usage.log(%{
                instance_id: instance.id,
                model: image_model,
                prompt_tokens: usage.prompt_tokens,
                completion_tokens: usage.completion_tokens,
                total_tokens: total,
                request_type: "image",
                requested_model: image_model,
                resolved_model: image_model,
                provider: "openrouter",
                latency_ms: latency
              })
            end
          end
```

- [ ] **Step 5: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `meter image usage in responses_proxy with budget enforcement`

---

### Task 5: Meter audio (audio_transcriptions)

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:132-168`

- [ ] **Step 1: Add instance resolution and budget check**

At the top of `audio_transcriptions/2`, after `openai_key` check, add:

```elixir
      instance = resolve_instance(conn)

      if instance do
        case Budget.check(instance.id) do
          {:error, :exceeded} ->
            json_error(conn, 429, "Token budget exceeded", "insufficient_quota")
          {:ok, _} ->
            do_audio_transcription(conn, openai_key, instance)
        end
      else
        do_audio_transcription(conn, openai_key, nil)
      end
```

Extract the existing transcription logic into `do_audio_transcription/3`.

- [ ] **Step 2: Extract duration from Whisper response and meter**

In the success branch (status == 200), parse the response for duration and log usage:

```elixir
          if status == 200 and instance do
            duration_ms = case Jason.decode(resp_body) do
              {:ok, %{"duration" => d}} when is_number(d) -> round(d * 1000)
              _ -> nil
            end
            tokens_per_second = String.to_integer(get_setting("audio_tokens_per_second") || "10")
            equivalent_tokens = if duration_ms, do: div(duration_ms, 1000) * tokens_per_second, else: 0

            if equivalent_tokens > 0, do: Budget.deduct(instance.id, equivalent_tokens)

            Usage.log(%{
              instance_id: instance.id,
              model: "whisper",
              prompt_tokens: 0,
              completion_tokens: 0,
              total_tokens: equivalent_tokens,
              request_type: "audio",
              audio_duration_ms: duration_ms,
              requested_model: conn.body_params["model"] || "whisper-1",
              resolved_model: "whisper-1",
              provider: "openai",
              latency_ms: latency
            })
          end
```

- [ ] **Step 3: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `meter audio usage with duration tracking and budget enforcement`

---

### Task 6: Meter embeddings

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:184-200`

- [ ] **Step 1: Add metering to embeddings handler**

The embeddings handler already has `conn.assigns.instance` from the `llm_api` pipeline. After the successful response, extract usage and log. Change the success branch:

```elixir
      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        instance = conn.assigns.instance
        started_at_embed = System.monotonic_time(:millisecond)

        # Extract usage from embedding response
        case Jason.decode(resp_body) do
          {:ok, %{"usage" => %{"total_tokens" => total} = u}} when is_integer(total) and total > 0 ->
            Usage.log(%{
              instance_id: instance.id,
              model: body["model"] || "unknown",
              prompt_tokens: u["prompt_tokens"] || total,
              completion_tokens: 0,
              total_tokens: total,
              request_type: "embedding",
              requested_model: body["model"],
              resolved_model: body["model"],
              provider: "openrouter",
              latency_ms: System.monotonic_time(:millisecond) - started_at_embed
            })
          _ -> :ok
        end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, resp_body)
```

Note: No `Budget.check()` for embeddings — track only, never block.

- [ ] **Step 2: Move started_at to the top of the function**

Add `started_at = System.monotonic_time(:millisecond)` at the top of `embeddings/2` so latency is measured from request start, not after response.

- [ ] **Step 3: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `meter embedding usage (track only, no budget enforcement)`

---

### Task 7: Add request_type to existing chat metering

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/controllers/llm_proxy_controller.ex:92-130`

- [ ] **Step 1: Add request_type to meter() calls**

In the `meter/6` function (line 92), add `request_type: "chat"` to the `Usage.log()` call:

```elixir
      Usage.log(%{
        instance_id: instance.id,
        model: model,
        prompt_tokens: usage.prompt_tokens,
        completion_tokens: usage.completion_tokens,
        total_tokens: total,
        request_type: "chat",
        requested_model: model,
        resolved_model: model,
        provider: "openrouter",
        latency_ms: latency,
        prompt_preview: prompt_preview,
        response_preview: resp_preview,
        request_body: Jason.encode!(request_body),
      })
```

- [ ] **Step 2: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `add request_type to chat completions meter`

---

### Task 8: Settings — audio_tokens_per_second

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Add audio_tokens_per_second to SettingsLive mount**

In `mount/3`, add to the assigns:

```elixir
        audio_tokens_per_second: Druzhok.Settings.get("audio_tokens_per_second") || "10",
```

- [ ] **Step 2: Add to the save handler**

In `handle_event("save", ...)`, add `"audio_tokens_per_second"` to the simple key loop:

```elixir
    for key <- ["system_prompt_budget_ratio", "tool_definitions_budget_ratio",
                "history_budget_ratio", "tool_result_budget_ratio",
                "response_reserve_ratio", "default_context_window",
                "token_estimation_divisor", "embedding_api_url", "embedding_model",
                "compaction_api_url", "compaction_model", "audio_tokens_per_second"] do
```

And add to the re-assign block:

```elixir
      audio_tokens_per_second: Druzhok.Settings.get("audio_tokens_per_second") || "10",
```

- [ ] **Step 3: Add UI field in template**

Add a new section in the template after the Voice Transcription section:

```heex
          <div class="bg-white rounded-xl border border-gray-200 p-6">
            <h2 class="text-sm font-semibold mb-4">Audio Budget</h2>
            <p class="text-xs text-gray-500 mb-4">Tokens charged per second of audio for budget accounting. Adjust based on your Whisper pricing.</p>
            <div>
              <label class="block text-xs text-gray-500 mb-1">Tokens per Second</label>
              <input name="audio_tokens_per_second" value={@audio_tokens_per_second}
                     class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
            </div>
          </div>
```

- [ ] **Step 4: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `add audio_tokens_per_second setting`

---

### Task 9: Dashboard — Request type in usage tab

**Files:**
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex:1187-1205`
- Modify: `v4/druzhok/apps/druzhok_web/lib/druzhok_web_web/live/components/usage_tab.ex`

- [ ] **Step 1: Pass request_type through load_usage_data**

In `load_usage_data/1` (dashboard_live.ex:1187), add `request_type` and `audio_duration_ms` to the request map:

```elixir
      %{
        id: r.id,
        inserted_at: r.inserted_at,
        model: r.model,
        input_tokens: r.prompt_tokens || 0,
        output_tokens: r.completion_tokens || 0,
        tool_calls_count: 0,
        elapsed_ms: r.latency_ms,
        prompt_preview: r.prompt_preview,
        response_preview: r.response_preview,
        request_body: r.request_body,
        request_type: r.request_type || "chat",
        audio_duration_ms: r.audio_duration_ms
      }
```

- [ ] **Step 2: Add type badge to usage_tab request rows**

In `usage_tab.ex`, in the request row `<tr>` (line 72), add a Type column after Time:

Add to the header:
```heex
              <th class="px-3 py-2">Type</th>
```

Add to the row:
```heex
                <td class="px-3 py-2">
                  <span class={"inline-block px-1.5 py-0.5 rounded text-[10px] font-medium #{type_badge_class(req.request_type)}"}>
                    <%= req.request_type %>
                  </span>
                </td>
```

Add helper:
```elixir
  defp type_badge_class("chat"), do: "bg-blue-100 text-blue-700"
  defp type_badge_class("image"), do: "bg-purple-100 text-purple-700"
  defp type_badge_class("audio"), do: "bg-amber-100 text-amber-700"
  defp type_badge_class("embedding"), do: "bg-gray-100 text-gray-600"
  defp type_badge_class(_), do: "bg-gray-100 text-gray-600"
```

- [ ] **Step 3: Show audio duration for audio rows**

In the Input column, show duration instead of token count for audio:

```heex
                <td class="px-3 py-2 text-right text-blue-600 font-mono">
                  <%= if req.request_type == "audio" and req.audio_duration_ms do %>
                    <%= format_duration(req.audio_duration_ms) %>
                  <% else %>
                    <%= format_number(req.input_tokens) %>
                  <% end %>
                </td>
```

Add helper:
```elixir
  defp format_duration(ms) when ms >= 60_000, do: "#{Float.round(ms / 60_000, 1)}m"
  defp format_duration(ms) when ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)}s"
  defp format_duration(ms), do: "#{ms}ms"
```

- [ ] **Step 4: Update colspan in expanded row**

Change `colspan="7"` to `colspan="8"` in the expanded request detail row (line 83).

- [ ] **Step 5: Compile and commit**

Run: `cd v4/druzhok && mix compile`
Message: `dashboard: show request type and audio duration in usage tab`

---

### Task 10: Deploy and verify

- [ ] **Step 1: Push and deploy**

```bash
git push
ssh -l igor 158.160.78.230
cd ~/druzhok && git pull
source ~/.bashrc; . ~/.asdf/asdf.sh
cd v4/druzhok && mix compile
DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix ecto.migrate
sudo systemctl restart druzhok
```

- [ ] **Step 2: Restart pool to pick up new audio auth config**

```bash
docker rm -f druzhok-pool-1
# Wait for auto-restart, then verify config:
docker exec druzhok-pool-1 cat /data/openclaw.json | python3 -c "import sys,json; c=json.load(sys.stdin); print(json.dumps(c['tools']['media']['audio'], indent=2))"
```

Verify the audio config now has `request.auth` with the tenant token.

- [ ] **Step 3: Test chat metering (existing)**

Send a text message to the bot. Check dashboard Usage tab — should show a row with type "chat".

- [ ] **Step 4: Test image metering**

Send an image to the bot. Check dashboard Usage tab — should show a row with type "image" and token counts.

- [ ] **Step 5: Test audio metering**

Send a voice message to the bot. Check dashboard Usage tab — should show a row with type "audio" and duration displayed.

- [ ] **Step 6: Test embedding metering**

Trigger memory search (ask the bot to recall something). Check dashboard — should show a row with type "embedding".
