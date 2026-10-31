import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/druzhok_web start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :druzhok_web, DruzhokWebWeb.Endpoint, server: true
end

if config_env() == :prod do
  config :druzhok, data_root_default: "/data/tenants"

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :druzhok_web, DruzhokWebWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Loopback only: Caddy terminates TLS and proxies in; bots reach the
      # LLM proxy at 127.0.0.1:4000. Override with PHX_BIND_ALL=1 if needed.
      ip: (if System.get_env("PHX_BIND_ALL") == "1", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
      port: port,
      # A `Connection: close` client (python urllib, which Mnemosyne uses) lost
      # the tail of large responses on Linux: Bandit closes right after the
      # send and the inet driver dropped what was still queued (~100 KB of a
      # 500 KB embeddings reply). linger makes close flush the queue first.
      thousand_island_options: [transport_options: [linger: {true, 30}]]
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :druzhok_web, DruzhokWebWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :druzhok_web, DruzhokWebWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Upstreams the LLM proxy calls (not bots)
# Empty env vars (e.g. `RUOC_URL=` in an EnvironmentFile) must
# behave like unset so the Settings row (`ops/druzhok settings`) is used instead.
env_or_nil = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    v -> v
  end
end

config :druzhok,
  openai_api_url: System.get_env("OPENAI_API_URL") || "https://api.openai.com/v1",
  ruoc_url: env_or_nil.("RUOC_URL"),
  # The partner token comes from the env only; it never has a settings row.
  ruoc_partner_token: env_or_nil.("RUOC_PARTNER_TOKEN"),
  ruoc_catalog_key: env_or_nil.("RUOC_CATALOG_KEY"),
  fetch_secret: env_or_nil.("FETCH_SECRET"),
  # The bot panel: Caddy's edge header secret (env only, never a settings
  # row), ruoc's public origin for the Счёт tab, init data lifetime.
  edge_secret: env_or_nil.("DRUZHOK_EDGE_SECRET"),
  ruoc_site_url: env_or_nil.("RUOC_SITE_URL"),
  panel_init_max_age: String.to_integer(System.get_env("PANEL_INIT_MAX_AGE") || "86400"),
  # GNU find for the panel's listings (`-printf`); macOS dev has it as gfind.
  find_bin: System.get_env("FIND_BIN") || System.find_executable("gfind") || "/usr/bin/find",
  # The panel's save script, root-owned on the box (ops/bootstrap.sh, deploy
  # recipe); nil runs the priv copy, in dev and test.
  panel_save_script:
    System.get_env("PANEL_SAVE_SCRIPT") ||
      (if System.get_env("DRUZHOK_HOST") == "systemd",
         do: "/usr/local/lib/druzhok/panel-save.py"),
  operator_telegram_id: env_or_nil.("OPERATOR_TELEGRAM_ID"),
  host:
    (if System.get_env("DRUZHOK_HOST") == "systemd",
       do: Druzhok.Host.Systemd,
       else: Druzhok.Host.Process)

# Dev: point at a local hermes venv. Tests keep the fake from config/test.exs.
if bin = System.get_env("HERMES_BIN"), do: config(:druzhok, hermes_bin: bin)
if bin = System.get_env("FETCH_WORKER_BIN"), do: config(:druzhok, fetch_worker_bin: bin)
