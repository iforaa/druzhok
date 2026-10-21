defmodule DruzhokWebWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :druzhok_web

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.Head

  # Bot-published static sites for `<bot>.oldey.dev`. Runs before the Router and
  # halts on bot subdomains, so they can only ever reach files under the bot's
  # sites dir — never the `/v1/*` proxy routes. Non-bot hosts (incl. the
  # bare druzhok host) pass through untouched.
  plug DruzhokWebWeb.Plugs.BotSite

  plug DruzhokWebWeb.Router
end
