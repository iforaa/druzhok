defmodule Druzhok.InstanceManager do
  @moduledoc """
  Creates and manages per-user agent instances.
  Each instance = PiCore.Session + Telegram bot.
  """

  def create(name, opts) do
    workspace = opts.workspace
    ensure_workspace(workspace)

    # Start session
    {:ok, session_pid} = PiCore.Session.start_link(%{
      workspace: workspace,
      model: opts.model,
      api_url: opts.api_url,
      api_key: opts.api_key,
      workspace_loader: opts[:workspace_loader],
      tools: opts[:tools],
      caller: nil  # telegram process will set itself
    })

    # Start telegram bot pointing to this session
    {:ok, telegram_pid} = Druzhok.Agent.Telegram.start_link(%{
      token: opts.telegram_token,
      session_pid: session_pid,
    })

    # Update session caller to telegram PID so responses go there
    GenServer.cast(session_pid, {:set_caller, telegram_pid})

    {:ok, %{name: name, session: session_pid, telegram: telegram_pid}}
  end

  def stop(%{session: session, telegram: telegram}) do
    try do GenServer.stop(telegram, :normal, 5_000) rescue _ -> :ok catch _ -> :ok end
    try do GenServer.stop(session, :normal, 5_000) rescue _ -> :ok catch _ -> :ok end
    :ok
  end

  defp ensure_workspace(workspace) do
    unless File.exists?(workspace) do
      template = Path.join([File.cwd!(), "..", "..", "workspace-template"]) |> Path.expand()
      if File.exists?(template) do
        File.cp_r!(template, workspace)
      else
        File.mkdir_p!(workspace)
        File.mkdir_p!(Path.join(workspace, "memory"))
      end
    end
  end
end
