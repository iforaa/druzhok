defmodule Druzhok.Repo.Migrations.SeedHonchoSystemTenant do
  @moduledoc """
  Seeds the `honcho-system` synthetic instance row used to authenticate
  Honcho's deriver/dialectic LLM calls through druzhok's proxy.

  - `bot_runtime: "system"` keeps it out of BotManager's hermes restart loop.
  - `daily_budget_cents: 0` makes Budget.check/1 return :unlimited so
    Honcho's background extraction is never gated.
  - `active: 0` (false) so the dashboard / process supervision skips it.
  - The `tenant_key` is what Phase 3 pastes into ~/honcho/.env as
    HONCHO_PROXY_API_KEY.
  """

  use Ecto.Migration

  def up do
    tenant_key =
      :crypto.strong_rand_bytes(8)
      |> Base.url_encode64(padding: false)
      |> then(&"dk-honcho-system-#{&1}")

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    execute("""
    INSERT OR IGNORE INTO instances (
      name, telegram_token, model, workspace, active, heartbeat_interval,
      sandbox, timezone, language, bot_runtime, daily_budget_cents,
      tenant_key, memory_provider, inserted_at, updated_at
    ) VALUES (
      'honcho-system', '', 'system', '/opt/data', 0, 0,
      'local', 'UTC', 'en', 'system', 0,
      '#{tenant_key}', 'builtin', '#{now}', '#{now}'
    )
    """)
  end

  def down do
    execute("DELETE FROM instances WHERE name = 'honcho-system'")
  end
end
