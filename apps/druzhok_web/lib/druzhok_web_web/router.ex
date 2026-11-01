defmodule DruzhokWebWeb.Router do
  use DruzhokWebWeb, :router

  # No browser routes: the dashboard is gone, the operator uses `ops/druzhok`
  # (docs/superpowers/specs/2026-10-21-dashboard-removal-design.md).

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
  end

  # Firecrawl-compatible v2 API — hermes web_search and web_extract via
  # FIRECRAWL_API_URL. Both forward to ruoc-gateway.
  scope "/v2", DruzhokWebWeb do
    pipe_through :llm_api

    post "/search", LlmProxyController, :firecrawl_search
    post "/scrape", LlmProxyController, :firecrawl_scrape

    # Not Firecrawl: hermes's site_publish and site_delete, forwarded to
    # ruoc-gateway's site API under the bot's own key.
    put "/sites/:site", SitesController, :publish
    delete "/sites/:site", SitesController, :unpublish
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

  # The bot panel: a Telegram Mini App for a bot's owner (spec
  # docs/superpowers/specs/2026-10-24-bot-panel-design.md). Everything under
  # /app needs Caddy's edge header: bots reach this port directly.
  pipeline :panel do
    plug DruzhokWebWeb.Plugs.Edge
  end

  pipeline :panel_api do
    plug DruzhokWebWeb.Plugs.PanelAuth
  end

  scope "/app", DruzhokWebWeb do
    pipe_through :panel

    get "/", PanelPageController, :index
    get "/assets/:file", PanelPageController, :asset

    scope "/api" do
      pipe_through :panel_api

      get "/bot", PanelController, :bot
      get "/invites", PanelController, :invites
      get "/files", PanelController, :files
      get "/files/:kind", PanelController, :file
      get "/jobs", PanelController, :jobs
      get "/skills", PanelController, :skills
      get "/skills/:name", PanelController, :skill
      get "/skills/:category/:name", PanelController, :skill
      get "/site", PanelController, :site
      get "/site/published", PanelController, :published
      get "/image-models", PanelController, :image_models
      post "/files/:kind", PanelController, :save_file
      post "/skills/:name", PanelController, :save_skill
      post "/skills/:category/:name", PanelController, :save_skill
      post "/settings", PanelController, :settings
      post "/delete", PanelController, :delete
    end
  end

  # Telegram pushes webhook-mode bots' updates here. No pipeline: no session,
  # no content negotiation; the controller checks the bot's own secret header
  # (docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md).
  scope "/telegram", DruzhokWebWeb do
    post "/webhook/:bot", TelegramWebhookController, :receive
  end
end
