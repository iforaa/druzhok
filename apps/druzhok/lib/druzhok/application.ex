defmodule Druzhok.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        Druzhok.Repo,
        {Registry, keys: :unique, name: Druzhok.Registry},
        {DynamicSupervisor, name: Druzhok.Host.ProcessSup, strategy: :one_for_one},
        {Finch, name: Druzhok.Finch},
        {Finch, name: Druzhok.LocalFinch},
        Druzhok.Fetch.Worker,
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
      [Druzhok.ManagerBot, sweep_panel_saves()] ++ backfill()
    else
      []
    end
  end

  # Hand-over files left by a save that a crash cut short; a stale save script.
  defp sweep_panel_saves do
    Supervisor.child_spec({Task, &Druzhok.Panel.Editor.boot/0}, id: :panel_save_sweep)
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
