# Image Generation Tool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `generate_image` tool that the LLM can call to generate images via OpenRouter's Gemini Flash Image, sending the result to the user as an inline Telegram photo.

**Architecture:** New `PiCore.Tools.GenerateImage` tool calls OpenRouter with an image-capable model. Response contains base64 image in `images[]` array. Tool decodes, saves temp file, sends via new `send_photo_fn` (for inline preview). Tool is conditionally registered based on a dashboard toggle (`image_generation_enabled`).

**Tech Stack:** Elixir, Finch, OpenRouter API, Telegram Bot API (sendPhoto)

**Spec:** `docs/superpowers/specs/2026-03-24-openrouter-multimodal-design.md` (Spec 3 section)

---

## File Structure

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `v3/apps/druzhok/lib/druzhok/telegram/api.ex` | Add `send_photo/4` |
| Modify | `v3/apps/druzhok/lib/druzhok/instance/sup.ex` | Add `send_photo_fn` to extra_tool_context |
| Create | `v3/apps/pi_core/lib/pi_core/tools/generate_image.ex` | Image generation tool |
| Create | `v3/apps/pi_core/test/pi_core/tools/generate_image_test.exs` | Unit tests |
| Modify | `v3/apps/pi_core/lib/pi_core/session.ex:50` | Conditional tool registration |
| Modify | `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex` | Dashboard toggle |

---

### Task 1: Add send_photo to Telegram API

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/telegram/api.ex`

- [ ] **Step 1: Add send_photo function**

In `v3/apps/druzhok/lib/druzhok/telegram/api.ex`, after `send_document/4` (after line 44), add:

```elixir
def send_photo(token, chat_id, photo_bytes, opts \\ %{}) do
  boundary = "----ElixirBoundary#{:rand.uniform(1_000_000)}"
  caption = opts[:caption]

  parts = [
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n#{chat_id}\r\n",
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"image.png\"\r\nContent-Type: image/png\r\n\r\n"
  ]

  # Build body with binary content (can't use string interpolation for binary)
  body = IO.iodata_to_binary([
    Enum.join(parts),
    photo_bytes,
    "\r\n",
    if(caption, do: "--#{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n#{caption}\r\n", else: ""),
    "--#{boundary}--\r\n"
  ])

  headers = [{"content-type", "multipart/form-data; boundary=#{boundary}"}]
  url = "#{@base_url}#{token}/sendPhoto"

  case Finch.build(:post, url, headers, body) |> Finch.request(PiCore.Finch) do
    {:ok, %{status: 200, body: resp}} -> {:ok, Jason.decode!(resp)}
    {:ok, %{body: resp}} -> {:error, resp}
    {:error, reason} -> {:error, reason}
  end
end
```

- [ ] **Step 2: Verify compilation**

Run (from `v3/` directory): `mix compile`

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/druzhok/lib/druzhok/telegram/api.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add send_photo to Telegram API"
```

---

### Task 2: Add send_photo_fn to instance context

**Files:**
- Modify: `v3/apps/druzhok/lib/druzhok/instance/sup.ex`

- [ ] **Step 1: Add send_photo_fn alongside send_file_fn**

In `v3/apps/druzhok/lib/druzhok/instance/sup.ex`, after the `send_file_fn` definition (after line 47), add:

```elixir
send_photo_fn = fn photo_bytes, caption ->
  case Registry.lookup(Druzhok.Registry, {name, :telegram}) do
    [{pid, _}] ->
      chat_id = GenServer.call(pid, :get_chat_id, 5_000)
      if chat_id do
        Druzhok.Telegram.API.send_photo(config.token, chat_id, photo_bytes, %{caption: caption})
      else
        {:error, "No active chat"}
      end
    [] -> {:error, "Telegram not available"}
  end
end
```

Then add it to the `extra_tool_context` map (after `send_file_fn:` on line 73):

```elixir
send_photo_fn: send_photo_fn,
```

- [ ] **Step 2: Verify compilation**

Run (from `v3/` directory): `mix compile`

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/druzhok/lib/druzhok/instance/sup.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add send_photo_fn to instance tool context"
```

---

### Task 3: Implement GenerateImage tool

**Files:**
- Create: `v3/apps/pi_core/lib/pi_core/tools/generate_image.ex`
- Create: `v3/apps/pi_core/test/pi_core/tools/generate_image_test.exs`

- [ ] **Step 1: Write failing test**

Create `v3/apps/pi_core/test/pi_core/tools/generate_image_test.exs`:

```elixir
defmodule PiCore.Tools.GenerateImageTest do
  use ExUnit.Case

  alias PiCore.Tools.GenerateImage

  test "new/1 creates a tool with correct name and parameters" do
    tool = GenerateImage.new()
    assert tool.name == "generate_image"
    assert Map.has_key?(tool.parameters, :prompt)
  end

  test "execute calls LLM and sends photo on success" do
    # Fake 1x1 white PNG (valid PNG header + minimal data)
    fake_b64 = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

    mock_llm = fn _opts ->
      {:ok, %{
        "choices" => [%{
          "message" => %{
            "content" => "Here is your image",
            "images" => [%{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/png;base64,#{fake_b64}"}
            }]
          }
        }]
      }}
    end

    sent = :ets.new(:test_sent, [:set, :public])
    mock_send_photo = fn bytes, caption ->
      :ets.insert(sent, {:called, bytes, caption})
      :ok
    end

    tool = GenerateImage.new(llm_fn: mock_llm)
    context = %{send_photo_fn: mock_send_photo, workspace: System.tmp_dir!(), chat_id: 123}
    {:ok, result} = tool.execute.(%{"prompt" => "a cat in space"}, context)
    assert result =~ "sent"

    [{:called, bytes, _caption}] = :ets.lookup(sent, :called)
    assert is_binary(bytes)
    :ets.delete(sent)
  end

  test "execute returns error when no send_photo_fn" do
    tool = GenerateImage.new()
    context = %{workspace: System.tmp_dir!()}
    {:error, msg} = tool.execute.(%{"prompt" => "test"}, context)
    assert msg =~ "not available"
  end

  test "execute returns error when LLM fails" do
    mock_llm = fn _opts -> {:error, "API error"} end

    tool = GenerateImage.new(llm_fn: mock_llm)
    context = %{send_photo_fn: fn _, _ -> :ok end, workspace: System.tmp_dir!(), chat_id: 123}
    {:error, msg} = tool.execute.(%{"prompt" => "test"}, context)
    assert msg =~ "failed" or msg =~ "error"
  end

  test "execute returns error when no images in response" do
    mock_llm = fn _opts ->
      {:ok, %{
        "choices" => [%{
          "message" => %{"content" => "I can't generate images", "images" => []}
        }]
      }}
    end

    tool = GenerateImage.new(llm_fn: mock_llm)
    context = %{send_photo_fn: fn _, _ -> :ok end, workspace: System.tmp_dir!(), chat_id: 123}
    {:error, msg} = tool.execute.(%{"prompt" => "test"}, context)
    assert msg =~ "No image"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `v3/` directory): `mix test apps/pi_core/test/pi_core/tools/generate_image_test.exs`

Expected: FAIL — module doesn't exist.

- [ ] **Step 3: Implement the tool**

Create `v3/apps/pi_core/lib/pi_core/tools/generate_image.ex`:

```elixir
defmodule PiCore.Tools.GenerateImage do
  alias PiCore.Tools.Tool

  @default_model "google/gemini-2.5-flash-image"

  def new(opts \\ []) do
    %Tool{
      name: "generate_image",
      description: "Generate an image from a text description. The image will be sent to the user in the chat.",
      parameters: %{
        prompt: %{type: :string, description: "Description of the image to generate"}
      },
      execute: fn args, context -> execute(args, context, opts) end
    }
  end

  def execute(%{"prompt" => prompt}, context, opts) do
    send_photo_fn = context[:send_photo_fn]

    unless send_photo_fn do
      {:error, "Image sending not available"}
    else
      llm_fn = Keyword.get(opts, :llm_fn) || build_default_llm_fn(opts)

      request = %{
        model: Keyword.get(opts, :model) || Druzhok.Settings.get("image_generation_model") || @default_model,
        provider: :openrouter,
        api_url: Keyword.get(opts, :api_url) || Druzhok.Settings.api_url("openrouter"),
        api_key: Keyword.get(opts, :api_key) || Druzhok.Settings.api_key("openrouter"),
        system_prompt: "You are an image generator. Generate the requested image.",
        messages: [%{role: "user", content: prompt}],
        tools: [],
        max_tokens: 4096,
        stream: false,
        on_delta: nil,
        on_event: nil
      }

      case llm_fn.(request) do
        {:ok, response} ->
          extract_and_send_image(response, send_photo_fn)

        {:error, reason} ->
          {:error, "Image generation failed: #{inspect(reason)}"}
      end
    end
  end

  def execute(_, _, _), do: {:error, "Missing required parameter: prompt"}

  defp extract_and_send_image(response, send_photo_fn) do
    images = get_in(response, ["choices", Access.at(0), "message", "images"]) || []

    case images do
      [%{"image_url" => %{"url" => data_url}} | _] ->
        case decode_data_url(data_url) do
          {:ok, bytes} ->
            case send_photo_fn.(bytes, nil) do
              :ok -> {:ok, "Image generated and sent"}
              {:ok, _} -> {:ok, "Image generated and sent"}
              {:error, reason} -> {:error, "Failed to send image: #{inspect(reason)}"}
            end

          {:error, reason} ->
            {:error, "Failed to decode image: #{reason}"}
        end

      _ ->
        {:error, "No image in response"}
    end
  end

  defp decode_data_url("data:" <> rest) do
    case String.split(rest, ",", parts: 2) do
      [_header, base64_data] ->
        case Base.decode64(base64_data) do
          {:ok, bytes} -> {:ok, bytes}
          :error -> {:error, "Invalid base64"}
        end
      _ -> {:error, "Invalid data URL format"}
    end
  end
  defp decode_data_url(_), do: {:error, "Not a data URL"}

  defp build_default_llm_fn(_opts) do
    fn request ->
      # Use sync (non-streaming) completion and return raw response
      url = "#{String.trim_trailing(request.api_url, "/")}/chat/completions"
      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{request.api_key}"},
        {"HTTP-Referer", "https://druzhok.app"},
        {"X-Title", "Druzhok"}
      ]
      body = Jason.encode!(%{
        model: request.model,
        messages: [
          %{role: "system", content: request.system_prompt}
          | request.messages
        ],
        max_tokens: request.max_tokens
      })

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PiCore.Finch, receive_timeout: 60_000) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          {:ok, Jason.decode!(resp)}
        {:ok, %{status: status, body: resp}} ->
          {:error, "HTTP #{status}: #{String.slice(resp, 0, 200)}"}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
```

**Key design notes:**
- Uses raw Finch HTTP instead of `PiCore.LLM.OpenAI.completion/1` because the response format is different (has `images[]` array, not just `content`)
- `llm_fn` is injectable for testing
- `send_photo_fn` comes from context (wired in instance sup)
- Settings fallback: reads model from `image_generation_model` setting
- 60s timeout for image generation (can be slow)

- [ ] **Step 4: Run tests**

Run (from `v3/` directory): `mix test apps/pi_core/test/pi_core/tools/generate_image_test.exs`

Expected: All 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/pi_core/lib/pi_core/tools/generate_image.ex v3/apps/pi_core/test/pi_core/tools/generate_image_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add generate_image tool"
```

---

### Task 4: Conditional tool registration + dashboard toggle

**Files:**
- Modify: `v3/apps/pi_core/lib/pi_core/session.ex:50`
- Modify: `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`

- [ ] **Step 1: Modify session init to conditionally add generate_image**

In `v3/apps/pi_core/lib/pi_core/session.ex`, find line 50:

```elixir
tools = opts[:tools] || default_tools()
```

Replace with:

```elixir
tools = opts[:tools] || build_tools(opts)
```

Then add a new private function (near `default_tools/0`):

```elixir
defp build_tools(opts) do
  tools = default_tools()
  ctx = opts[:extra_tool_context] || %{}

  # Conditionally add image generation
  image_gen_enabled = ctx[:image_generation_enabled] ||
    (fn -> Druzhok.Settings.get("image_generation_enabled") == "true" end).()

  if image_gen_enabled do
    tools ++ [PiCore.Tools.GenerateImage.new()]
  else
    tools
  end
end
```

- [ ] **Step 2: Add dashboard settings**

In `v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex`:

**Mount assigns** — add:
```elixir
image_generation_enabled: Druzhok.Settings.get("image_generation_enabled") || "false",
image_generation_model: Druzhok.Settings.get("image_generation_model") || "google/gemini-2.5-flash-image",
```

**Save handler** — add:
```elixir
if val = non_empty(params["image_generation_enabled"]) do
  Druzhok.Settings.set("image_generation_enabled", val)
end
if val = non_empty(params["image_generation_model"]) do
  Druzhok.Settings.set("image_generation_model", val)
end
```

**Re-assign after save** — add:
```elixir
image_generation_enabled: Druzhok.Settings.get("image_generation_enabled") || "false",
image_generation_model: Druzhok.Settings.get("image_generation_model") || "google/gemini-2.5-flash-image",
```

**Template** — add after the Voice Transcription section:
```heex
<div class="bg-white rounded-xl border border-gray-200 p-6">
  <h2 class="text-sm font-semibold mb-4">Image Generation</h2>
  <p class="text-xs text-gray-500 mb-4">Allows the bot to generate images. Requires OpenRouter API key. Off by default.</p>
  <div class="space-y-3">
    <div>
      <label class="block text-xs text-gray-500 mb-1">Enabled</label>
      <select name="image_generation_enabled"
              class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm focus:outline-none focus:ring-1 focus:ring-gray-900">
        <option value="false" selected={@image_generation_enabled != "true"}>No</option>
        <option value="true" selected={@image_generation_enabled == "true"}>Yes</option>
      </select>
    </div>
    <div>
      <label class="block text-xs text-gray-500 mb-1">Model</label>
      <input name="image_generation_model" value={@image_generation_model}
             class="w-full border border-gray-300 rounded-lg px-3 py-2 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-gray-900" />
    </div>
  </div>
</div>
```

- [ ] **Step 3: Verify compilation**

Run (from `v3/` directory): `mix compile`

- [ ] **Step 4: Run full test suite**

Run (from `v3/` directory): `mix test`

Expected: All tests pass, no regressions.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v3/apps/pi_core/lib/pi_core/session.ex v3/apps/druzhok_web/lib/druzhok_web_web/live/settings_live.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "add conditional image generation registration and dashboard toggle"
```
