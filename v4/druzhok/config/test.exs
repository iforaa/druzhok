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
