defmodule DruzhokWebWeb.PanelController do
  @moduledoc """
  The bot panel's API, read only (spec
  `docs/superpowers/specs/2026-10-24-bot-panel-design.md`). `Plugs.Edge` and
  `Plugs.PanelAuth` have run: `conn.assigns.instance` is the owner's bot.

      GET /app/api/bot
      GET /app/api/files
      GET /app/api/files/:kind            soul | memory | user
      GET /app/api/jobs
      GET /app/api/skills
      GET /app/api/skills/:name
      GET /app/api/skills/:category/:name
      GET /app/api/site
      GET /app/api/invites
  """

  use DruzhokWebWeb, :controller

  alias Druzhok.Panel
  alias DruzhokWebWeb.Plugs.PanelAuth

  def bot(conn, _params), do: reply(conn, Panel.bot(conn.assigns.instance))
  def files(conn, _params), do: reply(conn, Panel.files(conn.assigns.instance))
  def file(conn, %{"kind" => kind}), do: content(conn, Panel.file(conn.assigns.instance, kind))
  def jobs(conn, _params), do: reply(conn, Panel.jobs(conn.assigns.instance))
  def skills(conn, _params), do: reply(conn, %{skills: Panel.skills(conn.assigns.instance)})

  def skill(conn, %{"category" => cat, "name" => name}),
    do: content(conn, Panel.skill(conn.assigns.instance, [cat, name]))

  def skill(conn, %{"name" => name}),
    do: content(conn, Panel.skill(conn.assigns.instance, [name]))

  def site(conn, _params) do
    files =
      case Panel.site(conn.assigns.instance) do
        nil -> nil
        list -> Enum.map(list, &Map.take(&1, [:site, :path, :size, :type]))
      end

    reply(conn, %{files: files})
  end

  def invites(conn, _params) do
    case Panel.invites(conn.assigns.instance) do
      {:ok, body} -> reply(conn, body)
      :error -> PanelAuth.error(conn, 502, "invites_unavailable", "could not load the invites")
    end
  end

  defp content(conn, {:ok, body}), do: reply(conn, body)
  defp content(conn, :not_found), do: PanelAuth.error(conn, 404, "not_found", "no such file")

  defp content(conn, :not_text),
    do: PanelAuth.error(conn, 422, "not_text", "the file is not text")

  defp reply(conn, body) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(body)
  end
end
