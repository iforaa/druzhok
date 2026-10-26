defmodule Druzhok.Instance do
  use Ecto.Schema
  import Ecto.Changeset

  schema "instances" do
    field :name, :string
    field :telegram_token, :string
    field :model, :string
    field :workspace, :string
    field :active, :boolean, default: true
    field :owner_telegram_id, :integer
    field :timezone, :string, default: "UTC"
    field :language, :string, default: "ru"
    field :tenant_key, :string
    field :mention_only, :boolean, default: false
    field :welcome_message, :string
    field :allowed_telegram_ids, :string
    field :allowed_telegram_chats, :string
    field :allow_all_telegram_users, :boolean, default: false
    field :trigger_name, :string
    field :image_model, :string
    field :group_shared_memory, :boolean, default: false
    field :website_hosting_enabled, :boolean, default: false
    field :image_gen_enabled, :boolean, default: false
    field :image_gen_model, :string
    field :ruoc_account_id, :string
    field :ruoc_api_key, :string
    field :memory_provider, :string, default: "mnemosyne"
    # Telegram delivery (Druzhok.Telegram.Webhook): "polling" or "webhook".
    field :telegram_mode, :string, default: "polling"
    field :telegram_webhook_secret, :string
    field :telegram_relay_paused_until, :utc_datetime
    field :telegram_relay_pause_reason, :string
    # Lifecycle (sleep/wake spec, "Model"): requests, written by anyone...
    field :start_seq, :integer, default: 0
    field :stop_seq, :integer, default: 0
    field :delete_requested, :boolean, default: false
    field :sleep_enabled, :boolean, default: false
    # ...and what the controller did, written only by Druzhok.Lifecycle.Bot.
    field :sleeping, :boolean, default: false
    field :applied_seq, :integer, default: 0
    field :stopped_seq, :integer, default: 0
    field :failed_seq, :integer, default: 0
    field :started_at, :utc_datetime
    field :started_mode, :string
    field :woke_at, :utc_datetime
    field :start_error, :string
    field :start_failed_at, :utc_datetime_usec
    field :start_failures, :integer, default: 0
    field :delete_error, :string
    field :delete_failed_at, :utc_datetime_usec
    field :delete_failures, :integer, default: 0
    # Bot cabinet (Druzhok.Cabinet): "<bot_id>:<owner_tg_id>" of the last
    # binding ruoc accepted, the cabinet's address it returned, and whether
    # the owner's menu button was set for that binding.
    field :cabinet_binding, :string
    field :cabinet_url, :string
    field :cabinet_menu_set, :boolean, default: false
    field :cabinet_off, :boolean, default: false
    # The bot's voice (Runtime.Hermes.Voice): its Telegram name, and the hash
    # of what druzhok last wrote to SOUL.md and AGENTS.md ("deleted" when the
    # migration removed AGENTS.md).
    field :display_name, :string
    field :soul_sha256, :string
    field :soul_version, :integer
    field :agents_md_sha256, :string

    timestamps()
  end

  @doc """
  The bot's numeric Telegram id: the part of its token before the colon. nil
  for a missing or malformed token. A token change changes it, and the next
  start rebinds the cabinet.
  """
  def telegram_bot_id(%__MODULE__{telegram_token: token}) when is_binary(token) do
    with [id, _secret] <- String.split(token, ":", parts: 2),
         {n, ""} when n > 0 <- Integer.parse(id) do
      n
    else
      _ -> nil
    end
  end

  def telegram_bot_id(_), do: nil

  # Hermes memory providers druzhok knows how to configure (Runtime.Hermes).
  @memory_providers ~w(builtin mnemosyne)
  def memory_providers, do: @memory_providers

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :owner_telegram_id, :timezone, :language, :tenant_key, :mention_only, :welcome_message, :allowed_telegram_ids, :allowed_telegram_chats, :allow_all_telegram_users, :trigger_name, :image_model, :group_shared_memory, :website_hosting_enabled, :image_gen_enabled, :image_gen_model, :ruoc_account_id, :ruoc_api_key, :memory_provider, :telegram_mode, :telegram_webhook_secret, :telegram_relay_paused_until, :telegram_relay_pause_reason, :sleep_enabled, :display_name])
    |> validate_required([:name, :model, :workspace])
    |> validate_inclusion(:memory_provider, @memory_providers)
    |> validate_inclusion(:telegram_mode, Druzhok.Telegram.Webhook.modes())
    |> unique_constraint(:name)
  end

  def generate_tenant_key(name) do
    random = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
    "dk-#{name}-#{random}"
  end

  def get_allowed_ids(instance) do
    case Map.get(instance, :allowed_telegram_ids) do
      nil -> []
      "" -> []
      json -> Jason.decode!(json) |> Enum.map(&to_string/1)
    end
  end

  def add_allowed_id(instance, user_id) do
    ids = get_allowed_ids(instance)
    user_id = to_string(user_id)
    if user_id in ids do
      {:ok, instance}
    else
      instance
      |> changeset(%{allowed_telegram_ids: Jason.encode!(ids ++ [user_id])})
      |> Druzhok.Repo.update()
    end
  end

  def remove_allowed_id(instance, user_id) do
    ids = get_allowed_ids(instance) |> Enum.reject(&(&1 == to_string(user_id)))
    instance
    |> changeset(%{allowed_telegram_ids: Jason.encode!(ids)})
    |> Druzhok.Repo.update()
  end
end
