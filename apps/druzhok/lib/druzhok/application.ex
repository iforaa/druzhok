defmodule Druzhok.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    # The tenant-fs helper, kept open (Druzhok.TenantFiles).
    children =
      [
        Druzhok.Repo,
        {Registry, keys: :unique, name: Druzhok.Registry},
        # Proxy calls open per bot, for queue mode's drain (written by druzhok_web).
        Druzhok.Inflight,
        {DynamicSupervisor, name: Druzhok.Host.ProcessSup, strategy: :one_for_one}
      ] ++
        Druzhok.TenantFiles.Server.child_specs() ++
        [
          {Finch, name: Druzhok.Finch},
          {Finch, name: Druzhok.LocalFinch},
          # Site uploads (Ruoc.Client.put_stream), each holding one for minutes.
          {Finch, name: Druzhok.UploadFinch, pools: %{default: [size: 8, count: 1]}},
          Druzhok.Fetch.Worker,
          # One document conversion at a time (POST /v2/docs/convert).
          Druzhok.Docs.Queue,
          Druzhok.Status,
          # cleohub_set_avatar's 3 a day per bot.
          Druzhok.Cleohub.AvatarLimit,
          # Warm ruoc's model catalogue: a bot start reads it from the cache
          # without waiting (Runtime.Hermes sync_image_input_mode).
          {Task, &Druzhok.Ruoc.models/0}
        ] ++ manager_bot()

    opts = [strategy: :one_for_one, name: Druzhok.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # One getUpdates poller per token: ops/druzhok-run.sh turns this off, or its
  # one-off BEAM fights druzhok.service's ManagerBot (409 Conflict). The
  # display-name backfill also runs in druzhok.service only: a one-off VM has
  # an empty profile cache and would ask Telegram for every bot again.
  defp manager_bot do
    if Application.get_env(:druzhok, :manager_bot, true) do
      [Druzhok.ManagerBot, check_scripts(), sweep_docs_jobs()] ++ backfill()
    else
      []
    end
  end

  # Job dirs a crash left (Druzhok.Docs). Only in druzhok.service: a one-off
  # BEAM would delete the dir of a job the service is converting.
  defp sweep_docs_jobs do
    Supervisor.child_spec({Task, &Druzhok.Docs.sweep/0}, id: :docs_sweep)
  end

  # A stale save script or tenant-fs helper on the box is said loudly at boot.
  defp check_scripts do
    Supervisor.child_spec({Task, &check_installed_scripts/0}, id: :script_check)
  end

  defp check_installed_scripts do
    Druzhok.Panel.Editor.check_script()
    Druzhok.TenantFiles.check_script()
  end

  defp backfill do
    if Application.get_env(:druzhok, :display_name_backfill, true),
      do: [
        Supervisor.child_spec({Task, &Druzhok.Panel.backfill_display_names/0},
          id: :display_name_backfill
        )
      ],
      else: []
  end
end
