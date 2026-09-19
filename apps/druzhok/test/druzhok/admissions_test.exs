defmodule Druzhok.AdmissionsTest do
  use ExUnit.Case, async: false

  alias Druzhok.{Admissions, Repo}

  setup do
    id = System.unique_integer([:positive]) + 10_000_000
    on_exit(fn -> Repo.delete_all(from_admissions(id)) end)
    %{id: id}
  end

  defp from_admissions(id) do
    import Ecto.Query
    from(a in "admissions", where: a.telegram_id == ^id)
  end

  @migration Path.expand("../../priv/repo/migrations/20260919000001_create_admissions.exs", __DIR__)

  # Migrations are not compiled into the app, so the module has to be loaded
  # before its SQL can be replayed. `apply/3` keeps the compiler from warning
  # about a module it cannot see yet.
  defp grandfather_sql do
    mod = Druzhok.Repo.Migrations.CreateAdmissions
    unless Code.ensure_loaded?(mod), do: Code.require_file(@migration)
    apply(mod, :grandfather_sql, [])
  end

  test "a person is not admitted until admitted, and stays admitted", %{id: id} do
    refute Admissions.admitted?(id)
    assert :ok = Admissions.admit(id, "ABCD")
    assert Admissions.admitted?(id)
    # Admitting twice is fine: a rename or a recreate must not need a second code.
    assert :ok = Admissions.admit(id, "WXYZ")
    assert Admissions.admitted?(id)
    assert Repo.aggregate(from_admissions(id), :count) == 1
  end

  test "nil is never admitted" do
    refute Admissions.admitted?(nil)
  end

  # The migration's insert runs exactly once, on prod, and getting it wrong
  # locks every current owner out of their own superbot.
  test "grandfathering admits each existing owner once and skips ownerless bots", %{id: id} do
    import Ecto.Query
    other = id + 1
    names = for n <- 1..3, do: "grand_#{id}_#{n}"

    on_exit(fn ->
      Repo.delete_all(from(i in Druzhok.Instance, where: i.name in ^names))
      Repo.delete_all(from(a in "admissions", where: a.telegram_id in [^id, ^other]))
    end)

    for {name, owner} <- Enum.zip(names, [id, id, nil]) do
      %Druzhok.Instance{}
      |> Druzhok.Instance.changeset(%{
        name: name,
        model: "m",
        workspace: "/tmp/#{name}",
        tenant_key: "dk-#{name}",
        owner_telegram_id: owner
      })
      |> Repo.insert!()
    end

    # On prod the table is empty when this runs; here the DB may carry rows from
    # other tests, so clear the owners the insert is about to cover.
    owners =
      Repo.all(
        from(i in Druzhok.Instance,
          where: not is_nil(i.owner_telegram_id),
          distinct: true,
          select: i.owner_telegram_id
        )
      )

    assert id in owners
    Repo.delete_all(from(a in "admissions", where: a.telegram_id in ^owners))
    on_exit(fn -> Repo.delete_all(from(a in "admissions", where: a.telegram_id in ^owners)) end)

    Repo.query!(grandfather_sql())

    # One row per distinct owner — the two bots sharing `id` produce one — and
    # none for the bot with no owner.
    assert Repo.aggregate(from_admissions(id), :count) == 1
    assert Repo.aggregate(from(a in "admissions", where: a.telegram_id in ^owners), :count) == length(owners)
    refute Admissions.admitted?(other)
    assert Admissions.admitted?(id)
  end
end
