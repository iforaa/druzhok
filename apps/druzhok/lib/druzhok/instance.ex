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
    field :api_key, :string
    field :language, :string, default: "ru"
    field :tenant_key, :string
    field :mention_only, :boolean, default: false
    field :welcome_message, :string
    field :allowed_telegram_ids, :string
    field :allowed_telegram_chats, :string
    field :allow_all_telegram_users, :boolean, default: false
    field :trigger_name, :string
    field :image_model, :string
    field :group_sessions_per_user, :boolean, default: true
    field :group_shared_memory, :boolean, default: false
    field :website_hosting_enabled, :boolean, default: false
    field :daily_budget_cents, :integer, default: 0
    field :image_gen_enabled, :boolean, default: false
    field :image_gen_model, :string

    has_one :budget, Druzhok.Budget

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :telegram_token, :model, :workspace, :active, :owner_telegram_id, :timezone, :api_key, :language, :tenant_key, :mention_only, :welcome_message, :allowed_telegram_ids, :allowed_telegram_chats, :allow_all_telegram_users, :trigger_name, :image_model, :group_sessions_per_user, :group_shared_memory, :website_hosting_enabled, :daily_budget_cents, :image_gen_enabled, :image_gen_model])
    |> validate_required([:name, :model, :workspace])
    |> unique_constraint(:name)
  end

  def get_by_api_key(nil), do: nil
  def get_by_api_key(key), do: Druzhok.Repo.get_by(__MODULE__, api_key: key)

  def generate_api_key do
    "dk_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
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
