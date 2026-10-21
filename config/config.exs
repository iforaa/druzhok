# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Configures the endpoint
config :druzhok_web, DruzhokWebWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: DruzhokWebWeb.ErrorJSON], layout: false]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Timezone database (DateTime.shift_zone!, e.g. ManagerBot.Onboarding renewal dates)
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :druzhok, Druzhok.Repo,
  database: System.get_env("DATABASE_PATH") || Path.expand("../data/druzhok.db", __DIR__)

config :druzhok,
  ecto_repos: [Druzhok.Repo],
  host: Druzhok.Host.Process,
  data_root_default: Path.expand("../../data/tenants", __DIR__),
  hermes_bin: "hermes",
  # Python for the fetch worker (priv/fetch-worker); nil disables page reading.
  fetch_worker_bin: nil

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
