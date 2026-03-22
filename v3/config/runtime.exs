import Config

config :pi_core,
  api_key: System.get_env("NEBIUS_API_KEY"),
  api_url: System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1"
