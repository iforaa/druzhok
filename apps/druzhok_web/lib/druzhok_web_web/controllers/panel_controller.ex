defmodule DruzhokWebWeb.PanelController do
  @moduledoc """
  The bot panel's API (spec `docs/superpowers/specs/2026-10-24-bot-panel-design.md`;
  the two writes: `2026-10-26-panel-controls-design.md`). `Plugs.Edge` and
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
      GET /app/api/image-models
      POST /app/api/settings        {"changes": {"language": "en", ...}}
      POST /app/api/delete          deletes the bot (init data under 10 min old)
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

  def image_models(conn, _params) do
    case Panel.image_models() do
      {:ok, models} ->
        reply(conn, %{models: models})

      :error ->
        PanelAuth.error(conn, 502, "catalogue_unavailable", "could not load the picture models")
    end
  end

  def settings(conn, %{"changes" => changes}) when is_map(changes) do
    case Druzhok.Panel.Settings.save(conn.assigns.instance, changes) do
      {:ok, inst} -> reply(conn, %{bot: Panel.bot(inst)})
      {:error, status, type, message} -> PanelAuth.error(conn, status, type, message)
    end
  end

  def settings(conn, _params),
    do: PanelAuth.error(conn, 400, "invalid_setting", "the body must be {\"changes\": {...}}")

  # A delete is the one write a replayed init data could do lasting harm with,
  # so it takes a panel opened in the last 10 minutes rather than 24 hours.
  @delete_max_age_s 600

  def delete(conn, _params) do
    if System.system_time(:second) - conn.assigns.auth_date > @delete_max_age_s do
      PanelAuth.error(conn, 401, "init_stale", "close the panel and open it again")
    else
      :ok = Druzhok.BotManager.delete(conn.assigns.instance.name)
      reply(conn, %{deleted: true})
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
