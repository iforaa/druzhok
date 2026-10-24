defmodule DruzhokWebWeb.Plugs.Edge do
  @moduledoc """
  Admits only requests that came through Caddy to `/app` (bot panel spec,
  "Who can reach /app").

  druzhok listens on 127.0.0.1:4000, and bot processes reach that port
  directly (the LLM proxy), with any `Host` and any `X-Forwarded-For`. Caddy's
  druzhok block sets `X-Druzhok-Edge` to a secret (`DRUZHOK_EDGE_SECRET`, env
  only); a request without it gets 404, as if the route did not exist. No
  secret configured: `/app` is closed.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = Application.get_env(:druzhok, :edge_secret)

    with true <- is_binary(secret) and secret != "",
         [given] <- get_req_header(conn, "x-druzhok-edge"),
         true <- Plug.Crypto.secure_compare(given, secret) do
      conn
    else
      _ -> conn |> send_resp(404, "Not Found") |> halt()
    end
  end
end
