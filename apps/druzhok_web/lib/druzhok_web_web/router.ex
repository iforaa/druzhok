defmodule DruzhokWebWeb.Router do
  use DruzhokWebWeb, :router

  import DruzhokWebWeb.Auth, only: [require_admin: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {DruzhokWebWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :auth do
    plug DruzhokWebWeb.Auth
  end

  pipeline :admin do
    plug :require_admin
  end

  # LLM Proxy API (used by bots). Every route requires a tenant key.
  pipeline :llm_api do
    plug DruzhokWebWeb.Plugs.LlmAuth
  end

  scope "/v1", DruzhokWebWeb do
    pipe_through :llm_api

    post "/chat/completions", LlmProxyController, :chat_completions
    post "/embeddings", LlmProxyController, :embeddings
    post "/images/generations", LlmProxyController, :images_generations
    post "/audio/transcriptions", LlmProxyController, :audio_transcriptions
    post "/audio/speech", LlmProxyController, :audio_speech
    post "/responses", LlmProxyController, :responses_proxy
  end

  # Firecrawl-compatible v2 API — hermes web_search and web_extract via
  # FIRECRAWL_API_URL. Both forward to ruoc-gateway.
  scope "/v2", DruzhokWebWeb do
    pipe_through :llm_api

    post "/search", LlmProxyController, :firecrawl_search
    post "/scrape", LlmProxyController, :firecrawl_scrape
  end

  # The page fetcher ruoc-gateway routes POST /v1/fetch to. Shared secret,
  # localhost in practice; see docs/superpowers/specs/2026-09-05-web-fetch-service-design.md.
  pipeline :internal_api do
    plug DruzhokWebWeb.Plugs.FetchAuth
  end

  scope "/internal", DruzhokWebWeb do
    pipe_through :internal_api

    post "/fetch", FetchController, :fetch
  end

  # Telegram pushes webhook-mode bots' updates here. No pipeline: no session,
  # no content negotiation; the controller checks the bot's own secret header
  # (docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md).
  scope "/telegram", DruzhokWebWeb do
    post "/webhook/:bot", TelegramWebhookController, :receive
  end

  # Each group of LiveViews gets its own live_session: live navigation skips
  # the plug pipelines, so the on_mount hooks in LiveAuth are what keeps a
  # websocket opened on /login out of the dashboard.

  # Public routes
  scope "/", DruzhokWebWeb do
    pipe_through :browser

    live_session :public do
      live "/login", LoginLive
    end

    post "/auth/session", AuthController, :create_session
    get "/auth/logout", AuthController, :logout
  end

  # Protected routes
  scope "/", DruzhokWebWeb do
    pipe_through [:browser, :auth]

    live_session :authenticated, on_mount: {DruzhokWebWeb.LiveAuth, :require_user} do
      live "/", DashboardLive
      live "/instances/:name", DashboardLive
      live "/instances/:name/:tab", DashboardLive
    end
  end

  # Admin-only routes
  scope "/", DruzhokWebWeb do
    pipe_through [:browser, :auth, :admin]

    live_session :admin, on_mount: {DruzhokWebWeb.LiveAuth, :require_admin} do
      live "/settings", SettingsLive
    end
  end
end
