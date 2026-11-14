defmodule DruzhokWebWeb.CleohubMcpController do
  @moduledoc """
  `POST /mcp/cleohub`: CleoHub's tools (`Druzhok.Cleohub`) as an MCP server for
  hermes's own client (`mcp_servers.cleohub`, written by `Runtime.Hermes`), under
  the bot's tenant key (`:llm_api`).

  Streamable HTTP reduced to what that client needs: JSON-RPC 2.0, POST only,
  every answer `application/json`, no SSE and no sessions (no `Mcp-Session-Id`, so
  the client never opens the GET stream). `initialize` echoes a protocol version
  it knows, else the latest; mcp 2.0's `server/discover` probe gets -32601 and the
  client falls back to `initialize`. A notification is 202 with no body. GET (and
  HEAD, which Plug.Head turns into GET) and DELETE are 405.

  A tool's own failure is a result with `isError: true` and a short Russian text,
  so the model can retell it; -32602 is for a call that names no known tool or
  carries arguments that are not an object.
  """

  use DruzhokWebWeb, :controller
  require Logger

  alias Druzhok.Cleohub

  @latest "2025-11-25"
  @supported ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)

  def supported_versions, do: @supported

  # A tool call reads ruoc, Telegram and the database; queue mode's drain must
  # not stop the bot under one (`Druzhok.Inflight`).
  def action(conn, opts) do
    ref = Druzhok.Inflight.enter(conn.assigns.instance.id)

    try do
      super(conn, opts)
    after
      Druzhok.Inflight.leave(ref)
    end
  end

  def rpc(conn, %{"_json" => _}), do: reply(conn, error(nil, -32600, "batches are not supported"))

  def rpc(conn, %{"jsonrpc" => "2.0", "method" => method} = msg) when is_binary(method) do
    case Map.fetch(msg, "id") do
      # A notification (`notifications/initialized`, `notifications/cancelled`):
      # nothing to answer.
      :error ->
        send_resp(conn, 202, "")

      {:ok, id} when is_binary(id) or is_integer(id) ->
        params = Map.get(msg, "params") || %{}
        reply(conn, handle(conn.assigns.instance, method, params, id))

      {:ok, _} ->
        reply(conn, error(nil, -32600, "invalid id"))
    end
  end

  # A response from the client (it never sends one: this server asks nothing).
  def rpc(conn, %{"jsonrpc" => "2.0", "id" => _} = msg)
      when is_map_key(msg, "result") or is_map_key(msg, "error"),
      do: send_resp(conn, 202, "")

  def rpc(conn, _), do: reply(conn, error(nil, -32600, "not a JSON-RPC 2.0 request"))

  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  defp handle(_inst, "initialize", params, id) when is_map(params) do
    asked = params["protocolVersion"]
    version = if asked in @supported, do: asked, else: @latest

    result(id, %{
      protocolVersion: version,
      capabilities: %{tools: %{}},
      serverInfo: %{name: "cleohub", version: "1"}
    })
  end

  defp handle(_inst, "ping", _params, id), do: result(id, %{})

  defp handle(_inst, "tools/list", _params, id), do: result(id, %{tools: Cleohub.tools()})

  defp handle(inst, "tools/call", %{"name" => name} = params, id) when is_binary(name) do
    args = Map.get(params, "arguments") || %{}

    cond do
      not Cleohub.tool?(name) ->
        error(id, -32602, "unknown tool: #{name}")

      not is_map(args) ->
        error(id, -32602, "arguments must be an object")

      true ->
        started = System.monotonic_time(:millisecond)
        outcome = Cleohub.call(inst, name, args)
        elapsed = System.monotonic_time(:millisecond) - started
        Logger.info("[cleohub] #{inst.name} #{name}: #{elem(outcome, 0)} #{elapsed}ms")
        result(id, tool_result(outcome))
    end
  end

  defp handle(_inst, "tools/call", _params, id), do: error(id, -32602, "tools/call needs a tool name")

  defp handle(_inst, "initialize", _params, id), do: error(id, -32602, "params must be an object")

  defp handle(_inst, method, _params, id), do: error(id, -32601, "method not found: #{method}")

  defp tool_result({:ok, text, structured}),
    do: %{content: [%{type: "text", text: text}], structuredContent: structured, isError: false}

  defp tool_result({:error, text}),
    do: %{content: [%{type: "text", text: text}], isError: true}

  defp result(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  defp error(id, code, message), do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp reply(conn, body), do: conn |> put_status(200) |> json(body)
end
