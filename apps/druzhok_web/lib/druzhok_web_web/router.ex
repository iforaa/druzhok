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
end
