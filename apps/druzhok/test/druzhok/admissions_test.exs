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
end
