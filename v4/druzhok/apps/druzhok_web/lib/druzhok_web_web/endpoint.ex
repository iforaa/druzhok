defmodule DruzhokWebWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :druzhok_web

  # Session cookie is host-only (no domain set) so a hostile subdomain
  # (e.g. a malicious bot-hosted site at vasya.oldey.dev) cannot read
  # or overwrite it. SameSite=Strict prevents the cookie from being
  # sent on cross-site navigations — user must be actively on the
  # dashboard host. Secure + HttpOnly are standard hardening.
  @session_options [
    store: :cookie,
    key: "_druzhok_web_key",
    signing_salt: "9Ma3K3Mm",
    same_site: "Strict",
    secure: true,
    http_only: true
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :druzhok_web,
    gzip: false,
    only: DruzhokWebWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Bot-published static sites for `<bot>.oldey.dev`. Runs before the Router and
  # halts on bot subdomains, so they can only ever reach files under the bot's
  # sites dir — never the dashboard or `/v1/*` proxy routes. Non-bot hosts
  # (incl. the bare dashboard host) pass through untouched.
  plug DruzhokWebWeb.Plugs.BotSite

  plug DruzhokWebWeb.Router
end
