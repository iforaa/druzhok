defmodule DruzhokWebWeb.Plugs.DocsAuth do
  @moduledoc """
  Who is calling `POST /v2/docs/convert`. A bot's terminal has no key (hermes
  keeps `OPENAI_API_KEY` out of it, and the key must not land in a tenant
  file), so the bot is the one whose Linux user owns the client socket
  (`Druzhok.PeerUid`): only `bot-<name>` users pass, anyone else (Caddy for
  public traffic, druzhok, root) gets 403. `Authorization: Bearer
  <tenant_key>` identifies a bot as well.

  Under `Druzhok.Host.Process` (dev, tests) there are no bot users: the
  header `x-druzhok-docs-bot: <name>` names the bot, and only when
  `config :druzhok_web, :docs_dev_bot_header` is true. Never in prod: the
  systemd host ignores it.
  """

  import Plug.Conn
  alias Druzhok.{Instance, Repo}

  @dev_header "x-druzhok-docs-bot"

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> key] when key != "" -> by_key(conn, key)
      [] -> by_socket(conn)
      _ -> refuse(conn, 401, "unauthorized")
    end
  end

  defp by_key(conn, key) do
    case Repo.get_by(Instance, tenant_key: key) do
      nil -> refuse(conn, 401, "unauthorized")
      instance -> accept(conn, instance)
    end
  end

  defp by_socket(conn) do
    name =
      if Druzhok.Host.impl() == Druzhok.Host.Systemd,
        do: socket_owner(conn),
        else: dev_bot(conn)

    case name && Repo.get_by(Instance, name: name) do
      %Instance{} = instance -> accept(conn, instance)
      _ -> refuse(conn, 403, "forbidden")
    end
  end

  defp socket_owner(conn) do
    peer = get_peer_data(conn)
    sock = get_sock_data(conn)
    Druzhok.PeerUid.bot_name({peer.address, peer.port}, {sock.address, sock.port})
  end

  defp dev_bot(conn) do
    if Application.get_env(:druzhok_web, :docs_dev_bot_header, false) do
      case get_req_header(conn, @dev_header) do
        [name] -> name
        _ -> nil
      end
    end
  end

  # A bot being deleted is not served.
  defp accept(conn, %Instance{delete_requested: true}), do: refuse(conn, 403, "forbidden")
  defp accept(conn, instance), do: assign(conn, :instance, instance)

  defp refuse(conn, status, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: code, message: "Нет доступа к конвертеру документов."}))
    |> halt()
  end
end
