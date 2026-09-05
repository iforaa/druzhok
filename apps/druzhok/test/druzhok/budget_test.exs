defmodule Druzhok.BudgetTest do
  use ExUnit.Case
  import Ecto.Query
  alias Druzhok.{Budget, Instance, Repo}

  setup do
    name = "budget-test-#{System.unique_integer([:positive])}"
    {:ok, instance} =
      %Instance{}
      |> Instance.changeset(%{
        name: name,
        model: "xiaomi/mimo-v2-pro",
        workspace: "/tmp/#{name}/workspace",
        timezone: "UTC",
        daily_budget_cents: 100
      })
      |> Repo.insert()

    on_exit(fn ->
      Repo.delete_all(from(b in Budget, where: b.instance_id == ^instance.id))
      Repo.delete(instance)
    end)

    %{instance: instance}
  end

  describe "check/1" do
    test "returns :unlimited when daily_budget_cents is 0", %{instance: instance} do
      {:ok, _} =
        instance
        |> Instance.changeset(%{daily_budget_cents: 0})
        |> Repo.update()

      assert Budget.check(instance.id) == {:ok, :unlimited}
    end

    test "returns :ok when spent_today < daily_budget_cents", %{instance: instance} do
      Budget.deduct(instance.id, 30)
      assert {:ok, remaining} = Budget.check(instance.id)
      assert remaining == 70
    end

    test "returns {:error, :exceeded} when spent_today >= daily_budget_cents", %{instance: instance} do
      Budget.deduct(instance.id, 100)
      assert Budget.check(instance.id) == {:error, :exceeded}
    end
  end

  describe "lazy reset" do
    test "resets balance when reset_at differs from today-in-tz", %{instance: instance} do
      Budget.deduct(instance.id, 80)
      yesterday = Date.add(Date.utc_today(), -1)
      Repo.update_all(
        from(b in Budget, where: b.instance_id == ^instance.id),
        set: [reset_at: yesterday]
      )

      assert {:ok, 100} = Budget.check(instance.id)

      reloaded = Repo.get_by(Budget, instance_id: instance.id)
      assert reloaded.balance == 0
      assert reloaded.reset_at == Date.utc_today()
    end

    test "respects non-UTC timezone", %{instance: instance} do
      {:ok, instance} =
        instance
        |> Instance.changeset(%{timezone: "Europe/Amsterdam"})
        |> Repo.update()

      Budget.deduct(instance.id, 50)
      today_ams = DateTime.now!("Europe/Amsterdam") |> DateTime.to_date()
      reloaded = Repo.get_by(Budget, instance_id: instance.id)
      assert reloaded.reset_at == today_ams
    end
  end

  describe "deduct/2" do
    test "increments balance and lifetime_used", %{instance: instance} do
      {:ok, _} = Budget.deduct(instance.id, 25)
      {:ok, _} = Budget.deduct(instance.id, 10)
      b = Repo.get_by(Budget, instance_id: instance.id)
      assert b.balance == 35
      assert b.lifetime_used == 35
    end

    test "is a no-op for non-positive amounts", %{instance: instance} do
      Budget.deduct(instance.id, 20)
      Budget.deduct(instance.id, 0)
      Budget.deduct(instance.id, -5)
      b = Repo.get_by(Budget, instance_id: instance.id)
      assert b.balance == 20
    end
  end
end
