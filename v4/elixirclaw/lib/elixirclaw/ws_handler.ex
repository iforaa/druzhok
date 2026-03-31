defmodule ElixirClaw.WsHandler do
  @moduledoc """
  WebSocket handler for streaming chat responses.

  Protocol:
    Client sends: {"type": "message", "content": "hello"}
    Server sends: {"type": "delta", "content": "chunk"} (streaming)
    Server sends: {"type": "done", "content": "full response"}
    Server sends: {"type": "error", "content": "error message"}
  """
  @behaviour WebSock
  require Logger

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_in({text, [opcode: :text]}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "message", "content" => content}} ->
        session_id = state.session_id
        parent = self()

        Task.start(fn ->
          case ElixirClaw.SessionManager.prompt(session_id, content) do
            {:ok, response} ->
              send(parent, {:send_ws, Jason.encode!(%{type: "done", content: response})})
            {:error, reason} ->
              send(parent, {:send_ws, Jason.encode!(%{type: "error", content: inspect(reason)})})
          end
        end)

        {:ok, state}

      {:ok, %{"type" => "ping"}} ->
        {:push, {:text, Jason.encode!(%{type: "pong"})}, state}

      _ ->
        {:push, {:text, Jason.encode!(%{type: "error", content: "invalid message format"})}, state}
    end
  end

  @impl true
  def handle_info({:send_ws, text}, state) do
    {:push, {:text, text}, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
