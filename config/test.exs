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

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :druzhok,
  nebius_api_url: "https://api.tokenfactory.us-central1.nebius.com/v1",
  openrouter_api_url: "https://openrouter.ai/api/v1",
  anthropic_api_url: "https://api.anthropic.com"

# Lifecycle controller timings scaled down for tests (sleep/wake spec).
config :druzhok,
  lifecycle: [tick_ms: 50, unit_poll_ms: 0, idle_check_ms: 0, backoff_ms: [300, 600]],
  lifecycle_wait_poll_ms: 20,
  lifecycle_wait_ms: 15_000,
  lifecycle_typing: [every_ms: 50, for_ms: 2_000]

config :druzhok,
  hermes_bin: Path.expand("../apps/druzhok/test/support/fake_hermes.sh", __DIR__),
  fetch_worker_bin: System.get_env("FETCH_WORKER_BIN") || Path.expand("../.fetch-venv/bin/python", __DIR__)
