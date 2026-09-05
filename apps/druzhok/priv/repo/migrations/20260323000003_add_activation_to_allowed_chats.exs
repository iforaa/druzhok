defmodule Druzhok.Repo.Migrations.AddActivationToAllowedChats do
  use Ecto.Migration

  def change do
    alter table(:allowed_chats) do
      add :activation, :string, default: "buffer"
      add :buffer_size, :integer, default: 50
    end
  end
end
