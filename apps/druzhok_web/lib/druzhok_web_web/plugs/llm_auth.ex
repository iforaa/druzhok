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
          instance ->
            assign(conn, :instance, instance)
        end
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: %{message: "Missing Authorization header", type: "authentication_error"}}))
        |> halt()
    end
  end
end
