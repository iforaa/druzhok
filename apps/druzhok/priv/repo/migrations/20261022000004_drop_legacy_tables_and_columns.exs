defmodule Druzhok.Repo.Migrations.DropLegacyTablesAndColumns do
  use Ecto.Migration

  # Leftovers of the own-agent, OpenClaw, Docker, honcho and token-pool eras
  # (legacy cleanup spec, step 4). Nothing has read them since step 2, and the
  # schema no longer declares `api_key` or `group_sessions_per_user`.

  @tables ~w(models llm_requests reminders tool_executions memory_embeddings allowed_chats
             tokens pairing_codes)a

  @columns [
    api_key: :string,
    group_sessions_per_user: :boolean,
    heartbeat_interval: :integer,
    sandbox: :string,
    daily_token_limit: :integer,
    dream_hour: :integer,
    bot_runtime: :string,
    on_demand_model: :string,
    reject_message: :string,
    audio_model: :string,
    embedding_model: :string,
    heartbeat_active_start: :string,
    heartbeat_active_end: :string,
    heartbeat_target: :string,
    fallback_models: :string,
    dreaming: :boolean,
    honcho_workspace: :string,
    honcho_token: :string
  ]

  @settings ~w(anthropic_api_key nebius_api_key openrouter_api_url openrouter_api_key)

  def up do
    for t <- @tables, do: drop_if_exists(table(t))

    # SQLite refuses DROP COLUMN on an indexed column, and ecto_sqlite3 does
    # not drop dependent indexes.
    drop_if_exists index(:instances, [:api_key])

    alter table(:instances) do
      for {c, _} <- @columns, do: remove(c)
    end

    execute "DELETE FROM settings WHERE key IN (#{Enum.map_join(@settings, ", ", &"'#{&1}'")})"
  end

  # Structure only; the data is in /data/backups/druzhok-pre-legacy-cleanup-*.db.
  def down do
    alter table(:instances) do
      for {c, type} <- @columns do
        if c == :group_sessions_per_user,
          do: add(c, type, default: true, null: false),
          else: add(c, type)
      end
    end

    create unique_index(:instances, [:api_key])

    create table(:tokens) do
      add :token, :string, null: false
      add :bot_username, :string
      add :instance_id, references(:instances, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:tokens, [:token])
    create index(:tokens, [:instance_id])

    create table(:pairing_codes) do
      add :instance_name, :string, null: false
      add :code, :string, null: false
      add :telegram_user_id, :integer, null: false
      add :username, :string
      add :display_name, :string
      add :expires_at, :utc_datetime, null: false
      timestamps()
    end

    create unique_index(:pairing_codes, [:instance_name])

    create table(:allowed_chats) do
      add :instance_name, :string, null: false
      add :chat_id, :integer, null: false
      add :chat_type, :string, null: false
      add :title, :string
      add :telegram_user_id, :integer
      add :status, :string, default: "pending", null: false
      add :info_sent, :boolean, default: false
      add :activation, :string, default: "buffer"
      add :buffer_size, :integer, default: 50
      add :system_prompt, :text
      timestamps()
    end

    create unique_index(:allowed_chats, [:instance_name, :chat_id])

    create table(:models) do
      add :model_id, :string, null: false
      add :label, :string, null: false
      add :position, :integer, default: 0
      add :provider, :string, default: "openai"
      add :context_window, :integer, default: 32000
      add :supports_reasoning, :boolean, default: false
      add :supports_tools, :boolean, default: true
      add :supports_vision, :boolean, default: false
      timestamps()
    end

    create unique_index(:models, [:model_id])

    create table(:reminders) do
      add :instance_name, :string, null: false
      add :fire_at, :utc_datetime, null: false
      add :message, :text, null: false
      add :fired, :boolean, default: false
      add :chat_id, :integer
      timestamps()
    end

    create table(:llm_requests) do
      add :instance_name, :string
      add :chat_id, :integer
      add :model, :string
      add :input_tokens, :integer, default: 0
      add :output_tokens, :integer, default: 0
      add :tool_calls_count, :integer, default: 0
      add :elapsed_ms, :integer
      add :iteration, :integer, default: 0
      add :prompt_preview, :text
      add :response_preview, :text
      timestamps(updated_at: false)
    end

    create table(:tool_executions) do
      add :instance_name, :string
      add :tool_name, :string
      add :elapsed_ms, :integer
      add :is_error, :boolean, default: false
      add :output_size, :integer, default: 0
      timestamps(updated_at: false)
    end

    create table(:memory_embeddings) do
      add :instance_name, :string, null: false
      add :file, :string, null: false
      add :chunk_hash, :string, null: false
      add :chunk_text, :text
      add :embedding, :binary, null: false
      add :model_name, :string, default: "all-MiniLM-L6-v2"
      timestamps()
    end
  end
end
