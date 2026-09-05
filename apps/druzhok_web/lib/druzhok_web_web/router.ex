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

  # Firecrawl-compatible v2 API (only /search — hermes web_search via
  # FIRECRAWL_API_URL). Forwards to OpenRouter perplexity/sonar.
  scope "/v2", DruzhokWebWeb do
    pipe_through :llm_api

    post "/search", LlmProxyController, :firecrawl_search
  end

  # Public routes
  scope "/", DruzhokWebWeb do
    pipe_through :browser

    live "/login", LoginLive
    post "/auth/session", AuthController, :create_session
    get "/auth/logout", AuthController, :logout
  end

  # Protected routes
  scope "/", DruzhokWebWeb do
    pipe_through [:browser, :auth]

    live "/", DashboardLive
    live "/instances/:name", DashboardLive
    live "/instances/:name/:tab", DashboardLive
  end

  # Admin-only routes
  scope "/", DruzhokWebWeb do
    pipe_through [:browser, :auth, :admin]

    live "/settings", SettingsLive
    live "/errors", ErrorsLive
    live "/usage", UsageLive
  end
end
