defmodule Druzhok.Panel do
  @moduledoc """
  What the bot panel shows a bot's owner (spec
  `docs/superpowers/specs/2026-10-24-bot-panel-design.md`), and the two
  things it changes: settings (`Druzhok.Panel.Settings`) and the request to
  delete the bot, which the owner confirms in the superbot (panel controls
  spec, «Delete»). Nothing here wakes a sleeping bot: it reads the instance row, the disk through
  `Druzhok.TenantFiles` / `Druzhok.Panel.Lister` and the unit's state, plus
  the bot's name from Telegram's `getMe` (`profile/1`, cached), ruoc's model
  catalogue as last fetched, and the owner's referral codes at ruoc.

  The HTTP side (authentication, routes) is `DruzhokWebWeb.PanelController`.
  """

  require Logger

  alias Druzhok.{BotManager, Instance, Lifecycle, TenantFiles}
  alias Druzhok.Panel.Lister

  @text_limit 256 * 1024
  @json_limit 1024 * 1024
  @max_skills 200
  @max_site_entries 2000
  @site_depth 8

  @files %{
    "soul" => ["SOUL.md"],
    "memory" => ["memories", "MEMORY.md"],
    "user" => ["memories", "USER.md"]
  }

  @doc "The panel's address for a bot, or nil without a public host (dev, test)."
  def url(%Instance{} = inst, query \\ []) do
    with true <- Druzhok.Telegram.Webhook.public_host?(),
         bot when is_integer(bot) <- Instance.telegram_bot_id(inst) do
      host = System.get_env("PHX_HOST") || Application.get_env(:druzhok, :public_host)
      "https://#{host}/app/?" <> URI.encode_query([{"bot", bot} | query])
    else
      _ -> nil
    end
  end

  @doc "ruoc's public origin, which the Счёт tab calls (`RUOC_SITE_URL`)."
  def billing_url do
    (Application.get_env(:druzhok, :ruoc_site_url) || Druzhok.Settings.get("ruoc_site_url") ||
       "https://oldey.dev")
    |> String.trim_trailing("/")
  end

  @doc "The live, non-deleted instance whose token belongs to Telegram bot `bot_id`."
  def find_bot(bot_id) when is_integer(bot_id) do
    import Ecto.Query

    from(i in Instance, where: i.delete_requested == false and not is_nil(i.telegram_token))
    |> Druzhok.Repo.all()
    |> Enum.find(&(Instance.telegram_bot_id(&1) == bot_id))
  end

  defp tenant_dir(%Instance{name: name}), do: BotManager.tenant_dir(name)

  # --- Бот -----------------------------------------------------------------

  @doc "State and settings, from an explicit allowlist of fields."
  def bot(%Instance{} = inst) do
    profile = profile(inst.telegram_token)
    remember_name(inst, profile)

    %{
      name: inst.name,
      bot_id: Instance.telegram_bot_id(inst),
      title: profile && profile.title,
      username: (profile && profile.username) || Druzhok.Telegram.Addressed.username(inst),
      state: state(Lifecycle.shown_status(inst, BotManager.status(inst.name)), inst.active),
      started_at: inst.started_at,
      start_error: start_error(inst.start_error),
      settings: %{
        model: inst.model,
        model_name: model_name(inst.model),
        language: inst.language,
        timezone: inst.timezone,
        mention_only: inst.mention_only,
        trigger_name: inst.trigger_name,
        sleep_enabled: inst.sleep_enabled,
        sleep_idle_minutes: div(Lifecycle.Idle.window_s(), 60),
        image_gen_enabled: inst.image_gen_enabled,
        image_gen_model: inst.image_gen_model,
        website_hosting_enabled: inst.website_hosting_enabled,
        memory_provider: inst.memory_provider,
        group_shared_memory: inst.group_shared_memory
      },
      apply: apply(inst),
      access: access(inst),
      billing_url: billing_url(),
      support_url: support_url(),
      superbot: superbot()
    }
  end

  # Where a delete is confirmed: the superbot's @username, or nil.
  defp superbot do
    case Druzhok.Settings.get("manager_bot_token") do
      token when is_binary(token) and token != "" -> profile(token) |> then(&(&1 && &1.username))
      _ -> nil
    end
  end

  defp apply(inst) do
    state = Druzhok.Panel.Settings.apply_state(inst)
    %{state: state, error: if(state == "failed", do: start_error(inst.start_error))}
  end

  # The bot's Telegram name feeds its SOUL.md (Runtime.Hermes.Voice) from the
  # row, never from a call on the start path; a renamed bot is picked up here.
  defp remember_name(%Instance{id: id, display_name: old}, %{title: title})
       when is_binary(title) and title != old do
    import Ecto.Query
    from(i in Instance, where: i.id == ^id) |> Druzhok.Repo.update_all(set: [display_name: title])
  end

  defp remember_name(_inst, _profile), do: :ok

  @doc """
  Fills `display_name` for bots that have none, from a live getMe each (one at
  a time, 3 s cap). Run once at boot by druzhok.service; a bot whose getMe
  fails keeps nil and is tried again on the next boot.
  """
  def backfill_display_names do
    import Ecto.Query

    from(i in Instance,
      where: is_nil(i.display_name) and i.delete_requested == false and not is_nil(i.telegram_token)
    )
    |> Druzhok.Repo.all()
    |> Enum.each(fn inst ->
      case profile(inst.telegram_token) do
        %{title: title} when is_binary(title) -> remember_name(inst, %{title: title})
        _ -> Logger.info("[panel] no Telegram name for #{inst.name} yet")
      end
    end)
  end

  @profile_ttl_s 3600
  @profile_retry_s 60

  @doc """
  The bot's Telegram name and @username, from `getMe`, as Telegram writes
  them: `%{title:, username:}` or nil. Cached per token for an hour; a miss
  asks Telegram and waits at most 3 s. A failed ask answers the last known
  profile (or nil) and is not repeated for a minute, so a Telegram outage
  costs one 3 s wait a minute, not one per request.
  """
  def profile(token) when is_binary(token) and token != "" do
    key = {__MODULE__, :profile, :crypto.hash(:sha256, token)}
    now = System.monotonic_time(:second)

    case :persistent_term.get(key, nil) do
      {at, p} when now - at < @profile_ttl_s ->
        p

      {:failed, at, p} when now - at < @profile_retry_s ->
        p

      cached ->
        last =
          case cached do
            {_, p} -> p
            {:failed, _, p} -> p
            nil -> nil
          end

        task = Task.async(fn -> get_me(token) end)

        case Task.yield(task, 3000) || Task.shutdown(task, :brutal_kill) do
          {:ok, %{} = p} ->
            :persistent_term.put(key, {now, p})
            p

          _ ->
            Logger.warning("[panel] getMe failed or timed out; showing the last known bot name")
            :persistent_term.put(key, {:failed, now, last})
            last
        end
    end
  end

  def profile(_), do: nil

  defp get_me(token) do
    {mod, fun} = Application.get_env(:druzhok, :panel_get_me, {Druzhok.Telegram.API, :get_me})

    case apply(mod, fun, [token]) do
      {:ok, %{} = me} -> %{title: text_or_nil(me["first_name"]), username: text_or_nil(me["username"])}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp text_or_nil(v) when is_binary(v) and v != "", do: v
  defp text_or_nil(_), do: nil

  # ruoc's catalogue name for a model id, from the catalogue as last fetched
  # (never waiting on ruoc); the id when the catalogue lacks it.
  defp model_name(nil), do: nil

  defp model_name(id) do
    case Enum.find(Druzhok.Ruoc.cached_models(), &(&1.id == id)) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> id
    end
  end

  @doc "Where the panel's «Поддержка» goes (Settings `support_url`), or nil."
  def support_url do
    case Druzhok.Settings.get("support_url") do
      url when is_binary(url) ->
        url = String.trim(url)
        if String.starts_with?(url, "https://"), do: url, else: nil

      _ ->
        nil
    end
  end

  # --- Приглашения ------------------------------------------------------------

  @doc """
  The owner's referral codes at ruoc (`GET /v1/referrals` with the bot's
  key) as links to the superbot, like its «🎁 Пригласить»:
  `{:ok, %{links: [...], used: n}}` or `:error`.
  """
  def invites(%Instance{ruoc_api_key: key}) when is_binary(key) and key != "" do
    with {:ok, codes} <- Druzhok.Ruoc.referrals(key),
         %{username: manager} when is_binary(manager) <-
           profile(Druzhok.Settings.get("manager_bot_token")) do
      {:ok,
       %{
         links: Druzhok.ManagerBot.Onboarding.invites(codes, manager),
         used: Enum.count(codes, &(&1.status == "redeemed"))
       }}
    else
      _ -> :error
    end
  end

  def invites(_), do: :error

  @doc "ruoc's picture models for the panel's picker, or `:error`."
  def image_models do
    case Druzhok.Ruoc.image_models() do
      {:ok, models} ->
        {:ok, Enum.map(models, &Map.take(&1, [:id, :name, :rub_per_image, :default]))}

      {:error, _} ->
        :error
    end
  end

  # --- Delete ---------------------------------------------------------------

  @delete_ttl_s 10 * 60

  @doc """
  Asks the owner, in the superbot, to confirm deleting the bot. Only creates
  the request: a token on the row (10 min; a live one is reused) and the
  superbot's message with ✅/❌ buttons carrying it. The bot itself cannot
  answer in that chat, so a phished panel session cannot finish a delete.
  `{:ok, superbot_username}`, `{:error, :superbot_unreachable}` when Telegram
  refuses to message the owner (they never opened the superbot), or
  `{:error, :superbot_unavailable}`.
  """
  def request_delete(%Instance{} = inst) do
    :global.trans({{__MODULE__, :delete, inst.id}, self()}, fn ->
      with token when is_binary(token) and token != "" <-
             Druzhok.Settings.get("manager_bot_token"),
           %{username: superbot} when is_binary(superbot) <- profile(token),
           %Instance{delete_requested: false} = latest <- Druzhok.Repo.get(Instance, inst.id),
           confirm = live_token(latest) || new_token(latest),
           {text, rows} =
             Druzhok.ManagerBot.Onboarding.panel_delete_confirm(handle(latest), confirm),
           :ok <- send_confirm(token, latest.owner_telegram_id, text, rows) do
        {:ok, superbot}
      else
        {:error, :forbidden} ->
          clear_token(inst)
          {:error, :superbot_unreachable}

        _ ->
          {:error, :superbot_unavailable}
      end
    end)
  end

  defp live_token(%Instance{delete_confirm_token: t, delete_confirm_expires_at: %DateTime{} = at})
       when is_binary(t) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt, do: t
  end

  defp live_token(_), do: nil

  defp new_token(inst) do
    import Ecto.Query
    token = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    expires = DateTime.utc_now() |> DateTime.add(@delete_ttl_s) |> DateTime.truncate(:second)

    from(i in Instance, where: i.id == ^inst.id)
    |> Druzhok.Repo.update_all(
      set: [delete_confirm_token: token, delete_confirm_expires_at: expires]
    )

    token
  end

  defp clear_token(inst) do
    import Ecto.Query

    from(i in Instance, where: i.id == ^inst.id)
    |> Druzhok.Repo.update_all(set: [delete_confirm_token: nil, delete_confirm_expires_at: nil])
  end

  defp handle(inst) do
    case profile(inst.telegram_token) do
      %{username: u} when is_binary(u) -> u
      _ -> Druzhok.Telegram.Addressed.username(inst) || inst.name
    end
  end

  defp send_confirm(_token, owner, _text, _rows) when not is_integer(owner),
    do: {:error, :forbidden}

  defp send_confirm(token, owner, text, rows) do
    markup = %{inline_keyboard: rows}

    case Druzhok.Telegram.API.send_message(token, owner, text, %{
           reply_markup: Jason.encode!(markup)
         }) do
      {:ok, _} ->
        :ok

      {:error, body} ->
        if forbidden?(body), do: {:error, :forbidden}, else: {:error, :telegram}
    end
  end

  # 403 «bot can't initiate conversation with a user» / «bot was blocked by the user».
  defp forbidden?(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"error_code" => 403}} -> true
      _ -> false
    end
  end

  defp forbidden?(%{"error_code" => 403}), do: true
  defp forbidden?(_), do: false

  @doc "The panel's word for a bot's state; first matching row of the spec's table wins."
  def state(shown, active) do
    cond do
      shown == "active" -> "awake"
      shown == "sleeping" -> "asleep"
      shown in ["activating", "waking", "restarting"] -> "starting"
      shown in ["stopping", "deleting"] -> "stopped"
      shown in ["inactive", "failed"] and not active -> "stopped"
      shown in ["inactive", "failed"] -> "error"
      true -> "error"
    end
  end

  defp start_error(nil), do: nil

  defp start_error(text) do
    root = BotManager.data_root_base()

    text
    |> String.replace(~r/#{Regex.escape(root)}\/\S*/, "…")
    |> String.slice(0, 300)
  end

  # Counts only: the ids are other people's.
  defp access(inst) do
    paired =
      case TenantFiles.read(
             tenant_dir(inst),
             ["platforms", "pairing", "telegram-approved.json"],
             @text_limit
           ) do
        {:ok, %{bytes: bytes, truncated: false}} ->
          case Jason.decode(bytes) do
            {:ok, map} when is_map(map) -> Map.keys(map)
            _ -> []
          end

        _ ->
          []
      end

    owner = if inst.owner_telegram_id, do: [to_string(inst.owner_telegram_id)], else: []

    users =
      (owner ++ Instance.get_allowed_ids(inst) ++ paired)
      |> Enum.reject(&(&1 == "__closed__"))
      |> Enum.uniq()

    %{
      allow_all_users: inst.allow_all_telegram_users,
      allowed_users: length(users),
      free_response_chats: length(list_field(inst.allowed_telegram_chats))
    }
  end

  defp list_field(nil), do: []
  defp list_field(""), do: []

  defp list_field(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
  end

  # --- Файлы ---------------------------------------------------------------

  @doc "The files index."
  def files(%Instance{} = inst) do
    dir = tenant_dir(inst)
    skills = skills_scan(inst)
    site = site(inst)

    %{
      soul: file_meta(dir, @files["soul"]),
      memory: file_meta(dir, @files["memory"]),
      user: file_meta(dir, @files["user"]),
      jobs: %{count: length(jobs(inst).jobs)},
      skills: %{own: length(skills.own), bundled: skills.bundled},
      site:
        site &&
          %{
            files: Enum.count(site, &(&1.type == :file)),
            sites: site |> Enum.map(& &1.site) |> Enum.uniq()
          }
    }
  end

  defp file_meta(dir, segments) do
    case TenantFiles.open(dir, segments) do
      {:ok, fd, _path, stat} ->
        :file.close(fd)
        %{size: stat.size, modified_at: DateTime.from_unix!(stat.mtime)}

      :not_found ->
        nil
    end
  end

  @doc "One of the fixed Markdown files: `soul`, `memory`, `user`."
  def file(%Instance{} = inst, kind) do
    case Map.fetch(@files, kind) do
      {:ok, segments} -> text(tenant_dir(inst), segments)
      :error -> :not_found
    end
  end

  defp text(dir, segments) do
    case TenantFiles.read_text(dir, segments, @text_limit) do
      {:ok, r} -> {:ok, %{text: r.text, modified_at: r.modified_at, truncated: r.truncated}}
      other -> other
    end
  end

  # --- Задачи --------------------------------------------------------------

  @doc "Scheduled jobs from `cron/jobs.json`, shown as hermes's own list shows them."
  def jobs(%Instance{} = inst) do
    case TenantFiles.read(tenant_dir(inst), ["cron", "jobs.json"], @json_limit) do
      {:ok, %{truncated: true}} ->
        %{jobs: [], error: "too_large"}

      {:ok, %{bytes: bytes}} ->
        case Jason.decode(bytes) do
          {:ok, %{"jobs" => list}} when is_list(list) -> %{jobs: normalize_jobs(list)}
          {:ok, list} when is_list(list) -> %{jobs: normalize_jobs(list)}
          _ -> %{jobs: [], error: "unreadable"}
        end

      :not_found ->
        %{jobs: []}
    end
  end

  defp normalize_jobs(list) do
    for job <- list, is_map(job) do
      %{
        name: job_name(job),
        prompt: text_field(job["prompt"]),
        schedule: job_schedule(job),
        state: job_state(job),
        next_run_at: job["next_run_at"],
        last_run_at: job["last_run_at"],
        last_status: job["last_status"],
        repeat: repeat(job["repeat"])
      }
    end
  end

  # Any decoded JSON value, never raising: objects and lists are not text.
  defp text_field(s) when is_binary(s), do: s
  defp text_field(n) when is_number(n) or is_boolean(n), do: to_string(n)
  defp text_field(_), do: ""

  defp repeat(%{} = r), do: %{times: r["times"], completed: r["completed"]}
  defp repeat(_), do: nil

  @doc false
  def job_name(job) do
    case String.trim(text_field(job["name"])) do
      "" ->
        skills = if is_list(job["skills"]), do: job["skills"], else: []

        source =
          [
            text_field(job["prompt"]),
            text_field(List.first(skills) || job["skill"]),
            String.trim(text_field(job["script"])),
            text_field(job["id"])
          ]
          |> Enum.find("", &(&1 != ""))

        case source |> String.slice(0, 50) |> String.trim() do
          "" -> "cron job"
          name -> name
        end

      name ->
        name
    end
  end

  @doc false
  def job_schedule(job) do
    display = String.trim(text_field(job["schedule_display"]))

    cond do
      display != "" ->
        display

      is_map(job["schedule"]) ->
        Enum.find_value(~w(display value expr run_at), "?", fn k ->
          case String.trim(text_field(job["schedule"][k])) do
            "" -> nil
            v -> v
          end
        end)

      not is_nil(job["schedule"]) ->
        case text_field(job["schedule"]) do
          "" -> "?"
          s -> s
        end

      true ->
        "?"
    end
  end

  @doc false
  def job_state(job) do
    stored = String.trim(text_field(job["state"]))
    paused_marker = stored == "paused" or not is_nil(job["paused_at"])

    cond do
      stored in ["completed", "error"] ->
        stored

      Map.get(job, "enabled", true) in [false, nil] and paused_marker ->
        "paused"

      Map.get(job, "enabled", true) in [false, nil] ->
        if(stored == "", do: "paused", else: stored)

      paused_marker ->
        "scheduled"

      stored == "" ->
        "scheduled"

      true ->
        stored
    end
  end

  # --- Навыки --------------------------------------------------------------

  @doc "The bot's own skills: name, category (or nil), description."
  def skills(%Instance{} = inst) do
    # `path` is the directory segments that open the skill: the front-matter
    # name shown may differ from the directory's.
    Enum.map(skills_scan(inst).own, fn s ->
      s |> Map.take([:name, :category, :description]) |> Map.put(:path, s.segments)
    end)
  end

  @doc "One own skill's SKILL.md: `segments` is `[name]` or `[category, name]`."
  def skill(%Instance{} = inst, segments) do
    with true <- TenantFiles.valid_segments?(segments),
         %{} <- Enum.find(skills_scan(inst).own, &(&1.segments == segments)) do
      text(tenant_dir(inst), ["skills" | segments] ++ ["SKILL.md"])
    else
      _ -> :not_found
    end
  end

  defp skills_scan(inst) do
    dir = tenant_dir(inst)

    if TenantFiles.real_dir?(dir, ["skills"]) do
      found =
        Lister.list(inst.name, dir, "../skills", 3, 5000)
        |> Enum.filter(&(&1.type == :file))
        |> Enum.flat_map(fn %{path: path} ->
          case Path.split(path) do
            [name, "SKILL.md"] -> [[name]]
            [cat, name, "SKILL.md"] -> [[cat, name]]
            _ -> []
          end
        end)
        |> Enum.filter(&TenantFiles.valid_segments?/1)
        |> Enum.map(fn segs ->
          front = front_matter(dir, ["skills" | segs] ++ ["SKILL.md"])

          %{
            segments: segs,
            name: front["name"] || List.last(segs),
            category: if(length(segs) == 2, do: hd(segs)),
            description: front["description"] || ""
          }
        end)

      bundled = bundled_names(dir)
      {bundled_on_disk, own} = Enum.split_with(found, &MapSet.member?(bundled, &1.name))

      %{
        own: own |> Enum.sort_by(&{&1.category || "", &1.name}) |> Enum.take(@max_skills),
        bundled: bundled_on_disk |> Enum.map(& &1.name) |> Enum.uniq() |> length()
      }
    else
      %{own: [], bundled: 0}
    end
  end

  defp bundled_names(dir) do
    case TenantFiles.read(dir, ["skills", ".bundled_manifest"], @text_limit) do
      {:ok, %{bytes: bytes}} ->
        bytes
        |> String.split("\n")
        |> Enum.map(&(&1 |> String.split(":", parts: 2) |> hd() |> String.trim()))
        |> Enum.reject(&(&1 == ""))
        |> MapSet.new()

      _ ->
        MapSet.new()
    end
  end

  # The leading `---` block's `name:` and `description:` lines; no YAML library.
  defp front_matter(dir, segments) do
    case TenantFiles.read_text(dir, segments, 16 * 1024) do
      {:ok, %{text: text}} ->
        case String.split(text, ~r/\r?\n/) do
          ["---" | rest] ->
            rest
            |> Enum.take_while(&(&1 != "---"))
            |> Enum.flat_map(fn line ->
              case Regex.run(~r/^(name|description):\s*(.*)$/, line) do
                [_, k, v] -> [{k, v |> String.trim() |> String.trim("\"") |> String.trim("'")}]
                _ -> []
              end
            end)
            |> Map.new()

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end

  # --- Сайт ----------------------------------------------------------------

  @doc """
  The website's files below `workspace/sites/`, `[%{site, path, size, type}]`,
  or nil when hosting is off or there is no sites dir.
  """
  def site(%Instance{website_hosting_enabled: true} = inst) do
    dir = tenant_dir(inst)

    if TenantFiles.real_dir?(dir, ["workspace", "sites"]) do
      Lister.list(inst.name, dir, "sites", @site_depth, @max_site_entries)
      |> Enum.map(fn e ->
        [site | _] = Path.split(e.path)
        Map.put(e, :site, site)
      end)
    end
  end

  def site(_inst), do: nil
end
