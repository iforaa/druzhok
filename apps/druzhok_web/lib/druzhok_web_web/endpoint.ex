defmodule DruzhokWebWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :druzhok_web

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # POST /v2/docs/convert reads its own body (up to 20 MiB) after the caller
  # is known: DocsController.
  @parsers Plug.Parsers.init(
             parsers: [:urlencoded, :multipart, :json],
             pass: ["*/*"],
             json_decoder: Phoenix.json_library()
           )

  plug :parse_body

  defp parse_body(%Plug.Conn{path_info: ["v2", "docs", "convert"]} = conn, _), do: conn
  defp parse_body(conn, _), do: Plug.Parsers.call(conn, @parsers)

  plug Plug.Head

  plug DruzhokWebWeb.Router
end
