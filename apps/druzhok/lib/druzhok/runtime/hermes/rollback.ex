defmodule Druzhok.Runtime.Hermes.Rollback do
  @moduledoc """
  One-off rollbacks for config changes whose keys the previous `sync_config`
  would leave in force (spec 2026-10-25-hermes-config-tuning-design.md).

  Order: deploy a revert of the sync steps that keeps this module, then
  `sudo ops/druzhok-run.sh 'IO.inspect(Druzhok.Runtime.Hermes.Rollback.tuning())'`,
  then restart the bots one at a time, then run it once more: every bot must
  report `:unchanged`. Running it while the new sync steps are still live is
  pointless: the next start or wake writes the keys back.

  A running bot may rewrite config.yaml itself (Telegram topic ids, /model)
  between this read and write: one of the two writes is lost. The re-run after
  the restarts catches keys a bot wrote back; a lost topic id is recreated by
  hermes.
  """

  require Logger
  alias Druzhok.{Instance, Repo, TenantFiles}
  alias Druzhok.Runtime.Hermes
  alias Druzhok.Runtime.Hermes.Voice

  @doc """
  Removes the config-tuning keys from every bot's config.yaml through
  TenantFiles. Returns `[{name, :ok | :unchanged | {:skipped, reason} | {:error, reason}}]`.
  """
  def tuning do
    for inst <- Repo.all(Instance) do
      root = Hermes.data_root(inst)

      result =
        case TenantFiles.read_text(root, ["config.yaml"], 1_048_576) do
          {:ok, %{text: content, truncated: false}} ->
            case Hermes.strip_tuning_keys(content) do
              ^content -> :unchanged
              stripped -> TenantFiles.write(root, ["config.yaml"], stripped)
            end

          other ->
            {:skipped, other}
        end

      {inst.name, result}
    end
  end

  @doc """
  Undoes the bot-voice change (spec 2026-10-25-bot-voice-design.md, Rollback)
  on every bot, through TenantFiles:

  - removes `agent.system_prompt` and `platform_hints.telegram` from config.yaml;
  - restores the newest `SOUL.md.bak-*` when SOUL.md is still what druzhok
    wrote (`instances.soul_sha256`);
  - restores the newest `workspace/AGENTS.md.bak-*` when AGENTS.md is absent
    or still what the migration wrote (`instances.agents_md_sha256`).

  Anything edited since is kept, its backup left in place and the case
  logged. Same order as `tuning/0`: deploy the partial revert (sync steps out,
  this module kept), run this, restart the bots. Returns
  `[{name, %{config:, soul:, agents_md:}}]`.
  """
  def voice do
    for inst <- Repo.all(Instance) do
      root = Hermes.data_root(inst)

      {inst.name,
       %{
         config: strip_config(root),
         soul: restore(root, [], "SOUL.md", inst.soul_sha256, false),
         agents_md: restore(root, ["workspace"], "AGENTS.md", inst.agents_md_sha256, true)
       }}
    end
  end

  defp strip_config(root) do
    case TenantFiles.read_text(root, ["config.yaml"], 1_048_576) do
      {:ok, %{text: content, truncated: false}} ->
        case Hermes.strip_voice_keys(content) do
          ^content -> :unchanged
          stripped -> TenantFiles.write(root, ["config.yaml"], stripped)
        end

      other ->
        {:skipped, other}
    end
  end

  # `absent_ok?`: a missing file counts as druzhok's (the migration deleted it).
  defp restore(root, dirs, name, recorded, absent_ok?) do
    with {:ok, bak} <- newest_backup(root, dirs, name),
         {:ok, text} <- read(root, dirs ++ [bak]),
         :ours <- ours?(root, dirs ++ [name], recorded, absent_ok?) do
      TenantFiles.write(root, dirs ++ [name], text)
    else
      :edited ->
        Logger.warning(
          "[rollback] #{Path.join([root | dirs] ++ [name])} changed since; backup left in place"
        )

        :edited

      other ->
        other
    end
  end

  defp newest_backup(root, dirs, name) do
    case File.ls(Path.join([root | dirs])) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.starts_with?(&1, name <> ".bak-"))
        |> Enum.sort()
        |> List.last()
        |> case do
          nil -> :no_backup
          bak -> {:ok, bak}
        end

      _ ->
        :no_backup
    end
  end

  defp read(root, segments) do
    case TenantFiles.read_text(root, segments, 1_048_576) do
      {:ok, %{text: text, truncated: false}} -> {:ok, text}
      other -> {:skipped, other}
    end
  end

  defp ours?(root, segments, recorded, absent_ok?) do
    case File.lstat(Path.join([root | segments])) do
      {:error, :enoent} when absent_ok? ->
        :ours

      {:ok, %File.Stat{type: :regular}} ->
        case read(root, segments) do
          {:ok, text} -> if Voice.sha256(text) == recorded, do: :ours, else: :edited
          other -> other
        end

      _ ->
        :edited
    end
  end
end
