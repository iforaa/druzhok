defmodule Druzhok.Panel do
  @moduledoc """
  What the bot panel shows a bot's owner (spec
  `docs/superpowers/specs/2026-10-24-bot-panel-design.md`), and what it
  changes: settings (`Druzhok.Panel.Settings`), the text pages
  (`Druzhok.Panel.Editor`) and the request to delete the bot, which the owner
  confirms in a Telegram dialog on the page (panel controls spec, «Delete»).
  Nothing here wakes a sleeping bot: it reads the instance row, the disk through
  `Druzhok.TenantFiles` / `Druzhok.Panel.Lister` and the unit's state, plus
  the bot's name from Telegram's `getMe` (`profile/1`, cached), ruoc's model
  catalogue as last fetched, and the owner's referral codes at ruoc.

  The HTTP side (authentication, routes) is `DruzhokWebWeb.PanelController`.
  """

  require Logger

  alias Druzhok.{BotManager, Instance, Lifecycle, TenantFiles}
  alias Druzhok.Panel.Lister

  # What a save may write (`Panel.Editor`) must read back whole.
  @text_limit 512 * 1024
  @json_limit 1024 * 1024
  @max_skills 200

  # See the file's header: built-ins an older hermes dropped from the manifest.
  @shipped_skills_file Path.expand("../../priv/hermes_shipped_skills.txt", __DIR__)
  @external_resource @shipped_skills_file
  @shipped_skills @shipped_skills_file
                  |> File.read!()
                  |> String.split("\n", trim: true)
                  |> Enum.reject(&String.starts_with?(&1, "#"))
                  |> MapSet.new()
  @max_site_entries 2000
  @site_depth 8

  @files %{
    "soul" => ["SOUL.md"],
    "memory" => ["memories", "MEMORY.md"],
    "user" => ["memories", "USER.md"]
  }

  # Hermes's CONTEXT_FILE_MAX_CHARS and MAX_SKILL_CONTENT_CHARS, in code points;
  # `Panel.EditorTest` compares them with hermes.
  @soul_limit 20_000
  @skill_limit 100_000

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
      where:
        is_nil(i.display_name) and i.delete_requested == false and not is_nil(i.telegram_token)
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
      {:ok, %{} = me} ->
        %{title: text_or_nil(me["first_name"]), username: text_or_nil(me["username"])}

      _ ->
        nil
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

  @doc """
  One of the fixed Markdown files: `soul`, `memory`, `user`. Nothing at that
  name (`File.lstat` says `:enoent`) is an empty, editable page for the memory
  files and `:not_found` for `soul`; a file that is there but cannot be read
  safely is an empty page that says so and cannot be edited, so that a save can
  never take it for absent. Invalid UTF-8 is `:not_text`, 422 in place of the file.
  """
  def file(%Instance{} = inst, kind) do
    with {:ok, segments} <- Map.fetch(@files, kind) do
      dir = tenant_dir(inst)
      limit = limit(kind)

      case {File.lstat(Path.join([dir | segments])), kind} do
        {{:error, :enoent}, "soul"} ->
          :not_found

        {{:error, :enoent}, _} ->
          {:ok, page("", nil, nil, editable: true, limit: limit)}

        _ ->
          case text(dir, segments, limit, true) do
            :not_found -> {:ok, page("", nil, nil, unreadable: true, limit: limit)}
            other -> other
          end
      end
    else
      :error -> :not_found
    end
  end

  defp text(dir, segments, limit, editable?) do
    case TenantFiles.read_text(dir, segments, @text_limit) do
      {:ok, r} ->
        {:ok,
         page(r.text, r.sha256, r.modified_at,
           truncated: r.truncated,
           editable: editable? and not r.truncated,
           limit: limit
         )}

      other ->
        other
    end
  end

  defp page(text, sha256, modified_at, opts) do
    %{
      text: text,
      sha256: sha256,
      modified_at: modified_at,
      truncated: Keyword.get(opts, :truncated, false),
      editable: Keyword.get(opts, :editable, false),
      unreadable: Keyword.get(opts, :unreadable, false),
      limit: Keyword.get(opts, :limit)
    }
  end

  defp limit("soul"), do: @soul_limit
  defp limit("memory"), do: Druzhok.Runtime.Hermes.memory_limits().memory
  defp limit("user"), do: Druzhok.Runtime.Hermes.memory_limits().user

  @doc """
  What a save may write: `{:file, kind}` or `{:skill, segments}` →
  `{:ok, %{kind:, target:, limit:}}` with `target` below the tenant dir, or
  `:not_found` for an unknown path or a system skill.
  """
  def edit_target(%Instance{}, {:file, kind}) do
    case Map.fetch(@files, kind) do
      {:ok, segments} -> {:ok, %{kind: kind, target: segments, limit: limit(kind)}}
      :error -> :not_found
    end
  end

  def edit_target(%Instance{} = inst, {:skill, segments}) do
    with true <- TenantFiles.valid_segments?(segments),
         %{} <- Enum.find(skills_scan(inst).own, &(&1.segments == segments)) do
      {:ok, %{kind: "skill", target: skill_file(segments), limit: @skill_limit}}
    else
      _ -> :not_found
    end
  end

  defp skill_file(segments), do: ["skills" | segments] ++ ["SKILL.md"]

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

  @doc """
  The bot's skills, each with name, category (or nil) and description: `own`,
  written by the bot or installed, and `system`, the ones in hermes's manifest.
  """
  def skills(%Instance{} = inst) do
    scan = skills_scan(inst)
    %{own: Enum.map(scan.own, &skill_row/1), system: Enum.map(scan.system, &skill_row/1)}
  end

  # `path` is the directory segments that open the skill: the front-matter
  # name shown may differ from the directory's.
  defp skill_row(s),
    do: s |> Map.take([:name, :category, :description]) |> Map.put(:path, s.segments)

  @doc """
  One skill's SKILL.md: `segments` is `[name]` or `[category, name]`. Only an
  own skill can be edited: an edit stops hermes updating a system one.
  """
  def skill(%Instance{} = inst, segments) do
    with true <- TenantFiles.valid_segments?(segments),
         scan = skills_scan(inst),
         {:ok, own?} <- skill_group(scan, segments) do
      limit = if own?, do: @skill_limit
      text(tenant_dir(inst), skill_file(segments), limit, own?)
    else
      _ -> :not_found
    end
  end

  defp skill_group(scan, segments) do
    cond do
      Enum.any?(scan.own, &(&1.segments == segments)) -> {:ok, true}
      Enum.any?(scan.system, &(&1.segments == segments)) -> {:ok, false}
      true -> :not_found
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
          front = front_matter(dir, skill_file(segs))

          %{
            segments: segs,
            name: front["name"] || List.last(segs),
            category: if(length(segs) == 2, do: hd(segs)),
            description: front["description"] || ""
          }
        end)

      bundled = bundled_names(dir)

      {system, own} =
        Enum.split_with(
          found,
          &(MapSet.member?(bundled, &1.name) or List.last(&1.segments) in @shipped_skills)
        )

      %{
        own: skill_list(own),
        system: skill_list(system),
        bundled: system |> Enum.map(& &1.name) |> Enum.uniq() |> length()
      }
    else
      %{own: [], system: [], bundled: 0}
    end
  end

  defp skill_list(skills),
    do: skills |> Enum.sort_by(&{&1.category || "", &1.name}) |> Enum.take(@max_skills)

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

  @doc """
  What the gateway serves for this bot: `[%{name, url, files, bytes,
  published_at, disabled}]`. `[]` when hosting is off, nil when the gateway did
  not answer.
  """
  def published(%Instance{website_hosting_enabled: true} = inst) do
    case Druzhok.Sites.published(inst) do
      {:ok, sites} -> sites
      {:error, _} -> nil
    end
  end

  def published(_inst), do: []
end
