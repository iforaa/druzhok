defmodule DruzhokWebWeb.Plugs.LlmAuth do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> tenant_key] ->
        case Druzhok.Repo.get_by(Druzhok.Instance, tenant_key: tenant_key) do
          nil ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(401, Jason.encode!(%{error: %{message: "Invalid API key", type: "authentication_error"}}))
            |> halt()
          %{ruoc_api_key: key} = instance when is_binary(key) and key != "" ->
            assign(conn, :instance, instance)

          # The legacy OpenRouter path is gone; a row without a ruoc account
          # cannot be served until it is migrated (BotManager.migrate_to_ruoc/1).
          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(503, Jason.encode!(%{error: %{message: "bot not migrated to ruoc-gateway", type: "api_error"}}))
            |> halt()
        end
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{message: "Missing Authorization header", type: "authentication_error"}}))
        |> halt()
    end
  end
end
