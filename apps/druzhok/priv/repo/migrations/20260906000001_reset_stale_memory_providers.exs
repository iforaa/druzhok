defmodule Druzhok.Repo.Migrations.ResetStaleMemoryProviders do
  use Ecto.Migration

  # `instances.memory_provider` came with the honcho migration (20260427000001)
  # and two prod rows still say "honcho", a provider druzhok no longer runs
  # (sync_config has pinned every bot to builtin since). The column now means
  # builtin | mnemosyne and the changeset validates it, so stale values are
  # reset rather than left to fail the next settings update.
  def up, do: execute("update instances set memory_provider = 'builtin' where memory_provider not in ('builtin', 'mnemosyne')")
  def down, do: :ok
end
