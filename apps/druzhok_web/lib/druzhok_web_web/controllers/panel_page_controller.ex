defmodule DruzhokWebWeb.PanelPageController do
  @moduledoc """
  The bot panel's page (built from `apps/druzhok_web/assets/app` into
  `priv/static/app` by `ops/build-app.sh`), behind `Plugs.Edge`.

      GET /app/                 the Mini App
      GET /app/assets/:file     the bundle

  Its policy follows ruoc's Mini App page: Telegram's script from
  telegram.org, Telegram Web's frame, inline style (Telegram Web injects
  some), and `connect-src` adds ruoc's public origin for the Счёт tab.
  """

  use DruzhokWebWeb, :controller

  def index(conn, _params) do
    case File.read(path("index.html")) do
      {:ok, html} ->
        conn
        |> put_resp_header("content-security-policy", policy())
        |> put_resp_header("referrer-policy", "no-referrer")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_content_type("text/html")
        |> send_resp(200, html)

      {:error, _} ->
        send_resp(conn, 404, "Not Found")
    end
  end

  def asset(conn, %{"file" => file}) do
    full = path(Path.join("assets", file))

    if Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, file) and File.regular?(full) do
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_content_type(MIME.from_path(file))
      |> send_file(200, full)
    else
      send_resp(conn, 404, "Not Found")
    end
  end

  @doc "The page's Content-Security-Policy."
  def policy do
    billing = Druzhok.Panel.billing_url() |> URI.parse()

    origin =
      "#{billing.scheme}://#{billing.host}" <>
        if(billing.port in [nil, 80, 443], do: "", else: ":#{billing.port}")

    "default-src 'none'; script-src 'self' https://telegram.org; " <>
      "style-src 'self' 'unsafe-inline'; img-src 'self'; connect-src 'self' #{origin}; " <>
      "frame-ancestors https://web.telegram.org; base-uri 'none'; form-action 'none'"
  end

  defp path(rel), do: Path.join([Application.app_dir(:druzhok_web, "priv"), "static", "app", rel])
end
