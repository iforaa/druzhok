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

  config :druzhok_web, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :druzhok_web, DruzhokWebWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Loopback only: Caddy terminates TLS and proxies in; bots reach the
      # LLM proxy at 127.0.0.1:4000. Override with PHX_BIND_ALL=1 if needed.
      ip: (if System.get_env("PHX_BIND_ALL") == "1", do: {0, 0, 0, 0}, else: {127, 0, 0, 1}),
      port: port
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

# LLM provider credentials (used by the LLM proxy, not by bots)
# Empty env vars (e.g. `OPENROUTER_API_KEY=` in an EnvironmentFile) must
# behave like unset so the dashboard Settings value is used instead.
env_or_nil = fn name ->
  case System.get_env(name) do
    nil -> nil
    "" -> nil
    v -> v
  end
end

config :druzhok,
  nebius_api_key: env_or_nil.("NEBIUS_API_KEY"),
  nebius_api_url:
    System.get_env("NEBIUS_BASE_URL") || "https://api.tokenfactory.us-central1.nebius.com/v1",
  anthropic_api_key: env_or_nil.("ANTHROPIC_API_KEY"),
  anthropic_api_url: System.get_env("ANTHROPIC_API_URL") || "https://api.anthropic.com",
  openrouter_api_key: env_or_nil.("OPENROUTER_API_KEY"),
  openrouter_api_url: System.get_env("OPENROUTER_API_URL") || "https://openrouter.ai/api/v1",
  http_proxy_url: env_or_nil.("HTTP_PROXY_URL"),
  host:
    (if System.get_env("DRUZHOK_HOST") == "systemd",
       do: Druzhok.Host.Systemd,
       else: Druzhok.Host.Process),
  druzhok_ctl: ["sudo", "-n", "/usr/local/sbin/druzhok-ctl"]
