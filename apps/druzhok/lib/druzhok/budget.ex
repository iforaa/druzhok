defmodule Druzhok.Budget do
  @moduledoc """
  Per-bot daily USD budget in cents.

  Budget.balance stores cents spent *today* (not remaining). The limit
  lives on `instance.daily_budget_cents`. Value 0 = unlimited.

  Daily reset is lazy: every `check/1` call compares `budget.reset_at` to
  today-in-tz (using `instance.timezone`). If different, `balance` is
  zeroed and `reset_at` is advanced. No cron required.
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias Druzhok.{Instance, Repo}

  schema "budgets" do
    belongs_to :instance, Druzhok.Instance
    field :balance, :integer, default: 0
    field :lifetime_used, :integer, default: 0
    field :reset_at, :date
    timestamps()
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [:instance_id, :balance, :lifetime_used, :reset_at])
    |> validate_required([:instance_id])
    |> unique_constraint(:instance_id)
  end

  @doc """
  Returns `{:ok, remaining_cents}`, `{:ok, :unlimited}`, or `{:error, :exceeded}`.
  Lazily resets the daily counter when the reset_at date differs from today-in-tz.
  """
  def check(instance_id) do
    case Repo.get(Instance, instance_id) do
      nil ->
        {:error, :not_found}

      %Instance{daily_budget_cents: 0} ->
        {:ok, :unlimited}

      %Instance{daily_budget_cents: limit} = instance ->
        budget = get_or_create_with_reset(instance)

        if budget.balance >= limit do
          {:error, :exceeded}
        else
          {:ok, limit - budget.balance}
        end
    end
  end

  @doc """
  Adds `cents` to today's spend and lifetime total. No-op for zero/negative.
  """
  def deduct(instance_id, cents) when is_integer(cents) and cents > 0 do
    instance = Repo.get(Instance, instance_id)
    budget = get_or_create_with_reset(instance)

    budget
    |> changeset(%{
      balance: budget.balance + cents,
      lifetime_used: budget.lifetime_used + cents
    })
    |> Repo.update()
  end

  def deduct(_instance_id, _cents), do: :ok

  @doc """
  Returns cents spent today for display in dashboard.
  """
  def spent_today_cents(instance_id) do
    case Repo.get(Instance, instance_id) do
      nil ->
        0

      instance ->
        budget = get_or_create_with_reset(instance)
        budget.balance
    end
  end

  @doc """
  Formats cents as a two-decimal dollar string, e.g. `120 -> "1.20"`.
  Shared across proxy error messages and dashboard UI.
  """
  def cents_to_dollars(cents) when is_integer(cents) do
    :io_lib.format("~.2f", [cents / 100]) |> IO.iodata_to_binary()
  end

  def cents_to_dollars(_), do: "0.00"

  # --- Private ---

  defp get_or_create_with_reset(%Instance{} = instance) do
    today = today_in_tz(instance.timezone || "UTC")

    case Repo.get_by(__MODULE__, instance_id: instance.id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{instance_id: instance.id, balance: 0, reset_at: today})
        |> Repo.insert!()

      %__MODULE__{reset_at: ^today} = budget ->
        budget

      budget ->
        budget
        |> changeset(%{balance: 0, reset_at: today})
        |> Repo.update!()
    end
  end

  defp today_in_tz(tz) do
    case DateTime.now(tz) do
      {:ok, dt} -> DateTime.to_date(dt)
      _ -> Date.utc_today()
    end
  end
end
