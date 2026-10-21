# Managed Bot Service Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Telegram manager bot GenServer inside druzhok that lets users create their own hermes AI bots via a 4-step inline-keyboard onboarding flow, auto-provisioning a Docker container on completion.

**Architecture:** A `Druzhok.ManagerBot` GenServer long-polls the Telegram Bot API using a dedicated manager token (stored in Settings). It runs a per-user state machine (name → personality → language → confirm) with inline keyboards, generates `t.me/newbot/...` deep links, handles `managed_bot` updates to trigger auto-provisioning via `BotManager.create`, and enforces a 2-bot-per-user limit.

**Tech Stack:** Elixir GenServer, `Druzhok.Telegram.API` (existing Finch-based client), Ecto/SQLite, hermes Docker containers.

**Spec:** `docs/superpowers/specs/2026-04-18-managed-bot-service-design.md`

---

## File Structure

**Create:**
- `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot.ex` — the GenServer: long-polling, state machine, onboarding flow, provisioning trigger.
- `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/onboarding.ex` — pure-function module: state transitions, message builders, keyboard builders. Keeps the GenServer thin.
- `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/provisioner.ex` — provisioning pipeline: getManagedBotToken → create instance → apply personality → auto-pair → send confirmation.
- `v4/druzhok/apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs` — unit tests for state machine + message generation.
- `v4/druzhok/apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs` — unit tests for provisioning logic.

**Modify:**
- `v4/druzhok/apps/druzhok/lib/druzhok/application.ex` — add `Druzhok.ManagerBot` to supervision tree.
- `v4/druzhok/apps/druzhok/lib/druzhok/telegram/api.ex` — add `answer_callback_query/2` and `get_managed_bot_token/2`.

---

## Task 1: Extend Telegram API client

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/telegram/api.ex`

Two new API methods needed by the manager bot.

- [ ] **Step 1: Add `answer_callback_query/2`**

In `v4/druzhok/apps/druzhok/lib/druzhok/telegram/api.ex`, before the `defp call` function, add:

```elixir
  def answer_callback_query(token, callback_query_id, opts \\ %{}) do
    call(token, "answerCallbackQuery", Map.merge(%{callback_query_id: callback_query_id}, opts))
  end
```

- [ ] **Step 2: Add `get_managed_bot_token/2`**

In the same file, add:

```elixir
  def get_managed_bot_token(token, bot_user_id) do
    call(token, "getManagedBotToken", %{user_id: bot_user_id})
  end
```

- [ ] **Step 3: Compile**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix compile
```

Expected: clean.

- [ ] **Step 4: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/telegram/api.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "telegram api: add answer_callback_query + get_managed_bot_token"
```

---

## Task 2: Onboarding module (pure functions, TDD)

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/onboarding.ex`
- Create: `v4/druzhok/apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs`

This module contains all the state-machine logic and message-building as pure functions — no GenServer, no side effects. Makes it easy to test.

- [ ] **Step 1: Write the test file**

Create `v4/druzhok/apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs`:

```elixir
defmodule Druzhok.ManagerBot.OnboardingTest do
  use ExUnit.Case, async: true

  alias Druzhok.ManagerBot.Onboarding

  describe "new_session/0" do
    test "starts at :name step" do
      session = Onboarding.new_session()
      assert session.step == :name
      assert session.name == nil
      assert session.personality == nil
      assert session.language == nil
    end
  end

  describe "handle_input/2 at :name step" do
    test "accepts a name and moves to :personality" do
      session = Onboarding.new_session()
      {:ok, session, _reply} = Onboarding.handle_input(session, %{text: "Вася"})
      assert session.step == :personality
      assert session.name == "Вася"
    end

    test "rejects empty name" do
      session = Onboarding.new_session()
      {:retry, _session, _reply} = Onboarding.handle_input(session, %{text: ""})
    end
  end

  describe "handle_input/2 at :personality step" do
    test "accepts a valid personality callback" do
      session = %{Onboarding.new_session() | step: :personality, name: "Вася"}
      {:ok, session, _reply} = Onboarding.handle_input(session, %{callback_data: "personality:kawaii"})
      assert session.step == :language
      assert session.personality == "kawaii"
    end

    test "rejects unknown personality" do
      session = %{Onboarding.new_session() | step: :personality, name: "Вася"}
      {:retry, _session, _reply} = Onboarding.handle_input(session, %{callback_data: "personality:nonexistent"})
    end
  end

  describe "handle_input/2 at :language step" do
    test "accepts language and moves to :confirm" do
      session = %{Onboarding.new_session() | step: :language, name: "Вася", personality: "kawaii"}
      {:ok, session, _reply} = Onboarding.handle_input(session, %{callback_data: "lang:ru"})
      assert session.step == :confirm
      assert session.language == "ru"
    end
  end

  describe "generate_bot_username/1" do
    test "transliterates cyrillic and appends suffix" do
      username = Onboarding.generate_bot_username("Вася")
      assert username =~ ~r/^vasya_[a-f0-9]{4}_bot$/
    end

    test "handles latin input" do
      username = Onboarding.generate_bot_username("CoolBot")
      assert username =~ ~r/^coolbot_[a-f0-9]{4}_bot$/
    end

    test "strips special characters" do
      username = Onboarding.generate_bot_username("My Bot! 123")
      assert username =~ ~r/^my_bot_123_[a-f0-9]{4}_bot$/
    end

    test "truncates long names" do
      username = Onboarding.generate_bot_username(String.duplicate("a", 50))
      # 20 char slug + _ + 4 hex + _bot = 29 chars max
      assert String.length(username) <= 32
    end
  end

  describe "confirm_message/2" do
    test "builds the creation link" do
      session = %{Onboarding.new_session() | step: :confirm, name: "Вася", personality: "kawaii", language: "ru"}
      {text, keyboard, link} = Onboarding.confirm_message(session, "DruzhokBot")
      assert text =~ "Создать"
      assert link =~ "t.me/newbot/DruzhokBot/"
      assert link =~ "name="
      assert keyboard != nil
    end
  end

  describe "personalities/0" do
    test "returns a non-empty list of {key, label} tuples" do
      list = Onboarding.personalities()
      assert length(list) > 10
      assert {"kawaii", "Кавай"} in list
      assert {"pirate", "Пират"} in list
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
mix test apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs
```

Expected: all failures (module doesn't exist).

- [ ] **Step 3: Implement the module**

Create `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/onboarding.ex`:

```elixir
defmodule Druzhok.ManagerBot.Onboarding do
  @moduledoc """
  Pure-function state machine for the manager bot's onboarding flow.

  Steps: :name → :personality → :language → :confirm → :done
  Each step returns {:ok, session, reply} or {:retry, session, reply}.
  """

  @personalities [
    {"helpful", "Помощник"},
    {"kawaii", "Кавай"},
    {"pirate", "Пират"},
    {"noir", "Нуар"},
    {"philosopher", "Философ"},
    {"shakespeare", "Шекспир"},
    {"surfer", "Сёрфер"},
    {"hype", "Хайп"},
    {"concise", "Краткий"},
    {"technical", "Технарь"},
    {"creative", "Креативный"},
    {"teacher", "Учитель"},
    {"catgirl", "Кошкодевочка"},
    {"uwu", "UwU"},
  ]

  @personality_keys Enum.map(@personalities, fn {k, _} -> k end)

  def personalities, do: @personalities

  def new_session do
    %{
      step: :name,
      name: nil,
      personality: nil,
      language: nil,
      started_at: System.system_time(:second)
    }
  end

  # --- Step handlers ---

  def handle_input(%{step: :name} = session, %{text: text}) do
    name = String.trim(text || "")
    if name == "" do
      {:retry, session, {:text, "Имя не может быть пустым. Как назовём бота?"}}
    else
      session = %{session | step: :personality, name: name}
      {:ok, session, personality_reply()}
    end
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "personality:" <> key}) do
    if key in @personality_keys do
      session = %{session | step: :language, personality: key}
      {:ok, session, language_reply()}
    else
      {:retry, session, personality_reply()}
    end
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "more_personalities"}) do
    {:ok, session, personality_reply_page2()}
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "back_personalities"}) do
    {:ok, session, personality_reply()}
  end

  def handle_input(%{step: :personality} = session, _input) do
    {:retry, session, personality_reply()}
  end

  def handle_input(%{step: :language} = session, %{callback_data: "lang:" <> lang})
      when lang in ["ru", "en"] do
    session = %{session | step: :confirm, language: lang}
    {:ok, session, {:confirm, session}}
  end

  def handle_input(%{step: :language} = session, _input) do
    {:retry, session, language_reply()}
  end

  def handle_input(%{step: :confirm} = session, _input) do
    {:retry, session, {:confirm, session}}
  end

  def handle_input(%{step: :done} = session, _input) do
    {:retry, session, {:text, "Бот уже создан!"}}
  end

  # Catch-all for unexpected step/input combos
  def handle_input(session, _input) do
    {:retry, session, {:text, "Что-то пошло не так. Начни заново: /start"}}
  end

  # --- Message builders ---

  def welcome_message do
    "Привет! Я создам тебе персонального AI-бота.\n\nКак его назвать?"
  end

  def confirm_message(session, manager_username) do
    username = generate_bot_username(session.name)
    encoded_name = URI.encode(session.name)
    link = "https://t.me/newbot/#{manager_username}/#{username}?name=#{encoded_name}"

    text = "Отлично! Нажми кнопку — Telegram предложит создать бота:"
    keyboard = [[%{text: "🤖 Создать «#{session.name}»", url: link}]]

    {text, keyboard, link}
  end

  def completion_message(bot_username) do
    "✅ Бот @#{bot_username} создан и запущен!\n→ Написать боту: https://t.me/#{bot_username}"
  end

  def limit_message do
    "У тебя уже 2 бота — это максимум. Удали один из существующих чтобы создать новый."
  end

  # --- Username generation ---

  def generate_bot_username(display_name) do
    slug =
      display_name
      |> transliterate()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")
      |> String.slice(0, 20)

    slug = if slug == "", do: "bot", else: slug
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{slug}_#{suffix}_bot"
  end

  # --- Private ---

  defp personality_reply do
    page1 = Enum.take(@personalities, 8)
    buttons = Enum.map(page1, fn {key, label} ->
      %{text: label, callback_data: "personality:#{key}"}
    end)
    rows = Enum.chunk_every(buttons, 4)
    rows = rows ++ [[%{text: "Ещё...", callback_data: "more_personalities"}]]
    {:keyboard, "Характер бота:", rows}
  end

  defp personality_reply_page2 do
    page2 = Enum.drop(@personalities, 8)
    buttons = Enum.map(page2, fn {key, label} ->
      %{text: label, callback_data: "personality:#{key}"}
    end)
    rows = Enum.chunk_every(buttons, 4)
    rows = rows ++ [[%{text: "← Назад", callback_data: "back_personalities"}]]
    {:keyboard, "Характер бота:", rows}
  end

  defp language_reply do
    {:keyboard, "Язык:", [
      [%{text: "Русский", callback_data: "lang:ru"}, %{text: "English", callback_data: "lang:en"}]
    ]}
  end

  @transliteration %{
    "а" => "a", "б" => "b", "в" => "v", "г" => "g", "д" => "d",
    "е" => "e", "ё" => "yo", "ж" => "zh", "з" => "z", "и" => "i",
    "й" => "y", "к" => "k", "л" => "l", "м" => "m", "н" => "n",
    "о" => "o", "п" => "p", "р" => "r", "с" => "s", "т" => "t",
    "у" => "u", "ф" => "f", "х" => "kh", "ц" => "ts", "ч" => "ch",
    "ш" => "sh", "щ" => "shch", "ъ" => "", "ы" => "y", "ь" => "",
    "э" => "e", "ю" => "yu", "я" => "ya",
  }

  defp transliterate(text) do
    text
    |> String.graphemes()
    |> Enum.map(fn char ->
      lower = String.downcase(char)
      Map.get(@transliteration, lower, char)
    end)
    |> Enum.join()
  end
end
```

- [ ] **Step 4: Run tests**

```bash
mix test apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/onboarding.ex v4/druzhok/apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "manager_bot: onboarding state machine + message builders (TDD)"
```

---

## Task 3: Provisioner module (TDD)

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/provisioner.ex`
- Create: `v4/druzhok/apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs`

This module handles the post-creation pipeline. It's a set of functions called by the GenServer when a `managed_bot` update arrives.

- [ ] **Step 1: Write the test file**

Create `v4/druzhok/apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs`:

```elixir
defmodule Druzhok.ManagerBot.ProvisionerTest do
  use ExUnit.Case, async: true

  alias Druzhok.ManagerBot.Provisioner

  describe "derive_instance_name/1" do
    test "strips trailing _bot from username" do
      assert Provisioner.derive_instance_name("vasya_a7f3_bot") == "vasya_a7f3"
    end

    test "handles username without _bot suffix" do
      assert Provisioner.derive_instance_name("vasya") == "vasya"
    end

    test "handles complex usernames" do
      assert Provisioner.derive_instance_name("my_cool_ai_bot") == "my_cool_ai"
    end
  end

  describe "personality_to_soul/1" do
    test "returns hermes built-in personality names as-is" do
      assert Provisioner.personality_to_soul("kawaii") == {:builtin, "kawaii"}
    end

    test "returns nil for unknown personality" do
      assert Provisioner.personality_to_soul("nonexistent") == nil
    end
  end

  describe "build_create_opts/1" do
    test "assembles the options map for BotManager.create" do
      opts = Provisioner.build_create_opts(%{
        token: "123:ABC",
        model: "xiaomi/mimo-v2-pro",
        owner_id: 601956,
        language: "ru",
        bot_runtime: "hermes"
      })

      assert opts[:telegram_token] == "123:ABC"
      assert opts[:model] == "xiaomi/mimo-v2-pro"
      assert opts[:owner_telegram_id] == 601956
      assert opts[:language] == "ru"
      assert opts[:bot_runtime] == "hermes"
      assert opts[:mention_only] == true
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
mix test apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs
```

Expected: failures (module doesn't exist).

- [ ] **Step 3: Implement the module**

Create `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/provisioner.ex`:

```elixir
defmodule Druzhok.ManagerBot.Provisioner do
  @moduledoc """
  Provisioning pipeline for managed bots.

  Called by ManagerBot GenServer when a `managed_bot` update arrives.
  Handles: token retrieval → instance creation → personality application → auto-pairing.
  """

  require Logger

  alias Druzhok.{BotManager, Instance, Repo}
  alias Druzhok.Telegram.API

  @default_model "xiaomi/mimo-v2-pro"

  @hermes_personalities ~w(helpful kawaii pirate noir philosopher shakespeare surfer hype concise technical creative teacher catgirl uwu)

  @doc """
  Run the full provisioning pipeline.

  Returns {:ok, instance_name, bot_username} or {:error, reason}.
  """
  def provision(manager_token, bot_user_id, bot_username, session) do
    with {:ok, token} <- fetch_token(manager_token, bot_user_id),
         instance_name = derive_instance_name(bot_username),
         opts = build_create_opts(%{
           token: token,
           model: @default_model,
           owner_id: session[:owner_id],
           language: session[:language] || "ru",
           bot_runtime: "hermes"
         }),
         {:ok, _result} <- BotManager.create(instance_name, opts) do
      apply_personality(instance_name, session[:personality])
      auto_pair_owner(instance_name, session[:owner_id])
      {:ok, instance_name, bot_username}
    else
      {:error, reason} ->
        Logger.error("Provisioning failed for @#{bot_username}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def derive_instance_name(bot_username) do
    bot_username
    |> String.replace_suffix("_bot", "")
    |> String.replace_suffix("Bot", "")
  end

  def personality_to_soul(key) when key in @hermes_personalities, do: {:builtin, key}
  def personality_to_soul(_), do: nil

  def build_create_opts(params) do
    %{
      telegram_token: params[:token],
      model: params[:model] || @default_model,
      owner_telegram_id: params[:owner_id],
      language: params[:language] || "ru",
      bot_runtime: params[:bot_runtime] || "hermes",
      mention_only: true,
      allow_all_telegram_users: false,
    }
  end

  # --- Private ---

  defp fetch_token(manager_token, bot_user_id) do
    case API.get_managed_bot_token(manager_token, bot_user_id) do
      {:ok, token} when is_binary(token) -> {:ok, token}
      {:ok, other} -> {:error, "unexpected token response: #{inspect(other)}"}
      {:error, reason} -> {:error, "getManagedBotToken failed: #{inspect(reason)}"}
    end
  end

  defp apply_personality(instance_name, personality) do
    case personality_to_soul(personality) do
      {:builtin, key} ->
        case Repo.get_by(Instance, name: instance_name) do
          nil -> :ok
          instance ->
            data_root = Path.dirname(instance.workspace || "")
            config_path = Path.join(data_root, "config.yaml")
            case File.read(config_path) do
              {:ok, content} ->
                line = "  personality: #{key}"
                updated = if content =~ ~r/^\s*personality:/m do
                  Regex.replace(~r/^\s*personality:.*$/m, content, line)
                else
                  # Append under display: section or at top level
                  content <> "\ndisplay:\n#{line}\n"
                end
                File.write!(config_path, updated)
              {:error, _} -> :ok
            end
        end
      nil -> :ok
    end
  end

  defp auto_pair_owner(instance_name, owner_id) when is_integer(owner_id) do
    case Repo.get_by(Instance, name: instance_name) do
      nil -> :ok
      instance -> Instance.add_allowed_id(instance, to_string(owner_id))
    end
  end
  defp auto_pair_owner(_, _), do: :ok
end
```

- [ ] **Step 4: Run tests**

```bash
mix test apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/manager_bot/provisioner.ex v4/druzhok/apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "manager_bot: provisioner module — token fetch, create, personality, auto-pair"
```

---

## Task 4: ManagerBot GenServer

**Files:**
- Create: `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot.ex`

This is the GenServer that ties everything together: long-polling, user session state, dispatching to Onboarding + Provisioner.

- [ ] **Step 1: Create the GenServer**

Create `v4/druzhok/apps/druzhok/lib/druzhok/manager_bot.ex`:

```elixir
defmodule Druzhok.ManagerBot do
  @moduledoc """
  Telegram manager bot GenServer.

  Long-polls the Telegram Bot API for a dedicated manager bot token.
  Handles onboarding conversations via inline keyboards, then provisions
  hermes instances when users create managed bots.
  """
  use GenServer
  require Logger

  alias Druzhok.Telegram.API
  alias Druzhok.ManagerBot.{Onboarding, Provisioner}

  @session_ttl_seconds 600  # 10 minutes
  @poll_timeout 30
  @max_bots_per_user 2

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Callbacks ---

  @impl true
  def init(_opts) do
    state = %{
      token: nil,
      bot_username: nil,
      offset: 0,
      sessions: %{},       # %{user_id => onboarding session}
      polling: false
    }

    send(self(), :try_start)
    {:ok, state}
  end

  @impl true
  def handle_info(:try_start, state) do
    token = Druzhok.Settings.get("manager_bot_token")

    if token && token != "" do
      case API.get_me(token) do
        {:ok, %{"username" => username}} ->
          Logger.info("ManagerBot started as @#{username}")
          send(self(), :poll)
          {:noreply, %{state | token: token, bot_username: username, polling: true}}

        {:error, reason} ->
          Logger.warning("ManagerBot: getMe failed (#{inspect(reason)}), retrying in 30s")
          Process.send_after(self(), :try_start, 30_000)
          {:noreply, state}
      end
    else
      Logger.info("ManagerBot: no manager_bot_token configured, staying idle")
      Process.send_after(self(), :try_start, 60_000)
      {:noreply, state}
    end
  end

  def handle_info(:poll, %{token: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    case API.get_updates(state.token, state.offset, @poll_timeout) do
      {:ok, updates} when is_list(updates) ->
        state = Enum.reduce(updates, state, &process_update/2)
        new_offset = if updates != [], do: List.last(updates)["update_id"] + 1, else: state.offset
        state = cleanup_expired_sessions(%{state | offset: new_offset})
        send(self(), :poll)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("ManagerBot poll error: #{inspect(reason)}")
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Update processing ---

  defp process_update(%{"message" => msg}, state) do
    user_id = get_in(msg, ["from", "id"])
    chat_id = msg["chat"]["id"]
    text = msg["text"] || ""

    cond do
      # /start or first message — begin onboarding
      text == "/start" or not Map.has_key?(state.sessions, user_id) ->
        start_onboarding(state, user_id, chat_id)

      # Free text — dispatch to current step
      true ->
        dispatch_input(state, user_id, chat_id, %{text: text})
    end
  end

  defp process_update(%{"callback_query" => cb}, state) do
    user_id = cb["from"]["id"]
    chat_id = cb["message"]["chat"]["id"]
    data = cb["data"]

    # Acknowledge the button tap
    API.answer_callback_query(state.token, cb["id"])

    dispatch_input(state, user_id, chat_id, %{callback_data: data})
  end

  defp process_update(%{"managed_bot" => managed_bot}, state) do
    handle_managed_bot(state, managed_bot)
  end

  defp process_update(_update, state), do: state

  # --- Onboarding ---

  defp start_onboarding(state, user_id, chat_id) do
    if user_bot_count(user_id) >= @max_bots_per_user do
      API.send_message(state.token, chat_id, Onboarding.limit_message())
      state
    else
      session = Onboarding.new_session()
      API.send_message(state.token, chat_id, Onboarding.welcome_message())
      put_in(state, [:sessions, user_id], session)
    end
  end

  defp dispatch_input(state, user_id, chat_id, input) do
    session = state.sessions[user_id] || Onboarding.new_session()

    case Onboarding.handle_input(session, input) do
      {:ok, session, {:confirm, session}} ->
        {text, keyboard, _link} = Onboarding.confirm_message(session, state.bot_username)
        send_with_inline_keyboard(state.token, chat_id, text, keyboard)
        put_in(state, [:sessions, user_id], session)

      {:ok, session, {:keyboard, text, rows}} ->
        send_with_callback_keyboard(state.token, chat_id, text, rows)
        put_in(state, [:sessions, user_id], session)

      {:ok, session, {:text, text}} ->
        API.send_message(state.token, chat_id, text)
        put_in(state, [:sessions, user_id], session)

      {:retry, session, {:keyboard, text, rows}} ->
        send_with_callback_keyboard(state.token, chat_id, text, rows)
        put_in(state, [:sessions, user_id], session)

      {:retry, session, {:text, text}} ->
        API.send_message(state.token, chat_id, text)
        put_in(state, [:sessions, user_id], session)

      {:retry, session, {:confirm, session}} ->
        {text, keyboard, _link} = Onboarding.confirm_message(session, state.bot_username)
        send_with_inline_keyboard(state.token, chat_id, text, keyboard)
        put_in(state, [:sessions, user_id], session)
    end
  end

  # --- Managed bot creation ---

  defp handle_managed_bot(state, managed_bot) do
    creator_id = get_in(managed_bot, ["user", "id"])
    bot_id = get_in(managed_bot, ["bot", "id"])
    bot_username = get_in(managed_bot, ["bot", "username"])

    session = Map.get(state.sessions, creator_id, %{})
    session = Map.put(session, :owner_id, creator_id)

    Task.start(fn ->
      case Provisioner.provision(state.token, bot_id, bot_username, session) do
        {:ok, _name, username} ->
          # Find the chat_id — use the creator's DM (same as user_id for private chats)
          msg = Onboarding.completion_message(username)
          API.send_message(state.token, creator_id, msg)

        {:error, reason} ->
          API.send_message(state.token, creator_id,
            "Ошибка создания бота: #{inspect(reason)}\nПопробуй ещё раз.")
      end
    end)

    # Clean up the session
    update_in(state, [:sessions], &Map.delete(&1, creator_id))
  end

  # --- Helpers ---

  defp user_bot_count(user_id) do
    import Ecto.Query
    Druzhok.Repo.aggregate(
      from(i in Druzhok.Instance, where: i.owner_telegram_id == ^user_id),
      :count
    )
  end

  defp cleanup_expired_sessions(state) do
    now = System.system_time(:second)
    sessions =
      state.sessions
      |> Enum.reject(fn {_uid, session} ->
        (now - (session[:started_at] || 0)) > @session_ttl_seconds
      end)
      |> Map.new()
    %{state | sessions: sessions}
  end

  defp send_with_callback_keyboard(token, chat_id, text, rows) do
    keyboard = %{
      inline_keyboard: Enum.map(rows, fn row ->
        Enum.map(row, fn btn ->
          %{text: btn.text, callback_data: btn.callback_data}
        end)
      end)
    }
    API.send_message(token, chat_id, text, %{reply_markup: Jason.encode!(keyboard)})
  end

  defp send_with_inline_keyboard(token, chat_id, text, rows) do
    keyboard = %{
      inline_keyboard: Enum.map(rows, fn row ->
        Enum.map(row, fn btn ->
          if btn[:url] do
            %{text: btn.text, url: btn.url}
          else
            %{text: btn.text, callback_data: btn[:callback_data] || "noop"}
          end
        end)
      end)
    }
    API.send_message(token, chat_id, text, %{reply_markup: Jason.encode!(keyboard)})
  end
end
```

- [ ] **Step 2: Compile**

```bash
mix compile
```

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/manager_bot.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "manager_bot: GenServer — long-polling, state machine, provisioning dispatch"
```

---

## Task 5: Wire into supervision tree

**Files:**
- Modify: `v4/druzhok/apps/druzhok/lib/druzhok/application.ex`

- [ ] **Step 1: Add ManagerBot to children**

In `v4/druzhok/apps/druzhok/lib/druzhok/application.ex`, find the `children` list (currently ends with `Druzhok.HealthMonitor`). Add `Druzhok.ManagerBot` after it:

```elixir
    children = [
      Druzhok.Repo,
      {Registry, keys: :unique, name: Druzhok.Registry},
      {DynamicSupervisor, name: Druzhok.InstanceDynSup, strategy: :one_for_one},
      {Finch, name: Druzhok.Finch, pools: finch_pools()},
      {Finch, name: Druzhok.LocalFinch},
      Druzhok.HealthMonitor,
      Druzhok.ManagerBot
    ]
```

- [ ] **Step 2: Compile + verify startup**

```bash
mix compile
```

From `/Users/igorkuznetsov/Documents/druzhok/v4/druzhok`:

```bash
DATABASE_PATH=data/druzhok.db mix run -e "Process.sleep(3000)" 2>&1 | grep -i "manager"
```

Expected: log line like `ManagerBot: no manager_bot_token configured, staying idle` (since we haven't set the token yet).

- [ ] **Step 3: Commit**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok add v4/druzhok/apps/druzhok/lib/druzhok/application.ex
git -C /Users/igorkuznetsov/Documents/druzhok commit -m "supervision: add ManagerBot to application children"
```

---

## Task 6: Deploy + configure manager bot token

This is operational. All code must be committed + pushed first.

- [ ] **Step 1: Create a manager bot via BotFather**

In Telegram, message @BotFather:
```
/newbot
Name: Druzhok Manager
Username: DruzhokManagerBot (or available variant)
```

Copy the token BotFather gives you.

**Enable Bot Management Mode**: open BotFather → `/mybots` → select the new bot → Bot Settings → enable "Bot Management Mode" (this is required for Telegram to send `managed_bot` updates to this bot).

- [ ] **Step 2: Push code + deploy**

```bash
git -C /Users/igorkuznetsov/Documents/druzhok push origin main
ssh igor@158.160.78.230 "cd ~/druzhok && git pull --ff-only 2>&1 | tail -3"
ssh igor@158.160.78.230 "sudo systemctl restart druzhok"
```

Wait for druzhok to start.

- [ ] **Step 3: Set the manager bot token**

Via the druzhok settings page (`https://oldey.dev/settings`), or directly:

```bash
ssh igor@158.160.78.230 "source ~/.bashrc; . ~/.asdf/asdf.sh; cd ~/druzhok/v4/druzhok && DATABASE_PATH=/home/igor/druzhok-data/v4-druzhok.db mix run -e 'Druzhok.Settings.set(\"manager_bot_token\", \"<PASTE-TOKEN>\")'"
```

- [ ] **Step 4: Restart druzhok so ManagerBot picks up the token**

```bash
ssh igor@158.160.78.230 "sudo systemctl restart druzhok"
```

Check logs:

```bash
ssh igor@158.160.78.230 "sudo journalctl -u druzhok --since '1 min ago' --no-pager | grep -i manager"
```

Expected: `ManagerBot started as @DruzhokManagerBot` (or whatever username you chose).

- [ ] **Step 5: End-to-end smoke test**

Open the manager bot in Telegram. Send `/start`. Walk through the full flow:
1. Type a name
2. Pick a personality from the keyboard
3. Pick a language
4. Tap the creation button → Telegram's native UI → confirm
5. Wait for confirmation message with the bot link
6. Open the new bot → send a message → verify it responds

Check the druzhok dashboard: the new instance should appear in the sidebar.

- [ ] **Step 6: Test the 2-bot limit**

Create a second bot via the manager. Then try creating a third — the manager bot should respond with the limit message.

---

## Self-Review

**Spec coverage:**
- ManagerBot GenServer (long-polling, state machine) → Task 4
- Onboarding flow (name → personality → language → confirm) → Task 2
- Inline keyboards + button handling → Task 2 (builders) + Task 4 (dispatch)
- Username generation (transliterate + suffix) → Task 2
- Provisioning pipeline (token fetch → create → personality → auto-pair) → Task 3
- 2-bot-per-user limit → Task 4 (`user_bot_count`)
- Manager bot token in Settings → Task 6
- Supervision tree → Task 5
- Telegram API extensions → Task 1
- Error handling (token fail, create fail, timeout) → Task 4 GenServer + Task 3 Provisioner
- Session expiry (10 min cleanup) → Task 4

No gaps.

**Placeholder scan:** No TBDs. All code blocks complete. The BotFather "enable Bot Management Mode" step in Task 6 is manual but documented.

**Type consistency:** `Onboarding.new_session()` returns `%{step, name, personality, language, started_at}`. `Provisioner.provision/4` receives `session` map with those keys + `:owner_id` (added in `handle_managed_bot`). `build_create_opts/1` takes a flat params map with explicit keys. `API.get_managed_bot_token/2` takes `(token, bot_user_id)`. All consistent.
