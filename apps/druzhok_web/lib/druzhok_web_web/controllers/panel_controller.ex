defmodule DruzhokWebWeb.PanelController do
  @moduledoc """
  The bot panel's API (spec `docs/superpowers/specs/2026-10-24-bot-panel-design.md`;
  the writes: `2026-10-26-panel-controls-design.md`, `2026-10-31-panel-editable-pages-design.md`). `Plugs.Edge` and
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
      POST /app/api/files/:kind              {"text": "...", "base_sha256": "..." | null}
      POST /app/api/skills/:name             same body (init data under 1 hour old)
      POST /app/api/skills/:category/:name   same body
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

  def skills(conn, _params) do
    groups = Panel.skills(conn.assigns.instance)
    reply(conn, %{skills: groups.own, system: groups.system})
  end

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

  # These files instruct the bot, so a replayed init data should not be good
  # for 24 hours, but delete's 10 minutes would throw away someone's typing.
  @save_max_age_s 3600

  def save_file(conn, %{"kind" => kind} = params), do: save(conn, {:file, kind}, params)

  def save_skill(conn, %{"category" => cat, "name" => name} = params),
    do: save(conn, {:skill, [cat, name]}, params)

  def save_skill(conn, %{"name" => name} = params), do: save(conn, {:skill, [name]}, params)

  defp save(conn, target, params) do
    if System.system_time(:second) - conn.assigns.auth_date > @save_max_age_s do
      PanelAuth.error(conn, 401, "init_stale", "close the panel and open it again")
    else
      case Panel.Editor.save(
             conn.assigns.instance,
             target,
             params["text"],
             params["base_sha256"]
           ) do
        {:ok, saved} ->
          reply(conn, saved)

        {:error, status, type, message, extra} ->
          PanelAuth.error(conn, status, type, message, extra)
      end
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
