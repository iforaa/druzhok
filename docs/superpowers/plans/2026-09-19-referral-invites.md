# Referral Invites and the One-Bot Superbot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The superbot admits a new person only with an invite or referral code, gives each person one bot, replaces the create button with the bot's controls once it exists, and lets an owner share the referral codes the operator issued to their bot's account.

**Architecture:** Admission is a druzhok table written after ruoc-gateway accepts a code at account creation. The code travels in the manager-bot session from `/start ref_…` or a typed message, through `Provisioner.provision` and `BotManager.create`, to `Ruoc.create_account(label, invite: code)`. `Onboarding` stays a pure state machine; every ruoc call and every keyboard decision lives in `ManagerBot`. The reply keyboard is rebuilt from the user's bot count on every send.

**Tech Stack:** Elixir umbrella, Ecto + SQLite, Finch HTTP, Bypass stubs in tests (`Druzhok.RuocStub`, `Druzhok.TelegramStub`).

**Spec:** `docs/superpowers/specs/2026-09-19-referral-invites-design.md`. Gateway contract: ruoc-gateway `docs/superpowers/specs/2026-09-19-referral-invites-for-api-accounts-design.md` (must be deployed first; its plan is `docs/superpowers/plans/2026-09-19-referral-invites-for-api-accounts.md` in that repo).

## Global Constraints

- Tests: `mix test` at the umbrella root; core tests run outside a SQL sandbox, so every row a test inserts gets a unique id and an `on_exit` cleanup. After adding a migration: `MIX_ENV=test mix ecto.migrate`.
- Commits through `/my-commit`: short imperative, no attribution trailers of any kind.
- Never `cd … && …`; use `git -C` or absolute paths.
- User-facing strings are Russian, informal «ты», exactly as written in the spec: prompt "Создание по приглашению. Введи код или открой ссылку от друга."; statuses "Этот код уже использован." / "Срок этого кода истёк." / "Код не найден. Проверь ссылку или попроси новый." / "Не получилось проверить код, попробуй позже."; race "Код успели использовать. Попроси новый и создай бота заново."; limit "У тебя уже есть бот. Удали его, чтобы создать нового."; invites intro "Пригласи друга — по этой ссылке он сможет создать своего бота:"; none "У тебя пока нет приглашений."; error "Не получилось загрузить приглашения, попробуй позже."; redeemed line "Использован <5 окт>".
- Keyboard rows by bot count: 0 → `[🤖 Создать бота]`; 1 → `[🤖 Мой бот] [🎨 Картинки]` / `[🎁 Пригласить] [🗑 Удалить]`; 2+ → `[📋 Мои боты]`.
- Ruoc contract: `POST /admin/accounts` body may carry `invite`; 409 with `error.type` `invite_invalid | invite_spent | invite_expired`. `GET /admin/invites/check?code=` → `{"status":"available"|"spent"|"expired"|"invalid"}`. `GET /v1/referrals` (bot key) → `{"codes":[{"code","status","redeemed_at","friend_gets_nanorub","you_get_nanorub"}]}`.
- The operator (`Druzhok.Settings.operator_telegram_id/0`, string or integer) is admitted by rule and may own several bots.

---

## File Structure

| File | Responsibility |
|---|---|
| `apps/druzhok/priv/repo/migrations/20260919000001_create_admissions.exs` (create) | `admissions` table + grandfather every existing owner |
| `apps/druzhok/lib/druzhok/admissions.ex` (create) | `admitted?/1`, `admit/2` |
| `apps/druzhok/lib/druzhok/ruoc.ex` (modify) | `create_account/2` with `invite`, `check_invite/1`, `referrals/1`, `admin_get/1` |
| `apps/druzhok/test/support/ruoc_stub.ex` (modify) | routes for check and referrals |
| `apps/druzhok/lib/druzhok/bot_manager.ex` (modify) | passes `invite`, maps the 409, writes the admission |
| `apps/druzhok/lib/druzhok/manager_bot/provisioner.ex` (modify) | carries `invite` from the session into the create opts |
| `apps/druzhok/lib/druzhok/manager_bot/onboarding.ex` (modify) | keyboard by count, `:invite` step, texts, «Мой бот» card, invite messages |
| `apps/druzhok/lib/druzhok/manager_bot.ex` (modify) | `/start` payload, gating, menu buttons, keyboards after create/delete |
| tests under `apps/druzhok/test/druzhok/` | as listed per task |

---

### Task 1: Admissions

**Files:**
- Create: `apps/druzhok/priv/repo/migrations/20260919000001_create_admissions.exs`
- Create: `apps/druzhok/lib/druzhok/admissions.ex`
- Test: `apps/druzhok/test/druzhok/admissions_test.exs`

**Interfaces:**
- Produces:
  ```elixir
  Druzhok.Admissions.admitted?(telegram_id :: integer) :: boolean
  Druzhok.Admissions.admit(telegram_id :: integer, hint :: String.t()) :: :ok   # idempotent
  ```

- [ ] **Step 1: Write the failing test**

Create `apps/druzhok/test/druzhok/admissions_test.exs`:

```elixir
defmodule Druzhok.AdmissionsTest do
  use ExUnit.Case, async: false

  alias Druzhok.{Admissions, Repo}

  setup do
    id = System.unique_integer([:positive]) + 10_000_000
    on_exit(fn -> Repo.delete_all(from_admissions(id)) end)
    %{id: id}
  end

  defp from_admissions(id) do
    import Ecto.Query
    from(a in "admissions", where: a.telegram_id == ^id)
  end

  test "a person is not admitted until admitted, and stays admitted", %{id: id} do
    refute Admissions.admitted?(id)
    assert :ok = Admissions.admit(id, "ABCD")
    assert Admissions.admitted?(id)
    # Admitting twice is fine: a rename or a recreate must not need a second code.
    assert :ok = Admissions.admit(id, "WXYZ")
    assert Admissions.admitted?(id)
    assert Repo.aggregate(from_admissions(id), :count) == 1
  end

  test "nil is never admitted" do
    refute Admissions.admitted?(nil)
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mix test apps/druzhok/test/druzhok/admissions_test.exs`
Expected: compile error, `Druzhok.Admissions` undefined.

- [ ] **Step 3: Migration**

Create `apps/druzhok/priv/repo/migrations/20260919000001_create_admissions.exs`:

```elixir
defmodule Druzhok.Repo.Migrations.CreateAdmissions do
  use Ecto.Migration

  # Who may create a bot. A row is written when ruoc-gateway accepted the
  # person's invite code at account creation, and is never removed: deleting
  # the bot does not take the admission back, so a rename needs no new code.
  # Everyone who owns a bot when this runs is admitted, so the invite gate
  # locks nobody out who is already here.
  def up do
    create table(:admissions) do
      add :telegram_id, :integer, null: false
      add :invite_hint, :string, null: false, default: ""
      add :admitted_at, :utc_datetime, null: false
    end

    create unique_index(:admissions, [:telegram_id])

    execute """
    insert into admissions (telegram_id, invite_hint, admitted_at)
    select distinct owner_telegram_id, 'grandfathered', strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    from instances where owner_telegram_id is not null
    """
  end

  def down, do: drop(table(:admissions))
end
```

- [ ] **Step 4: Module**

Create `apps/druzhok/lib/druzhok/admissions.ex`:

```elixir
defmodule Druzhok.Admissions do
  @moduledoc """
  Who may create a bot. The superbot is invite-only: a person gets in with a
  code, ruoc-gateway redeems it when the bot's account is created, and this
  table remembers that they got in. Permanent on purpose — a person who
  deletes their bot and makes a new one is not asked for a second code.

  The operator is admitted by rule, not by row; `ManagerBot` checks that.
  """

  import Ecto.Query
  alias Druzhok.Repo

  @doc "True when `telegram_id` has been admitted before."
  def admitted?(nil), do: false

  def admitted?(telegram_id) when is_integer(telegram_id) do
    Repo.exists?(from(a in "admissions", where: a.telegram_id == ^telegram_id))
  end

  @doc """
  Record the admission. `hint` is the first characters of the code that let
  them in (or a word like "grandfathered"), for the operator's eyes only.
  Idempotent: a second call for the same person changes nothing.
  """
  def admit(telegram_id, hint) when is_integer(telegram_id) and is_binary(hint) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "admissions",
      [%{telegram_id: telegram_id, invite_hint: String.slice(hint, 0, 8), admitted_at: now}],
      on_conflict: :nothing,
      conflict_target: [:telegram_id]
    )

    :ok
  end
end
```

- [ ] **Step 5: Migrate the test DB and run**

Run: `MIX_ENV=test mix ecto.migrate && mix test apps/druzhok/test/druzhok/admissions_test.exs`
Expected: 2 tests, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok/priv/repo/migrations/20260919000001_create_admissions.exs apps/druzhok/lib/druzhok/admissions.ex apps/druzhok/test/druzhok/admissions_test.exs
git commit -m "admissions: who may create a bot, existing owners grandfathered"
```

---

### Task 2: Ruoc client: invite on create, check, referrals

**Files:**
- Modify: `apps/druzhok/lib/druzhok/ruoc.ex:59-84` (`create_account`), add `check_invite/1`, `referrals/1`, `admin_get/1`
- Modify: `apps/druzhok/test/support/ruoc_stub.ex` (`default_routes`)
- Test: `apps/druzhok/test/druzhok/ruoc_test.exs`

**Interfaces:**
- Produces:
  ```elixir
  Druzhok.Ruoc.create_account(label, opts \\ [])   # opts: grant_rubles: "5", invite: "CODE"
    :: {:ok, %{account_id, api_key}} | {:error, {:invite, :invalid | :spent | :expired}} | {:error, String.t()}
  Druzhok.Ruoc.check_invite(code) :: {:ok, :available | :spent | :expired | :invalid} | {:error, String.t()}
  Druzhok.Ruoc.referrals(api_key)
    :: {:ok, [%{code: String.t() | nil, status: String.t(), redeemed_at: DateTime.t() | nil,
               friend_rub: String.t(), you_rub: String.t()}]} | {:error, String.t()}
  ```
  `create_account(label, "5")` (a bare string second argument) is no longer accepted; the two callers in `bot_manager.ex` pass only the label today.

- [ ] **Step 1: Write the failing tests**

In `apps/druzhok/test/druzhok/ruoc_test.exs`, change the first two `create_account` tests to the keyword form and add the invite cases inside the same `describe "create_account/2"`:

```elixir
    test "posts label and grant with the admin token and Host header, returns the key", %{stub: stub} do
      assert {:ok, %{account_id: "acct-" <> _, api_key: "ruoc_key" <> _}} =
               Ruoc.create_account("druzhok:bot1", grant_rubles: "5")

      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      assert call.params == %{"label" => "druzhok:bot1", "grant_rubles" => "5"}
      assert {"authorization", "Bearer " <> RuocStub.admin_token()} in call.headers
      assert {"host", "admin.test"} in call.headers
    end

    test "omits grant_rubles and invite when none given", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:bot2")
      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      refute Map.has_key?(call.params, "grant_rubles")
      refute Map.has_key?(call.params, "invite")
    end

    test "sends the invite code and maps the three refusals", %{stub: stub} do
      assert {:ok, _} = Ruoc.create_account("druzhok:kot", invite: "ABCD-EFGH")
      [call] = RuocStub.calls(stub, "POST /admin/accounts")
      assert call.params["invite"] == "ABCD-EFGH"

      for {type, reason} <- [{"invite_invalid", :invalid}, {"invite_spent", :spent}, {"invite_expired", :expired}] do
        Bypass.expect_once(stub.bypass, "POST", "/admin/accounts", fn conn ->
          RuocStub.reply(conn, 409, %{"error" => %{"type" => type, "message" => "no"}})
        end)

        assert {:error, {:invite, ^reason}} = Ruoc.create_account("druzhok:kot", invite: "ABCD-EFGH")
      end
    end
```

Append two top-level tests:

```elixir
  describe "check_invite/1" do
    test "asks the admin surface and returns the status as an atom", %{stub: stub} do
      assert {:ok, :available} = Ruoc.check_invite("ABCD-EFGH")
      [call] = RuocStub.calls(stub, "GET /admin/invites/check")
      assert call.path == "/admin/invites/check"
      assert {"host", "admin.test"} in call.headers

      for status <- ["spent", "expired", "invalid"] do
        Bypass.expect_once(stub.bypass, "GET", "/admin/invites/check", fn conn ->
          RuocStub.reply(conn, 200, %{"status" => status})
        end)

        assert {:ok, String.to_atom(status)} == Ruoc.check_invite("x")
      end
    end

    test "an unknown status or a failure is an error", %{stub: stub} do
      Bypass.expect_once(stub.bypass, "GET", "/admin/invites/check", fn conn ->
        RuocStub.reply(conn, 200, %{"status" => "weird"})
      end)

      assert {:error, _} = Ruoc.check_invite("x")
      Bypass.down(stub.bypass)
      assert {:error, _} = Ruoc.check_invite("x")
    end
  end

  test "referrals/1 uses the bot key and decodes the codes", %{stub: stub} do
    assert {:ok, [first, second]} = Ruoc.referrals("ruoc_bot")
    [call] = RuocStub.calls(stub, "GET /v1/referrals")
    assert {"authorization", "Bearer ruoc_bot"} in call.headers
    assert %{code: "AAAA-BBBB", status: "available", redeemed_at: nil, friend_rub: "0.00", you_rub: "20.00"} = first
    assert %{code: "CCCC-DDDD", status: "redeemed", redeemed_at: %DateTime{}} = second

    Bypass.expect_once(stub.bypass, "GET", "/v1/referrals", fn conn ->
      RuocStub.reply(conn, 503, %{"error" => %{"type" => "api_error", "message" => "referrals are not available"}})
    end)

    assert {:error, "HTTP 503: referrals are not available"} = Ruoc.referrals("ruoc_bot")
  end
```

- [ ] **Step 2: Stub routes**

In `apps/druzhok/test/support/ruoc_stub.ex` `default_routes/1`, add:

```elixir
    Bypass.stub(bypass, "GET", "/admin/invites/check", fn conn ->
      conn = record(stub, "GET /admin/invites/check", conn)
      reply(conn, 200, %{"status" => "available"})
    end)

    Bypass.stub(bypass, "GET", "/v1/referrals", fn conn ->
      conn = record(stub, "GET /v1/referrals", conn)
      reply(conn, 200, %{"codes" => referral_codes()})
    end)
```

and a public fixture:

```elixir
  def referral_codes do
    [
      %{"code" => "AAAA-BBBB", "status" => "available", "friend_gets_nanorub" => 0, "you_get_nanorub" => 20_000_000_000},
      %{"code" => "CCCC-DDDD", "status" => "redeemed", "redeemed_at" => "2026-10-05T09:00:00Z",
        "friend_gets_nanorub" => 0, "you_get_nanorub" => 20_000_000_000}
    ]
  end
```

`record/3` reads the body; for GETs it records `%{}` params and the path, which is what the tests assert.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `mix test apps/druzhok/test/druzhok/ruoc_test.exs`
Expected: failures on `create_account/2` with keyword opts (today the second argument is `grant_rubles`), `check_invite/1` and `referrals/1` undefined.

- [ ] **Step 4: Implement**

In `apps/druzhok/lib/druzhok/ruoc.ex` replace `create_account/2`:

```elixir
  @doc """
  Create an account with one key. `{:ok, %{account_id, api_key}}`; the key
  is returned once by the gateway and stored on the instance by the caller.

  Options: `grant_rubles` (decimal string) funds the account on top of its
  plan; `invite` is a code the gateway redeems in the same commit — a refusal
  is `{:error, {:invite, :invalid | :spent | :expired}}` and no account
  exists.
  """
  def create_account(label, opts \\ []) when is_list(opts) do
    body =
      %{"label" => label}
      |> put_present("grant_rubles", opts[:grant_rubles])
      |> put_present("invite", opts[:invite])

    case admin_post("/admin/accounts", body) do
      {:ok, 201, %{"account_id" => id, "api_key" => key}} ->
        {:ok, %{account_id: id, api_key: key}}

      {:ok, 409, %{"error" => %{"type" => "invite_" <> reason}}} when reason in ["invalid", "spent", "expired"] ->
        {:error, {:invite, String.to_existing_atom(reason)}}

      other ->
        {:error, describe(other)}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, to_string(value))

  @doc """
  Whether `code` would be accepted right now, without spending it:
  `{:ok, :available | :spent | :expired | :invalid}`. The gateway is the
  authority at creation; this is only so a person is refused before naming
  their bot rather than after the Telegram step.
  """
  def check_invite(code) do
    case admin_get("/admin/invites/check?code=" <> URI.encode_www_form(code)) do
      {:ok, 200, %{"status" => status}} when status in ["available", "spent", "expired", "invalid"] ->
        {:ok, String.to_existing_atom(status)}

      other ->
        {:error, describe(other)}
    end
  end
```

Add next to `admin_post/2`:

```elixir
  defp admin_get(path) do
    case admin_token() do
      nil ->
        {:error, "ruoc_admin_token is not set"}

      token ->
        headers = if host = admin_host(), do: [{"host", host}], else: []

        case Client.get(path, token, headers: headers) do
          {:ok, status, _headers, resp} -> {:ok, status, decode(resp)}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end
```

Add to the bot-facing section:

```elixir
  @doc """
  The referral codes on a bot's account, oldest first:
  `%{code, status, redeemed_at, friend_rub, you_rub}`. `code` is nil when the
  gateway reports it underivable (its secret changed). `status` is one of
  available | redeemed | revoked | expired | underivable.
  """
  def referrals(api_key) do
    case Client.get("/v1/referrals", api_key) do
      {:ok, 200, _headers, body} ->
        case Jason.decode(body) do
          {:ok, %{"codes" => codes}} when is_list(codes) -> {:ok, Enum.map(codes, &to_referral/1)}
          _ -> {:error, "unexpected referrals payload"}
        end

      {:ok, status, _headers, body} ->
        {:error, describe({:ok, status, decode(body)})}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp to_referral(c) do
    redeemed_at =
      case DateTime.from_iso8601(c["redeemed_at"] || "") do
        {:ok, dt, _} -> DateTime.truncate(dt, :second)
        _ -> nil
      end

    %{
      code: c["code"],
      status: c["status"],
      redeemed_at: redeemed_at,
      friend_rub: format_rub(c["friend_gets_nanorub"] || 0),
      you_rub: format_rub(c["you_get_nanorub"] || 0)
    }
  end
```

`format_rub/1` and `decode/1` already exist in the module.

- [ ] **Step 5: Run the tests**

Run: `mix test apps/druzhok/test/druzhok/ruoc_test.exs apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs`
Expected: 0 failures (the lifecycle tests call `create_account/1` through `BotManager`, unchanged).

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok/lib/druzhok/ruoc.ex apps/druzhok/test/support/ruoc_stub.ex apps/druzhok/test/druzhok/ruoc_test.exs
git commit -m "ruoc client: invite on account creation, invite check, referral codes"
```

---

### Task 3: `BotManager.create` redeems the code and admits the owner

**Files:**
- Modify: `apps/druzhok/lib/druzhok/bot_manager.ex:10-43` (`create`, `provision_ruoc`) and `do_create` (after `InstanceManager.create`)
- Modify: `apps/druzhok/lib/druzhok/manager_bot/provisioner.ex:19-36,49-57`
- Test: `apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs` (describe "ruoc"), `apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs`

**Interfaces:**
- Consumes: `Ruoc.create_account/2`, `Admissions.admit/2` from Tasks 1–2.
- Produces: `BotManager.create(name, opts)` honours `opts[:invite]` (string or nil) and returns `{:error, {:invite, :invalid | :spent | :expired}}` with no local row when ruoc refuses. On success with an `owner_telegram_id` it calls `Admissions.admit(owner, hint)` where `hint` is the code's first four characters, or `"owner"` when no code was used. `Provisioner.build_create_opts/1` copies `params[:invite]` to `opts[:invite]`; `provision/4` reads `session[:invite]`.

- [ ] **Step 1: Write the failing tests**

In `apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs`, inside `describe "ruoc"`, add:

```elixir
    test "create sends the invite to ruoc and admits the owner", %{name: name, stub: stub} do
      owner = System.unique_integer([:positive]) + 20_000_000
      on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id == ^owner)) end)
      refute Druzhok.Admissions.admitted?(owner)

      {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A", owner_telegram_id: owner, invite: "ABCD-EFGH"})

      assert [%{params: params}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts")
      assert params["invite"] == "ABCD-EFGH"
      assert Druzhok.Admissions.admitted?(owner)
      assert %{invite_hint: "ABCD"} = Repo.one(from(a in "admissions", where: a.telegram_id == ^owner, select: %{invite_hint: a.invite_hint}))
    end

    test "a refused invite leaves no row and no admission", %{name: name, stub: stub} do
      owner = System.unique_integer([:positive]) + 20_000_000

      Bypass.expect_once(stub.bypass, "POST", "/admin/accounts", fn conn ->
        Druzhok.RuocStub.reply(conn, 409, %{"error" => %{"type" => "invite_spent", "message" => "used"}})
      end)

      assert {:error, {:invite, :spent}} =
               BotManager.create(name, %{model: "m", telegram_token: "1A", owner_telegram_id: owner, invite: "ABCD-EFGH"})

      assert Repo.get_by(Instance, name: name) == nil
      refute Druzhok.Admissions.admitted?(owner)
    end

    test "create without a code still admits the owner", %{name: name} do
      owner = System.unique_integer([:positive]) + 20_000_000
      on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id == ^owner)) end)
      {:ok, _} = BotManager.create(name, %{model: "m", telegram_token: "1A", owner_telegram_id: owner})
      assert Druzhok.Admissions.admitted?(owner)
    end
```

Add `import Ecto.Query, only: [from: 2]` at the top of the test module if it is not imported.

In `apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs` `describe "build_create_opts/1"`:

```elixir
    test "carries the invite code when the session had one" do
      assert Provisioner.build_create_opts(%{token: "1", owner_id: 1, invite: "ABCD-EFGH"})[:invite] == "ABCD-EFGH"
      refute Map.has_key?(Provisioner.build_create_opts(%{token: "1", owner_id: 1}), :invite)
    end
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs`
Expected: the invite is not forwarded, the owner is not admitted, `build_create_opts` has no `:invite`.

- [ ] **Step 3: Implement in `BotManager`**

Replace `provision_ruoc/2`'s ruoc branch:

```elixir
      Druzhok.Ruoc.configured?() ->
        label = ruoc_label(name, opts[:owner_telegram_id])

        case Druzhok.Ruoc.create_account(label, invite: opts[:invite]) do
          {:ok, %{account_id: id, api_key: key}} ->
            {:ok,
             opts
             |> Map.merge(%{ruoc_account_id: id, ruoc_api_key: key})
             |> Map.update(:model, Druzhok.Ruoc.default_model(), &Druzhok.Ruoc.remap_model/1)}

          {:error, {:invite, _} = refused} ->
            # The gate held: no account, no row, and the person is told the
            # code did not work. Not logged as an error — it is theirs to fix.
            {:error, refused}

          {:error, reason} ->
            Logger.error("ruoc account for #{name} failed: #{reason}")
            {:error, "ruoc-gateway account creation failed: #{reason}"}
        end
```

In `do_create/2`, after `if token_record.id, do: TokenPool.claim(token_record, instance.id)`:

```elixir
            admit_owner(opts)
```

and add the helper near `ruoc_label/2`:

```elixir
  # Creating a bot is what admission means. With a code the hint is its first
  # characters; without one (the operator, a grandfathered owner, a recreate)
  # the row says "owner" so the console can tell the two apart.
  defp admit_owner(%{owner_telegram_id: owner} = opts) when is_integer(owner) do
    Druzhok.Admissions.admit(owner, opts[:invite] || "owner")
  end

  defp admit_owner(_), do: :ok
```

`InstanceManager.create/2` reads named keys only, so `opts[:invite]` never reaches the changeset.

- [ ] **Step 4: Implement in `Provisioner`**

`provision/4`: add `invite: session[:invite]` to the `build_create_opts` params map. `build_create_opts/1`:

```elixir
  def build_create_opts(params) do
    base = %{
      telegram_token: params[:token],
      model: params[:model] || Ruoc.default_model(),
      owner_telegram_id: params[:owner_id],
      language: params[:language] || "ru",
      mention_only: true,
      allow_all_telegram_users: false
    }

    case params[:invite] do
      code when is_binary(code) and code != "" -> Map.put(base, :invite, code)
      _ -> base
    end
  end
```

- [ ] **Step 5: Run the tests**

Run: `mix test apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs`
Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok/lib/druzhok/bot_manager.ex apps/druzhok/lib/druzhok/manager_bot/provisioner.ex apps/druzhok/test/druzhok/bot_manager_lifecycle_test.exs apps/druzhok/test/druzhok/manager_bot/provisioner_test.exs
git commit -m "bot create: redeem the invite through ruoc, admit the owner"
```

---

### Task 4: Onboarding: keyboard by bot count, invite step, texts

**Files:**
- Modify: `apps/druzhok/lib/druzhok/manager_bot/onboarding.ex`
- Test: `apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs`

**Interfaces:**
- Produces (all pure):
  ```elixir
  Onboarding.new_session/0                       # gains invite: nil
  Onboarding.menu_texts/0                        # every reply-keyboard label
  Onboarding.main_menu_keyboard(bot_count \\ 0)  # rows per the Global Constraints table
  Onboarding.ask_invite(session)                 # {session with step :invite, invite_prompt()}
  Onboarding.invite_prompt/0
  Onboarding.invite_status_message(:spent | :expired | :invalid | :error)
  Onboarding.begin_create(session, invite \\ nil) # {session with step :name, invite, "Как назовём бота?"}
  Onboarding.handle_input(%{step: :invite}, %{text: code}) # {:ok, session, {:check_invite, code}}; menu texts re-dispatch
  Onboarding.limit_message/0                     # one-bot wording
  Onboarding.create_race_message/0
  Onboarding.my_bot_message(bot)                 # {text, [[%{text: "💬 Написать", url}]]}
  Onboarding.referrals_messages(codes, manager_username) # [{text, rows}] to send in order
  Onboarding.after_delete_message/0              # "Можно создать нового бота."
  Onboarding.after_create_message/0              # "Управление ботом — в меню внизу."
  ```

- [ ] **Step 1: Write the failing tests**

Replace `describe "main_menu_keyboard/0"` in `onboarding_test.exs` with:

```elixir
  describe "main_menu_keyboard/1" do
    test "no bot: only create" do
      assert %{keyboard: [[%{text: "🤖 Создать бота"}]], resize_keyboard: true} = Onboarding.main_menu_keyboard(0)
      assert Onboarding.main_menu_keyboard() == Onboarding.main_menu_keyboard(0)
    end

    test "one bot: its controls, no create" do
      assert %{keyboard: [[%{text: "🤖 Мой бот"}, %{text: "🎨 Картинки"}], [%{text: "🎁 Пригласить"}, %{text: "🗑 Удалить"}]]} =
               Onboarding.main_menu_keyboard(1)
    end

    test "several bots (grandfathered): the list, no create" do
      assert %{keyboard: [[%{text: "📋 Мои боты"}]]} = Onboarding.main_menu_keyboard(2)
    end

    test "menu_texts covers every label" do
      for count <- [0, 1, 2], row <- Onboarding.main_menu_keyboard(count).keyboard, %{text: t} <- row do
        assert t in Onboarding.menu_texts()
      end
    end
  end

  describe "invite step" do
    test "ask_invite moves to :invite with the prompt" do
      {session, text} = Onboarding.ask_invite(Onboarding.new_session())
      assert session.step == :invite
      assert text == "Создание по приглашению. Введи код или открой ссылку от друга."
    end

    test "a typed code is handed back for checking" do
      {session, _} = Onboarding.ask_invite(Onboarding.new_session())
      assert {:ok, %{step: :invite}, {:check_invite, "ABCD-EFGH"}} = Onboarding.handle_input(session, %{text: "  ABCD-EFGH \n"})
    end

    test "menu buttons during the invite step are not codes" do
      {session, _} = Onboarding.ask_invite(Onboarding.new_session())
      assert {:ok, _, {:my_bots}} = Onboarding.handle_input(session, %{text: "📋 Мои боты"})
    end

    test "begin_create keeps the code on the session" do
      {session, text} = Onboarding.begin_create(Onboarding.new_session(), "ABCD-EFGH")
      assert session.step == :name
      assert session.invite == "ABCD-EFGH"
      assert text == "Как назовём бота?"
      assert {%{invite: nil}, _} = Onboarding.begin_create(Onboarding.new_session())
    end

    test "status messages" do
      assert Onboarding.invite_status_message(:spent) == "Этот код уже использован."
      assert Onboarding.invite_status_message(:expired) == "Срок этого кода истёк."
      assert Onboarding.invite_status_message(:invalid) == "Код не найден. Проверь ссылку или попроси новый."
      assert Onboarding.invite_status_message(:error) == "Не получилось проверить код, попробуй позже."
      assert Onboarding.create_race_message() == "Код успели использовать. Попроси новый и создай бота заново."
      assert Onboarding.limit_message() == "У тебя уже есть бот. Удали его, чтобы создать нового."
    end
  end

  describe "my_bot_message/1" do
    test "the bot line and a chat button" do
      bot = %{id: 7, name: "Кот", active: true, trigger_name: "kot_bot", ruoc_balance_rub: "1.00", ruoc_subscription: nil}
      {text, [[open]]} = Onboarding.my_bot_message(bot)
      assert text == "🟢 *Кот* — баланс 1.00 ₽"
      assert open == %{text: "💬 Написать", url: "https://t.me/kot_bot"}
    end
  end

  describe "referrals_messages/2" do
    test "an available code becomes a link with a share button; redeemed ones are listed" do
      codes = [
        %{code: "AAAA-BBBB", status: "available", redeemed_at: nil, friend_rub: "0.00", you_rub: "0.00"},
        %{code: "CCCC-DDDD", status: "redeemed", redeemed_at: ~U[2026-10-05 09:00:00Z], friend_rub: "0.00", you_rub: "0.00"}
      ]

      [{intro, []}, {share, [[button]]}, {used, []}] = Onboarding.referrals_messages(codes, "druzhoksuperbot")
      assert intro == "Пригласи друга — по этой ссылке он сможет создать своего бота:"
      assert share == "https://t.me/druzhoksuperbot?start=ref_AAAA-BBBB"
      assert button.text == "Поделиться"
      assert button.url =~ "https://t.me/share/url?url=https%3A%2F%2Ft.me%2Fdruzhoksuperbot%3Fstart%3Dref_AAAA-BBBB&text="
      assert used == "Использован 5 окт"
    end

    test "a bonus is mentioned in the share caption" do
      codes = [%{code: "AAAA-BBBB", status: "available", redeemed_at: nil, friend_rub: "0.00", you_rub: "20.00"}]
      [_, {_, [[button]]}] = Onboarding.referrals_messages(codes, "b")
      assert URI.decode_www_form(button.url) =~ "20.00"
    end

    test "no codes" do
      assert [{"У тебя пока нет приглашений.", []}] = Onboarding.referrals_messages([], "b")
    end

    test "only redeemed codes: no intro, just the list" do
      codes = [%{code: "C", status: "redeemed", redeemed_at: ~U[2026-10-05 09:00:00Z], friend_rub: "0.00", you_rub: "0.00"}]
      assert [{"Использован 5 окт", []}] = Onboarding.referrals_messages(codes, "b")
    end
  end
```

Also update the existing test "create bot button moves to :name step" if it checks the returned text (it stays "Как назовём бота?").

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs`
Expected: failures for every new function.

- [ ] **Step 3: Implement**

In `onboarding.ex`:

Session:

```elixir
  def new_session do
    %{
      step: :idle,
      name: nil,
      language: nil,
      username: nil,
      # The code the person came in with, until ruoc has redeemed it.
      invite: nil,
      message_id: nil,
      started_at: System.system_time(:second)
    }
  end
```

Menu:

```elixir
  @create "🤖 Создать бота"
  @my_bots "📋 Мои боты"
  @my_bot "🤖 Мой бот"
  @pictures "🎨 Картинки"
  @invite "🎁 Пригласить"
  @delete "🗑 Удалить"

  @doc "Every label the reply keyboard can carry; none of them is ever a bot name or a code."
  def menu_texts, do: [@create, @my_bots, @my_bot, @pictures, @invite, @delete]

  @doc """
  The reply keyboard for a person with `bot_count` bots. One bot is the rule;
  the create button exists only until it is used, and a person with several
  (only possible from before the rule) keeps the old list.
  """
  def main_menu_keyboard(bot_count \\ 0) do
    rows =
      case bot_count do
        0 -> [[%{text: @create}]]
        1 -> [[%{text: @my_bot}, %{text: @pictures}], [%{text: @invite}, %{text: @delete}]]
        _ -> [[%{text: @my_bots}]]
      end

    %{keyboard: rows, resize_keyboard: true, one_time_keyboard: false}
  end
```

Replace the `"🤖 Создать бота"` / `"📋 Мои боты"` literals in `handle_input` and the `:name` step guard with the attributes, and the `:name` step's `name in [...]` check with `name in menu_texts()`.

Invite step, after the `@my_bots` clause:

```elixir
  # Invite step: the person has no admission; whatever they type is a code
  # for ManagerBot to check with ruoc. Menu buttons keep working.
  def handle_input(%{step: :invite} = session, %{text: text}) do
    code = String.trim(text || "")

    cond do
      code in menu_texts() -> handle_input(new_session(), %{text: code})
      code == "" -> {:retry, session, {:text, invite_prompt()}}
      true -> {:ok, session, {:check_invite, code}}
    end
  end

  def handle_input(%{step: :invite} = session, _input), do: {:retry, session, {:text, invite_prompt()}}

  @doc "Put the session at the invite step; ManagerBot sends the prompt."
  def ask_invite(session), do: {%{session | step: :invite, started_at: System.system_time(:second)}, invite_prompt()}

  def invite_prompt, do: "Создание по приглашению. Введи код или открой ссылку от друга."

  def invite_status_message(:spent), do: "Этот код уже использован."
  def invite_status_message(:expired), do: "Срок этого кода истёк."
  def invite_status_message(:invalid), do: "Код не найден. Проверь ссылку или попроси новый."
  def invite_status_message(_), do: "Не получилось проверить код, попробуй позже."

  @doc "Start naming the bot, carrying the (checked) code to provisioning."
  def begin_create(session, invite \\ nil) do
    {%{session | step: :name, invite: invite, started_at: System.system_time(:second)}, "Как назовём бота?"}
  end

  def create_race_message, do: "Код успели использовать. Попроси новый и создай бота заново."
  def after_create_message, do: "Управление ботом — в меню внизу."
  def after_delete_message, do: "Можно создать нового бота."
```

Make the `:idle | :done` create clause use `begin_create/1`:

```elixir
  def handle_input(%{step: step} = session, %{text: @create}) when step in [:idle, :done] do
    {session, text} = begin_create(session, session.invite)
    {:ok, session, {:text, text}}
  end
```

Limit and cards:

```elixir
  def limit_message, do: "У тебя уже есть бот. Удали его, чтобы создать нового."

  @doc "The one-bot card: the bot line and a button into its chat."
  def my_bot_message(bot) do
    {bot_line(bot), [[%{text: "💬 Написать", url: "https://t.me/#{bot_handle(bot)}"}]]}
  end

  @doc """
  What «🎁 Пригласить» sends, in order: an intro, one message per available
  code with its deep link and a share button, then one message listing the
  redeemed codes. `codes` is `Druzhok.Ruoc.referrals/1`'s list.
  """
  def referrals_messages(codes, manager_username) do
    available = Enum.filter(codes, &(&1.status == "available" and is_binary(&1.code)))
    redeemed = Enum.filter(codes, &(&1.status == "redeemed"))

    shares =
      Enum.map(available, fn c ->
        link = "https://t.me/#{manager_username}?start=ref_#{c.code}"

        caption =
          if c.you_rub != "0.00",
            do: "Создай своего AI-бота по моей ссылке — мне за это начислят #{c.you_rub} ₽",
            else: "Создай своего AI-бота по моей ссылке"

        share = "https://t.me/share/url?url=#{URI.encode_www_form(link)}&text=#{URI.encode_www_form(caption)}"
        {link, [[%{text: "Поделиться", url: share}]]}
      end)

    intro = if shares == [], do: [], else: [{"Пригласи друга — по этой ссылке он сможет создать своего бота:", []}]

    used =
      case redeemed do
        [] -> []
        list -> [{Enum.map_join(list, "\n", &("Использован " <> short_date(&1.redeemed_at))), []}]
      end

    case intro ++ shares ++ used do
      [] -> [{"У тебя пока нет приглашений.", []}]
      messages -> messages
    end
  end
```

`short_date/1` expects a `DateTime`; a redeemed code without one is not possible from the gateway, but guard anyway: `&("Использован " <> if(&1.redeemed_at, do: short_date(&1.redeemed_at), else: ""))` and `String.trim/1` the line.

- [ ] **Step 4: Run the tests**

Run: `mix test apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs`
Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add apps/druzhok/lib/druzhok/manager_bot/onboarding.ex apps/druzhok/test/druzhok/manager_bot/onboarding_test.exs
git commit -m "onboarding: invite step, one-bot keyboard, invite messages"
```

---

### Task 5: ManagerBot: gating, `/start` payload, one-bot menu

**Files:**
- Modify: `apps/druzhok/lib/druzhok/manager_bot.ex`
- Test: `apps/druzhok/test/druzhok/manager_bot_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1–4.
- Produces: the behaviour in the spec. Internal helpers: `admitted?(user_id)`, `operator?(user_id)`, `user_bots(user_id)`, `send_menu(state, chat_id, user_id, text)`, `handle_check_invite(state, user_id, chat_id, session, code)`.

- [ ] **Step 1: Update and add tests**

In `manager_bot_test.exs`:

1. Add `@stranger 4343` and, in `setup`, admit the owner so the existing create-flow tests keep working under the gate:

```elixir
    Druzhok.Admissions.admit(@owner, "test")
    on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id in [@owner, @stranger])) end)
```

2. Change the `/start` test's keyboard assertion to `[[%{"text" => "🤖 Создать бота"}]]` and rename it "…the create-only reply keyboard".

3. In "managed_bot update provisions a bot for the creator", after the "создан и запущен" edit, assert the keyboard message:

```elixir
    menu = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Управление ботом — в меню внизу."), 5_000)
    assert Jason.decode!(menu["reply_markup"])["keyboard"] == [[%{"text" => "🤖 Мой бот"}, %{"text" => "🎨 Картинки"}], [%{"text" => "🎁 Пригласить"}, %{"text" => "🗑 Удалить"}]]
```

4. Rename `describe "with two existing bots"` → `"with two existing bots (grandfathered)"`, change "creating a third is refused" to assert `"уже есть бот"`, and add:

```elixir
    test "the keyboard is the list, and the list still works", %{stub: stub} do
      TelegramStub.push_update(stub, message("/start"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
      assert Jason.decode!(params["reply_markup"])["keyboard"] == [[%{"text" => "📋 Мои боты"}]]
    end
```

5. New describe:

```elixir
  describe "with one bot" do
    setup %{data_root: root} do
      ruoc = Druzhok.RuocStub.start()

      inst =
        %Instance{}
        |> Instance.changeset(%{
          name: "solo", model: "m", workspace: Path.join([root, "solo", "workspace"]), tenant_key: "dk-solo",
          owner_telegram_id: @owner, trigger_name: "solo_bot", ruoc_api_key: "ruoc_solo"
        })
        |> Repo.insert!()

      on_exit(fn -> Repo.delete_all(from(i in Instance, where: i.name == "solo")) end)
      %{ruoc: ruoc, inst: inst}
    end

    test "/start shows the bot's controls and no create button", %{stub: stub} do
      TelegramStub.push_update(stub, message("/start"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
      assert Jason.decode!(params["reply_markup"])["keyboard"] ==
               [[%{"text" => "🤖 Мой бот"}, %{"text" => "🎨 Картинки"}], [%{"text" => "🎁 Пригласить"}, %{"text" => "🗑 Удалить"}]]
    end

    test "create is refused with the one-bot message", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "У тебя уже есть бот. Удали его, чтобы создать нового."))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "Мой бот is the card with balance and a chat button", %{stub: stub} do
      TelegramStub.push_update(stub, message("🤖 Мой бот"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "*solo*"))
      assert params["text"] == "🟢 *solo* — баланс 12.50 ₽"
      [[open]] = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert open["url"] == "https://t.me/solo_bot"
    end

    test "Картинки opens the picture menu for the bot directly", %{stub: stub, inst: inst} do
      TelegramStub.push_update(stub, message("🎨 Картинки"))
      params = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Картинки для @solo_bot"))
      rows = Jason.decode!(params["reply_markup"])["inline_keyboard"]
      assert Enum.any?(List.flatten(rows), &(&1["callback_data"] == "imgoff:#{inst.id}"))

      # «Назад» from there is the card, not a list.
      TelegramStub.push_update(stub, callback("imgback"))
      assert TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "*solo*"))
    end

    test "Удалить asks, deletes, and hands back the create keyboard", %{stub: stub, inst: inst} do
      cleanup_instance("solo")
      TelegramStub.push_update(stub, message("🗑 Удалить"))
      ask = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Точно удалить @solo_bot"))
      [[yes, _no]] = Jason.decode!(ask["reply_markup"])["inline_keyboard"]
      assert yes["callback_data"] == "delyes:#{inst.id}"

      TelegramStub.push_update(stub, callback("delyes:#{inst.id}"))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "✅ Бот @solo_bot удалён."), 10_000)
      menu = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Можно создать нового бота."), 5_000)
      assert Jason.decode!(menu["reply_markup"])["keyboard"] == [[%{"text" => "🤖 Создать бота"}]]
      assert Repo.get(Instance, inst.id) == nil

      # Admitted before, so a new bot needs no code.
      TelegramStub.push_update(stub, message("🤖 Создать бота"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?"))
    end

    test "Пригласить lists the codes from ruoc with share buttons", %{stub: stub} do
      TelegramStub.push_update(stub, message("🎁 Пригласить"))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Пригласи друга"))
      share = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "https://t.me/test_manager_bot?start=ref_AAAA-BBBB"))
      [[button]] = Jason.decode!(share["reply_markup"])["inline_keyboard"]
      assert button["text"] == "Поделиться"
      assert button["url"] =~ "https://t.me/share/url?url="
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Использован 5 окт"))
    end

    test "Пригласить when ruoc fails", %{stub: stub, ruoc: ruoc} do
      Bypass.down(ruoc.bypass)
      TelegramStub.push_update(stub, message("🎁 Пригласить"))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Не получилось загрузить приглашения, попробуй позже."))
    end
  end

  describe "invite gate" do
    setup do
      %{ruoc: Druzhok.RuocStub.start()}
    end

    test "a stranger pressing create is asked for a code, and a good code starts naming", %{stub: stub, ruoc: ruoc} do
      TelegramStub.push_update(stub, message("🤖 Создать бота", @stranger))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Создание по приглашению. Введи код или открой ссылку от друга."))

      TelegramStub.push_update(stub, message("ABCD-EFGH", @stranger))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == @stranger))
      [call] = Druzhok.RuocStub.calls(ruoc, "GET /admin/invites/check")
      assert call.path == "/admin/invites/check"
    end

    test "a spent code is refused and the menu returns", %{stub: stub, ruoc: ruoc} do
      Bypass.stub(ruoc.bypass, "GET", "/admin/invites/check", fn conn ->
        Druzhok.RuocStub.reply(conn, 200, %{"status" => "spent"})
      end)

      TelegramStub.push_update(stub, message("🤖 Создать бота", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "по приглашению"))
      TelegramStub.push_update(stub, message("ABCD-EFGH", @stranger))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Этот код уже использован."))
      refute "Как назовём бота?" in sent_texts(stub)
    end

    test "a deep link with a good code goes straight to naming", %{stub: stub} do
      TelegramStub.push_update(stub, message("/start ref_ABCD-EFGH", @stranger))
      welcome = TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет" and &1["chat_id"] == @stranger))
      assert Jason.decode!(welcome["reply_markup"])["keyboard"] == [[%{"text" => "🤖 Создать бота"}]]
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == @stranger))
    end

    test "a deep link from an admitted person is just /start", %{stub: stub, ruoc: ruoc} do
      TelegramStub.push_update(stub, message("/start ref_ABCD-EFGH"))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] =~ "Привет"))
      Process.sleep(50)
      refute "Как назовём бота?" in sent_texts(stub)
      assert Druzhok.RuocStub.calls(ruoc, "GET /admin/invites/check") == []
    end

    test "the code reaches ruoc at creation, and a race is reported", %{stub: stub, ruoc: ruoc} do
      TelegramStub.set_managed_bot_token(stub, "558NEWBOT")
      cleanup_instance("gost_0001")

      TelegramStub.push_update(stub, message("/start ref_ABCD-EFGH", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == @stranger))
      TelegramStub.push_update(stub, message("Гость", @stranger))
      TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Язык:" and &1["chat_id"] == @stranger))
      TelegramStub.push_update(stub, callback("lang:ru", @stranger))
      TelegramStub.await_call(stub, "editMessageText", &(&1["text"] =~ "Гость"))

      Bypass.expect_once(ruoc.bypass, "POST", "/admin/accounts", fn conn ->
        Druzhok.RuocStub.reply(conn, 409, %{"error" => %{"type" => "invite_spent", "message" => "used"}})
      end)

      TelegramStub.push_update(stub, managed_bot_update(558, "gost_0001_bot", @stranger))
      assert TelegramStub.await_call(stub, "editMessageText", &(&1["text"] == "Код успели использовать. Попроси новый и создай бота заново."), 10_000)
      assert Repo.get_by(Instance, name: "gost_0001") == nil
      refute Druzhok.Admissions.admitted?(@stranger)
    end

    test "the operator creates without a code", %{stub: stub} do
      Druzhok.Settings.set("operator_telegram_id", "777")
      on_exit(fn -> Druzhok.Settings.set("operator_telegram_id", "") end)
      TelegramStub.push_update(stub, message("🤖 Создать бота", 777))
      assert TelegramStub.await_call(stub, "sendMessage", &(&1["text"] == "Как назовём бота?" and &1["chat_id"] == 777))
    end
  end
```

The `RuocStub` in "with one bot" makes `Druzhok.Ruoc.configured?()` true, so `BotManager` calls the stubbed `POST /admin/accounts` during the recreate at the end of the delete test; that is fine.

- [ ] **Step 2: Run them to verify they fail**

Run: `mix test apps/druzhok/test/druzhok/manager_bot_test.exs`
Expected: the new and changed tests fail; the old ones still pass except the `/start` keyboard.

- [ ] **Step 3: Implement**

In `manager_bot.ex`:

`@max_bots_per_user 1`. Add `alias Druzhok.{Admissions, Settings}` to the alias line.

Message routing:

```elixir
  defp process_update(%{"message" => msg}, state) do
    user_id = get_in(msg, ["from", "id"])
    chat_id = msg["chat"]["id"]
    text = msg["text"] || ""

    cond do
      text == "/start" ->
        show_main_menu(state, user_id, chat_id)

      String.starts_with?(text, "/start ref_") ->
        handle_start_ref(state, user_id, chat_id, String.trim_leading(text, "/start ref_") |> String.trim())

      String.starts_with?(text, "/start") ->
        show_main_menu(state, user_id, chat_id)

      text in Onboarding.menu_texts() ->
        handle_menu(state, user_id, chat_id, text)

      Map.has_key?(state.sessions, user_id) and
          state.sessions[user_id].step in [:name, :language, :confirm, :invite] ->
        dispatch_input(state, user_id, chat_id, %{text: text})

      true ->
        show_main_menu(state, user_id, chat_id)
    end
  end
```

Menu and keyboard:

```elixir
  # --- Main menu ---

  defp show_main_menu(state, user_id, chat_id) do
    send_menu(state, chat_id, user_id, Onboarding.welcome_message())
    put_in(state, [:sessions, user_id], Onboarding.new_session())
  end

  # Any message that should also (re)place the reply keyboard. The keyboard is
  # computed from the bot count every time, never cached: creation and
  # deletion change it, and both happen in tasks after this GenServer replied.
  defp send_menu(state, chat_id, user_id, text) do
    menu = Onboarding.main_menu_keyboard(user_bot_count(user_id))
    API.send_message(state.token, chat_id, text, %{reply_markup: Jason.encode!(menu)})
  end

  defp handle_menu(state, user_id, chat_id, "🤖 Создать бота"), do: dispatch_input(state, user_id, chat_id, %{text: "🤖 Создать бота"})
  defp handle_menu(state, user_id, chat_id, "📋 Мои боты"), do: dispatch_input(state, user_id, chat_id, %{text: "📋 Мои боты"})

  defp handle_menu(state, user_id, chat_id, text) do
    case user_bots(user_id) do
      [bot] -> one_bot_menu(state, user_id, chat_id, bot, text)
      # The keyboard on their screen is stale (bot deleted or a second one
      # appeared); the fresh one comes with the menu.
      _ -> show_main_menu(state, user_id, chat_id)
    end
  end

  defp one_bot_menu(state, _user_id, chat_id, bot, "🤖 Мой бот") do
    {text, rows} = Onboarding.my_bot_message(with_balance(bot))
    send_url_keyboard(state.token, chat_id, text, rows)
    state
  end

  defp one_bot_menu(state, _user_id, chat_id, bot, "🎨 Картинки") do
    {text, rows} = Onboarding.image_menu(Map.from_struct(bot), Druzhok.Ruoc.image_models())
    send_inline(state.token, chat_id, text, rows)
    state
  end

  defp one_bot_menu(state, _user_id, chat_id, bot, "🗑 Удалить") do
    {text, rows} = Onboarding.delete_confirm(bot.id, bot_display_handle(bot))
    send_inline(state.token, chat_id, text, rows)
    state
  end

  defp one_bot_menu(state, _user_id, chat_id, bot, "🎁 Пригласить") do
    case bot.ruoc_api_key && Druzhok.Ruoc.referrals(bot.ruoc_api_key) do
      {:ok, codes} ->
        for {text, rows} <- Onboarding.referrals_messages(codes, state.bot_username) do
          if rows == [],
            do: API.send_message(state.token, chat_id, text),
            else: send_url_keyboard(state.token, chat_id, text, rows)
        end

      _ ->
        API.send_message(state.token, chat_id, "Не получилось загрузить приглашения, попробуй позже.")
    end

    state
  end

  defp user_bots(user_id) do
    import Ecto.Query
    Repo.all(from(i in Instance, where: i.owner_telegram_id == ^user_id, order_by: [desc: i.active, asc: i.name]))
  end

  defp with_balance(inst) do
    {balance, subscription} =
      case inst.ruoc_api_key && Druzhok.Ruoc.balance(inst.ruoc_api_key) do
        {:ok, %{balance_rub: rub, subscription: sub}} -> {rub, sub}
        _ -> {nil, nil}
      end

    inst |> Map.from_struct() |> Map.put(:ruoc_balance_rub, balance) |> Map.put(:ruoc_subscription, subscription)
  end
```

Rewrite `my_bots_payload/1` to `user_bots(user_id) |> Enum.map(&with_balance/1) |> Onboarding.my_bots_message()`.

The `send_url_keyboard` helper sends `parse_mode: "Markdown"`; the share link text contains `_` (`start=ref_…`), which Markdown would eat. For the invite messages send the link with no parse mode: add a `send_url_keyboard_plain/4` identical to `send_url_keyboard/4` without `parse_mode`, and use it in the `"🎁 Пригласить"` clause.

Gating in `dispatch_input`:

```elixir
  defp dispatch_input(state, user_id, chat_id, input) do
    session = state.sessions[user_id] || Onboarding.new_session()

    cond do
      input == %{text: "🤖 Создать бота"} and user_bot_count(user_id) >= @max_bots_per_user ->
        API.send_message(state.token, chat_id, Onboarding.limit_message())
        state

      input == %{text: "🤖 Создать бота"} and not may_create?(user_id, session) ->
        {session, prompt} = Onboarding.ask_invite(session)
        API.send_message(state.token, chat_id, prompt)
        put_in(state, [:sessions, user_id], session)

      true ->
        case Onboarding.handle_input(session, input) do
          {_status, session, {:check_invite, code}} ->
            handle_check_invite(state, user_id, chat_id, session, code)

          … (existing clauses unchanged) …
        end
    end
  end

  # Admitted people, the operator, and a session already holding a checked
  # code (the deep link path) skip the prompt.
  defp may_create?(user_id, session) do
    is_binary(session[:invite]) or operator?(user_id) or Admissions.admitted?(user_id)
  end

  defp operator?(user_id) do
    case Settings.operator_telegram_id() do
      nil -> false
      id -> to_string(id) == to_string(user_id)
    end
  end

  defp handle_check_invite(state, user_id, chat_id, session, code) do
    case Druzhok.Ruoc.check_invite(code) do
      {:ok, :available} ->
        {session, text} = Onboarding.begin_create(session, code)
        API.send_message(state.token, chat_id, text)
        put_in(state, [:sessions, user_id], session)

      {:ok, status} ->
        API.send_message(state.token, chat_id, Onboarding.invite_status_message(status))
        put_in(state, [:sessions, user_id], Onboarding.new_session())

      {:error, reason} ->
        Logger.warning("invite check failed for #{user_id}: #{reason}")
        API.send_message(state.token, chat_id, Onboarding.invite_status_message(:error))
        put_in(state, [:sessions, user_id], Onboarding.new_session())
    end
  end

  # /start ref_<code>: the welcome and keyboard first, as any /start, then —
  # for somebody not yet admitted — the code is checked and naming begins.
  defp handle_start_ref(state, user_id, chat_id, code) do
    state = show_main_menu(state, user_id, chat_id)

    if code == "" or may_create?(user_id, %{}) or user_bot_count(user_id) >= @max_bots_per_user do
      state
    else
      handle_check_invite(state, user_id, chat_id, Onboarding.new_session(), code)
    end
  end
```

`imgback` for a single-bot owner edits into the card:

```elixir
          data == "imgback" ->
            case user_bots(user_id) do
              [bot] ->
                {text, rows} = Onboarding.my_bot_message(with_balance(bot))
                edit_url_keyboard(state.token, chat_id, message_id, text, rows)

              _ ->
                edit_my_bots(state, user_id, chat_id, message_id)
            end

            state
```

After deletion, in `handle_delete_confirm`'s task, on `:ok`:

```elixir
              :ok ->
                edit_plain(token, chat_id, message_id, Onboarding.delete_done(handle))
                menu = Onboarding.main_menu_keyboard(user_bot_count(user_id))
                API.send_message(token, chat_id, Onboarding.after_delete_message(), %{reply_markup: Jason.encode!(menu)})
```

(`user_id` is in scope of `handle_delete_confirm`; capture it before the `Task.start`.)

After creation, in `handle_managed_bot`'s task, on `{:ok, _name, username}` keep the completion edit and then:

```elixir
      case result do
        {:ok, _name, _username} ->
          menu = Onboarding.main_menu_keyboard(user_bot_count(creator_id))
          API.send_message(token, creator_id, Onboarding.after_create_message(), %{reply_markup: Jason.encode!(menu)})

        _ ->
          :ok
      end
```

Restructure the task body so `result` is the `Provisioner.provision` return (or `{:error, :crashed}` from the rescue) and `text` is derived from it; map the invite race:

```elixir
            {:error, {:invite, _}} -> Onboarding.create_race_message()
            {:error, reason} -> "Ошибка создания бота: #{inspect(reason)}\nПопробуй ещё раз."
```

Order matters: `finish_progress(progress, token, creator_id, text)` first, then the menu message, so the test's "создан и запущен" edit lands before the keyboard message.

- [ ] **Step 4: Run the manager bot tests**

Run: `mix test apps/druzhok/test/druzhok/manager_bot_test.exs`
Expected: 0 failures. If "Пригласить lists the codes" fails on the link text, check that the plain sender (no `parse_mode`) is used for those messages.

- [ ] **Step 5: Full suite**

Run: `mix test`
Expected: 0 failures in both apps; coverage thresholds hold (`mix test --cover`).

- [ ] **Step 6: Commit**

```bash
git add apps/druzhok/lib/druzhok/manager_bot.ex apps/druzhok/test/druzhok/manager_bot_test.exs
git commit -m "superbot: invite gate, one bot per person, bot controls in the menu"
```

---

### Task 6: Docs and memory

**Files:**
- Modify: `CLAUDE.md` (Proxy/ruoc paragraph: one line on admissions and referral codes)
- Modify: `docs/superpowers/specs/2026-09-19-referral-invites-design.md` only if implementation diverged

- [ ] **Step 1: CLAUDE.md**

Add to the ruoc-gateway settings paragraph:

```
The superbot is invite-only: `admissions` (`Druzhok.Admissions`) records who may create a bot, written when ruoc accepted their code (`POST /admin/accounts` with `invite`); the operator issues referral codes to a bot's account from the ruoc console account page, and «🎁 Пригласить» reads them via `GET /v1/referrals`. One bot per person (`@max_bots_per_user 1`). Spec: `docs/superpowers/specs/2026-09-19-referral-invites-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: invite-only superbot"
```

---

### Task 7: Deploy and verify

Prerequisite: ruoc-gateway's plan is deployed, the policy is set (0 / 0 / 30 days / 0) and one code was issued to the operator's bot account (its Task 8).

- [ ] **Step 1: Ship**

```bash
rsync -az --delete --exclude=_build --exclude=deps apps config ops mix.exs mix.lock .tool-versions ubuntu@195.49.213.8:~/druzhok/
ssh ubuntu@195.49.213.8 'cd ~/druzhok && sudo ops/druzhok-run.sh "IO.puts(:compiled)"'
ssh ubuntu@195.49.213.8 'cd ~/druzhok && . ~/.asdf/asdf.sh && set -a && . /etc/druzhok/druzhok.env && set +a && MIX_ENV=prod mix ecto.migrate'
ssh ubuntu@195.49.213.8 'sudo systemctl restart druzhok && sleep 3 && systemctl is-active druzhok'
```

(The middle line sources the env file on the server itself, as CLAUDE.md prescribes for migrations; do not print the file.)

- [ ] **Step 2: Grandfathering**

```bash
ssh ubuntu@195.49.213.8 'cd ~/druzhok && sudo ops/druzhok-run.sh "import Ecto.Query; IO.inspect({Druzhok.Repo.aggregate(from(a in \"admissions\"), :count), Druzhok.Repo.aggregate(from(i in Druzhok.Instance, where: not is_nil(i.owner_telegram_id), select: i.owner_telegram_id, distinct: true), :count)})"' 2>&1 | grep -E "^\{"
```

Expected: both numbers equal.

- [ ] **Step 3: End to end**

1. From the operator's Telegram: `/start` in the superbot shows the bot controls (or «📋 Мои боты» if the operator owns two). «🎁 Пригласить» shows the issued code as a link with a share button.
2. From a second Telegram account: open the link, see "Привет…" with the create keyboard and then "Как назовём бота?", name it, pick a language, create through the newbot link, watch it provision, then see the four-button keyboard.
3. In the ruoc console the code's row reads redeemed; the new bot's account exists with the `druzhok:<name> tg:<id>` label. In druzhok `admissions` has the new id with the code's first four characters.
4. From a third account without a code: «🤖 Создать бота» answers the invite prompt; typing `nope` answers "Код не найден…".

Report each step's outcome in the final message, including anything that did not match.

---

## Self-review

- Spec coverage: admissions + grandfathering (Task 1), ruoc contract (Task 2), redeem/admit at creation with 409 handling (Task 3), deep link and typed code, statuses, one-bot keyboard, «Мой бот» / «Картинки» / «Удалить» / «Пригласить», operator exemption, 2+ list (Tasks 4–5), rollout (Task 7). Session TTL: a session at `:invite` or `:name` expires with the existing cleanup, after which `may_create?` asks again — no extra code.
- Placeholders: none.
- Naming: `Admissions.admitted?/1`, `admit/2`; `Ruoc.create_account/2` (keyword opts), `check_invite/1`, `referrals/1`; `Onboarding.main_menu_keyboard/1`, `menu_texts/0`, `ask_invite/1`, `begin_create/2`, `invite_status_message/1`, `my_bot_message/1`, `referrals_messages/2`, `after_create_message/0`, `after_delete_message/0`, `create_race_message/0`; `ManagerBot` helpers `handle_menu/4`, `one_bot_menu/5`, `handle_check_invite/5`, `handle_start_ref/4`, `may_create?/2`, `operator?/1`, `user_bots/1`, `with_balance/1`, `send_menu/4` — consistent across tasks.
