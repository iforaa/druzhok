defmodule DruzhokWebWeb.Router do
  use DruzhokWebWeb, :router

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
    live "/settings", SettingsLive
    live "/models", ModelsLive
    live "/errors", ErrorsLive
    live "/usage", UsageLive
  end
end
