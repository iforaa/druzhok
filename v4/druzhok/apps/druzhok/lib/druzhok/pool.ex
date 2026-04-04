defmodule Druzhok.Pool do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Druzhok.{Repo, Instance}

  schema "pools" do
    field :name, :string
    field :container, :string
    field :port, :integer
    field :max_tenants, :integer, default: 10
    field :status, :string, default: "stopped"

    has_many :instances, Instance, foreign_key: :pool_id

    timestamps()
  end

  def changeset(pool, attrs) do
    pool
    |> cast(attrs, [:name, :container, :port, :max_tenants, :status])
    |> validate_required([:name, :container, :port])
    |> unique_constraint(:name)
    |> unique_constraint(:container)
    |> unique_constraint(:port)
  end

  def with_instances(pool_id) do
    Repo.get(__MODULE__, pool_id)
    |> Repo.preload(:instances)
  end

  def active_pools do
    from(p in __MODULE__, where: p.status in ["running", "starting"])
    |> Repo.all()
    |> Repo.preload(:instances)
  end

  def pool_with_capacity do
    from(p in __MODULE__,
      left_join: i in assoc(p, :instances),
      where: p.status == "running",
      group_by: p.id,
      having: count(i.id) < p.max_tenants,
      limit: 1
    )
    |> Repo.one()
  end

  def next_port do
    case Repo.one(from p in __MODULE__, select: max(p.port)) do
      nil -> 18800
      port -> port + 1
    end
  end

  def next_name do
    count = Repo.one(from p in __MODULE__, select: count(p.id))
    "openclaw-pool-#{count + 1}"
  end
end
