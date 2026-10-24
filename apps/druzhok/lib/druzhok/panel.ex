defmodule Druzhok.Panel do
  @moduledoc """
  What the bot panel shows a bot's owner, read only (spec
  `docs/superpowers/specs/2026-10-24-bot-panel-design.md`). Nothing here
  wakes a sleeping bot: it reads the instance row, the disk through
  `Druzhok.TenantFiles` / `Druzhok.Panel.Lister`, and the unit's state.

  The HTTP side (authentication, routes) is `DruzhokWebWeb.PanelController`.
  """

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
    %{
      name: inst.name,
      bot_id: Instance.telegram_bot_id(inst),
      username: Druzhok.Telegram.Addressed.username(inst),
      state: state(Lifecycle.shown_status(inst, BotManager.status(inst.name)), inst.active),
      started_at: inst.started_at,
      start_error: start_error(inst.start_error),
      settings: %{
        model: inst.model,
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
      access: access(inst),
      billing_url: billing_url()
    }
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
