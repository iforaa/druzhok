defmodule ElixirClaw.Router do
  @moduledoc """
  HTTP gateway for ElixirClaw. Exposes the PiCore agent runtime via REST and WebSocket.
  """
  use Plug.Router
  require Logger

  plug Plug.Logger, log: :debug
  plug :match
  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :dispatch

  # Health check
  get "/health" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok", uptime: uptime()}))
  end

  get "/healthz" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  # Send a message to a session
  post "/chat/:session_id" do
    body = conn.body_params
    message = body["message"] || body["content"] || ""

    if String.trim(message) == "" do
      send_resp(conn, 400, Jason.encode!(%{error: "message required"}))
    else
      case ElixirClaw.SessionManager.prompt(session_id, message) do
        {:ok, response} ->
          send_resp(conn, 200, Jason.encode!(%{response: response}))
        {:error, reason} ->
          send_resp(conn, 500, Jason.encode!(%{error: inspect(reason)}))
      end
    end
  end

  # WebSocket upgrade for streaming
  get "/ws/:session_id" do
    conn
    |> WebSockAdapter.upgrade(ElixirClaw.WsHandler, %{session_id: session_id}, [])
    |> halt()
  end

  # Telegram webhook (for future use)
  post "/telegram" do
    send_resp(conn, 200, Jason.encode!(%{status: "ok"}))
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{error: "not found"}))
  end

  defp uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    "#{div(uptime_ms, 1000)}s"
  end
end
