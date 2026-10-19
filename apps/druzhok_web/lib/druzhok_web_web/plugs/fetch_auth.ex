defmodule DruzhokWebWeb.Plugs.FetchAuth do
  @moduledoc """
  Guards the `/internal` endpoints ruoc-gateway calls back into
  (`POST /internal/fetch`, the page reader): a bearer token compared in constant time against the shared secret
  (Settings `fetch_secret`, env `FETCH_SECRET`). No secret configured
  means the endpoint is closed, not open.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    secret = Druzhok.Settings.fetch_secret()

    with true <- is_binary(secret) and secret != "",
         ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(token, secret) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "unauthorized"}))
        |> halt()
    end
  end
end
