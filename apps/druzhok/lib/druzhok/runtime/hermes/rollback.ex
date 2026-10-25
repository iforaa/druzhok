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

  alias Druzhok.{Instance, Repo, TenantFiles}
  alias Druzhok.Runtime.Hermes

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
end
