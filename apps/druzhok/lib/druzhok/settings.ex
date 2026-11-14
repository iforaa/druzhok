defmodule Druzhok.Settings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "settings" do
    field(:key, :string)
    field(:value, :string)

    timestamps()
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key])
    |> unique_constraint(:key)
  end

  # cleohub_notice is what bots answer to «что-то сломалось?» (`cleohub_notices`),
  # set with `ops/druzhok settings set cleohub_notice=-` (stdin), cleared with an empty value.
  # ruoc_admin_host / ruoc_admin_token are read by nothing since partner
  # access (RUOC_PARTNER_TOKEN); they stay listed for a rollback to the
  # previous druzhok and go in a later release.
  @keys ~w(openai_api_key manager_bot_token operator_telegram_id
           ruoc_url ruoc_admin_host ruoc_admin_token ruoc_catalog_key fetch_secret bot_creation
           sleep_idle_minutes start_min_free_mb docs_min_free_mb ruoc_site_url
           group_rate_user_per_min group_rate_chat_per_hour
           bot_slots slice_minutes max_bots min_free_disk_mb cleohub_notice)
  @secret ~w(openai_api_key manager_bot_token ruoc_admin_token ruoc_catalog_key
             fetch_secret)

  @doc "The keys an operator sets (`ops/druzhok settings set`)."
  def keys, do: @keys

  @doc "The keys whose values are never shown whole."
  def secret_keys, do: @secret

  @doc "Setting value, or nil when unset or blank."
  def get(key) do
    case Druzhok.Repo.get_by(__MODULE__, key: key) do
      %{value: v} when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  def set(key, value) do
    %__MODULE__{}
    |> changeset(%{key: key, value: value})
    |> Druzhok.Repo.insert(
      on_conflict: [set: [value: value, updated_at: DateTime.utc_now()]],
      conflict_target: :key
    )
  end

  @doc """
  Telegram user id of the platform operator, or nil. Hermes makes this id the
  slash-command admin on every bot; tenants get the user tier.
  """
  def operator_telegram_id do
    Application.get_env(:druzhok, :operator_telegram_id) || get("operator_telegram_id")
  end

  @doc """
  Shared secret ruoc-gateway presents to `POST /internal/fetch` (its
  `FETCH_SECRET`): env wins, otherwise `ops/druzhok settings`. Nil closes the endpoint.
  """
  def fetch_secret do
    Application.get_env(:druzhok, :fetch_secret) || get("fetch_secret")
  end

  @doc "Answered messages a minute one person may send in a group (default 5)."
  def group_rate_user_per_min, do: positive_int("group_rate_user_per_min", 5)

  @doc "Answered messages an hour one group may send (default 30)."
  def group_rate_chat_per_hour, do: positive_int("group_rate_chat_per_hour", 30)

  @doc "A positive integer setting, or `default` when unset or not one: a typo must not open a limit or close a gate."
  def positive_int(key, default) do
    case Integer.parse(get(key) || "") do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  @doc """
  Whether the superbot has stopped making bots for anyone but the operator.
  Set with `ops/druzhok settings set bot_creation=closed`; unset is open. Bots that exist keep running.
  """
  def bot_creation_closed?, do: get("bot_creation") == "closed"
end
