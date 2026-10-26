import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :druzhok_web, DruzhokWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "dk6+68Q+SfukfdlWipXSF22+INXhmiKB/luzWJ3q57M7Ckfa6I4XYV6RWiFO2deE",
  server: false

# Use a separate test database
config :druzhok, Druzhok.Repo,
  database: Path.expand("../data/druzhok_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Lifecycle controller timings scaled down for tests (sleep/wake spec).
config :druzhok,
  lifecycle: [
    tick_ms: 50,
    unit_poll_ms: 0,
    idle_check_ms: 0,
    quiet_check_ms: 0,
    backoff_ms: [300, 600]
  ],
  lifecycle_wait_poll_ms: 20,
  lifecycle_wait_ms: 15_000,
  lifecycle_typing: [every_ms: 50, for_ms: 2_000]

config :druzhok,
  hermes_bin: Path.expand("../apps/druzhok/test/support/fake_hermes.sh", __DIR__),
  fetch_worker_bin: System.get_env("FETCH_WORKER_BIN") || Path.expand("../.fetch-venv/bin/python", __DIR__)

# Telegram.Addressed learns a bot's @username from getMe; tests set it per token.
config :druzhok, :telegram_username_fun, {Druzhok.TestUsernames, :lookup}
config :druzhok, :panel_get_me, {Druzhok.TestUsernames, :get_me}
config :druzhok, :display_name_backfill, false
