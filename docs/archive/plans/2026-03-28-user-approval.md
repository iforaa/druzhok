# User Approval System Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow bot owners to approve Telegram users from the dashboard by pasting the user ID the bot shows them.

**Architecture:** Add `read_allowed_users/1`, `add_allowed_user/2`, `remove_allowed_user/2` callbacks to Runtime behaviour. ZeroClaw reads/writes `.zeroclaw/config.toml` on disk. PicoClaw restarts container with updated env. Dashboard gets a Security subsection in the Settings tab.

**Tech Stack:** Elixir, Phoenix LiveView, TOML parsing (simple regex — no library needed for this narrow use case)

---

## File Structure

```
Modify: apps/druzhok/lib/druzhok/runtime.ex                    — add 3 new callbacks
Modify: apps/druzhok/lib/druzhok/runtime/zero_claw.ex          — TOML read/write for allowed_users
Modify: apps/druzhok/lib/druzhok/runtime/pico_claw.ex          — restart-based approach
Modify: apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex — Security subsection in Settings
```

---

### Task 1: Add Callbacks to Runtime Behaviour

**Files:**
- Modify: `apps/druzhok/lib/druzhok/runtime.ex`

- [ ] **Step 1: Add 3 new callbacks to the behaviour**

In `apps/druzhok/lib/druzhok/runtime.ex`, add after line 15 (`@callback supports_feature?(atom()) :: boolean()`):

```elixir
  @callback read_allowed_users(data_root :: String.t()) :: [String.t()]
  @callback add_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
  @callback remove_allowed_user(data_root :: String.t(), user_id :: String.t()) :: :ok | {:error, term()}
```

- [ ] **Step 2: Add a helper to parse user input**

Add at the end of the module, before the closing `end`:

```elixir
  @doc """
  Parse user input from the dashboard. Accepts:
  - Raw ID: "281775258"
  - Full command: "zeroclaw channel bind-telegram 281775258"
  - With @: "@username"
  """
  def parse_user_input(input) do
    trimmed = String.trim(input)
    cond do
      # Full bind command — extract the last token
      String.contains?(trimmed, "bind-telegram") ->
        trimmed |> String.split() |> List.last()
      # Raw number or @username
      true ->
        trimmed
    end
  end
```

- [ ] **Step 3: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors (warnings about unimplemented callbacks in adapters are expected)

- [ ] **Step 4: Commit**

```
feat: add user approval callbacks to Runtime behaviour
```

---

### Task 2: Implement ZeroClaw Adapter

**Files:**
- Modify: `apps/druzhok/lib/druzhok/runtime/zero_claw.ex`

- [ ] **Step 1: Add read_allowed_users/1**

Add after the `workspace_files/1` function (after line 43):

```elixir
  @impl true
  def read_allowed_users(data_root) do
    config_path = Path.join([data_root, ".zeroclaw", "config.toml"])
    case File.read(config_path) do
      {:ok, content} -> parse_allowed_users(content)
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    config_path = Path.join([data_root, ".zeroclaw", "config.toml"])
    case File.read(config_path) do
      {:ok, content} ->
        current = parse_allowed_users(content)
        if user_id in current do
          :ok
        else
          updated = current ++ [user_id]
          new_content = replace_allowed_users(content, updated)
          File.write!(config_path, new_content)
          :ok
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    config_path = Path.join([data_root, ".zeroclaw", "config.toml"])
    case File.read(config_path) do
      {:ok, content} ->
        current = parse_allowed_users(content)
        updated = Enum.reject(current, &(&1 == user_id))
        new_content = replace_allowed_users(content, updated)
        File.write!(config_path, new_content)
        :ok
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_allowed_users(toml_content) do
    case Regex.run(~r/allowed_users\s*=\s*\[(.*?)\]/s, toml_content) do
      [_, inner] ->
        Regex.scan(~r/"([^"]*)"/, inner)
        |> Enum.map(fn [_, id] -> id end)
        |> Enum.reject(&(&1 == ""))
      nil -> []
    end
  end

  defp replace_allowed_users(toml_content, users) do
    users_str = Enum.map_join(users, ", ", &"\"#{&1}\"")
    Regex.replace(
      ~r/allowed_users\s*=\s*\[.*?\]/s,
      toml_content,
      "allowed_users = [#{users_str}]"
    )
  end
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 3: Commit**

```
feat: ZeroClaw adapter reads/writes allowed_users from config.toml
```

---

### Task 3: Implement PicoClaw Adapter

**Files:**
- Modify: `apps/druzhok/lib/druzhok/runtime/pico_claw.ex`

- [ ] **Step 1: Add the three callbacks**

PicoClaw uses env vars, not config files. Reading allowed users requires checking what was last set. Store the list in a JSON file in the data root for persistence.

Add after `workspace_files/1` (after line 27):

```elixir
  @impl true
  def read_allowed_users(data_root) do
    path = Path.join(data_root, ".allowed_users.json")
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, list} when is_list(list) -> list
          _ -> []
        end
      {:error, _} -> []
    end
  end

  @impl true
  def add_allowed_user(data_root, user_id) do
    current = read_allowed_users(data_root)
    if user_id in current do
      :ok
    else
      updated = current ++ [user_id]
      File.write!(Path.join(data_root, ".allowed_users.json"), Jason.encode!(updated))
      :ok
    end
  end

  @impl true
  def remove_allowed_user(data_root, user_id) do
    current = read_allowed_users(data_root)
    updated = Enum.reject(current, &(&1 == user_id))
    File.write!(Path.join(data_root, ".allowed_users.json"), Jason.encode!(updated))
    :ok
  end
```

Also update `env_vars/1` to read allowed users from the JSON file instead of relying on the instance map:

Change line 15 from:
```elixir
      allowed = Map.get(instance, :allowed_users, []) || []
```
To:
```elixir
      data_root = Map.get(instance, :workspace, "") |> Path.dirname()
      allowed = read_allowed_users(data_root)
```

- [ ] **Step 2: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 3: Commit**

```
feat: PicoClaw adapter reads/writes allowed_users from JSON file
```

---

### Task 4: Dashboard Security Subsection

**Files:**
- Modify: `apps/druzhok_web/lib/druzhok_web_web/live/dashboard_live.ex`

- [ ] **Step 1: Add `allowed_users` to socket assigns**

In `mount/3`, add to the assigns (around line 32):

```elixir
      allowed_users: [],
```

- [ ] **Step 2: Load allowed_users when instance is selected**

In `handle_params(%{"name" => name}, ...)`, after the existing assigns (around line 73), add:

```elixir
          allowed_users: load_allowed_users(name),
```

- [ ] **Step 3: Add the load helper**

Add a private function:

```elixir
  defp load_allowed_users(name) do
    inst = Druzhok.Repo.get_by(Druzhok.Instance, name: name)
    if inst && inst.workspace do
      runtime = Druzhok.Runtime.get(inst.bot_runtime || "zeroclaw", Druzhok.Runtime.ZeroClaw)
      data_root = Path.dirname(inst.workspace)
      runtime.read_allowed_users(data_root)
    else
      []
    end
  end
```

- [ ] **Step 4: Add event handlers for approve and remove**

```elixir
  def handle_event("approve_user", %{"user_input" => input}, socket) do
    user_id = Druzhok.Runtime.parse_user_input(input)
    if user_id != "" and socket.assigns.selected do
      inst = Druzhok.Repo.get_by(Druzhok.Instance, name: socket.assigns.selected)
      if inst && inst.workspace do
        runtime = Druzhok.Runtime.get(inst.bot_runtime || "zeroclaw", Druzhok.Runtime.ZeroClaw)
        data_root = Path.dirname(inst.workspace)
        runtime.add_allowed_user(data_root, user_id)
        {:noreply, assign(socket, allowed_users: load_allowed_users(socket.assigns.selected))}
      else
        {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, "Invalid user ID")}
    end
  end

  def handle_event("remove_user", %{"user_id" => user_id}, socket) do
    if socket.assigns.selected do
      inst = Druzhok.Repo.get_by(Druzhok.Instance, name: socket.assigns.selected)
      if inst && inst.workspace do
        runtime = Druzhok.Runtime.get(inst.bot_runtime || "zeroclaw", Druzhok.Runtime.ZeroClaw)
        data_root = Path.dirname(inst.workspace)
        runtime.remove_allowed_user(data_root, user_id)
        {:noreply, assign(socket, allowed_users: load_allowed_users(socket.assigns.selected))}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end
```

- [ ] **Step 5: Add Security subsection to Settings tab HTML**

In the Settings tab content, after the Telegram Token section (after line 593), add:

```heex
              <hr class="border-gray-200" />

              <%!-- Security --%>
              <div>
                <h3 class="text-sm font-medium text-gray-700 mb-3">Approved Telegram Users</h3>
                <div :if={@allowed_users == []} class="text-xs text-gray-400 mb-3">
                  No users approved yet. When someone messages the bot, it will show them an ID to paste here.
                </div>
                <div :if={@allowed_users != []} class="space-y-1 mb-3">
                  <div :for={user_id <- @allowed_users} class="flex items-center justify-between bg-gray-50 rounded-lg px-3 py-2">
                    <code class="text-sm font-mono"><%= user_id %></code>
                    <button phx-click="remove_user" phx-value-user_id={user_id}
                            class="text-xs text-red-500 hover:text-red-700 transition">Remove</button>
                  </div>
                </div>
                <form phx-submit="approve_user" class="flex gap-2">
                  <input name="user_input" placeholder="Paste user ID or bind command"
                         class="flex-1 border border-gray-300 rounded-lg px-3 py-2 text-sm" />
                  <button type="submit" class="px-3 py-2 bg-gray-900 text-white rounded-lg text-sm">Approve</button>
                </form>
                <p class="text-xs text-gray-400 mt-1">Paste the number from the bot's approval message</p>
              </div>
```

- [ ] **Step 6: Verify compilation**

Run: `cd /Users/igorkuznetsov/Documents/druzhok/v4/druzhok && mix compile 2>&1 | grep error`
Expected: No errors

- [ ] **Step 7: Verify end-to-end**

1. Open dashboard, select igor instance, go to Settings tab
2. You should see the Security section with "281775258" in the approved list (from our manual edit earlier)
3. Try removing and re-adding the user
4. Check that `.zeroclaw/config.toml` updates on disk

- [ ] **Step 8: Commit**

```
feat: user approval UI in dashboard Settings tab
```

---

### Task 5: Commit Docs

- [ ] **Step 1: Commit spec and plan**

```bash
cd /Users/igorkuznetsov/Documents/druzhok
git add docs/superpowers/specs/2026-03-28-user-approval-design.md docs/superpowers/plans/2026-03-28-user-approval.md
git commit -m "docs: user approval design spec and plan"
```
