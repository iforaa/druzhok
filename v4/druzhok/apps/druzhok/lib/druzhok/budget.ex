defmodule Druzhok.Budget do
  use Ecto.Schema
  import Ecto.Changeset
  alias Druzhok.Repo

  schema "budgets" do
    belongs_to :instance, Druzhok.Instance
    field :balance, :integer, default: 0
    field :lifetime_used, :integer, default: 0
    timestamps()
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [:instance_id, :balance, :lifetime_used])
    |> validate_required([:instance_id, :balance])
    |> unique_constraint(:instance_id)
  end

  def check(instance_id) do
    # daily_token_limit == 0 means unlimited — skip budget check
    case Druzhok.Repo.get(Druzhok.Instance, instance_id) do
      %{daily_token_limit: 0} -> {:ok, :unlimited}
      _ ->
        case get_or_create(instance_id) do
          %{balance: b} when b > 0 -> {:ok, b}
          _ -> {:error, :exceeded}
        end
    end
  end

  def deduct(instance_id, tokens) when tokens > 0 do
    budget = get_or_create(instance_id)
    budget
    |> changeset(%{
      balance: max(budget.balance - tokens, 0),
      lifetime_used: budget.lifetime_used + tokens,
    })
    |> Repo.update()
  end

  def add_credits(instance_id, amount) when amount > 0 do
    budget = get_or_create(instance_id)
    budget
    |> changeset(%{balance: budget.balance + amount})
    |> Repo.update()
  end

  def get_or_create(instance_id) do
    case Repo.get_by(__MODULE__, instance_id: instance_id) do
      nil ->
        %__MODULE__{}
        |> changeset(%{instance_id: instance_id, balance: 0})
        |> Repo.insert!()
      budget -> budget
    end
  end
end
