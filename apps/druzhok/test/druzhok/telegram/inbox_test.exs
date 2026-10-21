defmodule Druzhok.Telegram.InboxTest do
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query
  alias Druzhok.Repo
  alias Druzhok.Telegram.Inbox

  setup do
    %{inst: relay_instance(%{telegram_mode: "webhook", telegram_webhook_secret: "s"})}
  end

  test "a redelivered update_id is stored once", %{inst: inst} do
    :ok = Inbox.enqueue(inst.id, 7, ~s({"update_id":7}))
    :ok = Inbox.enqueue(inst.id, 7, ~s({"update_id":7,"again":true}))
    assert Inbox.pending_count(inst.id) == 1
    assert Inbox.next_pending(inst.id).payload == ~s({"update_id":7})
  end

  test "next_waking skips rows that do not wake, until they have waited 20 h", %{inst: inst} do
    :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}), wakes: false)
    assert Inbox.next_waking(inst.id) == nil
    assert Inbox.pending_count(inst.id) == 1

    assert %Inbox{update_id: 1} =
             Inbox.next_waking(inst.id, DateTime.add(DateTime.utc_now(), 20 * 3600 + 1))

    :ok = Inbox.enqueue(inst.id, 2, ~s({"update_id":2}))
    assert %Inbox{update_id: 2} = Inbox.next_waking(inst.id)
  end

  test "nothing is stored for a bot that is not in webhook mode at the moment of the insert" do
    polling = relay_instance()
    assert {:error, :not_webhook} = Inbox.enqueue(polling.id, 1, "{}")
    assert Inbox.pending_count(polling.id) == 0
  end

  test "pending rows come out in update_id order, not arrival order", %{inst: inst} do
    for id <- [12, 10, 11], do: :ok = Inbox.enqueue(inst.id, id, ~s({"update_id":#{id}}))

    order =
      Enum.map(1..3, fn _ ->
        row = Inbox.next_pending(inst.id)
        :ok = Inbox.ack(row)
        row.update_id
      end)

    assert order == [10, 11, 12]
    assert Inbox.next_pending(inst.id) == nil
  end

  test "reject drops one row with its reason; record_failure keeps it pending", %{inst: inst} do
    :ok = Inbox.enqueue(inst.id, 1, "{}")
    :ok = Inbox.enqueue(inst.id, 2, "{}")

    row = Inbox.next_pending(inst.id)
    :ok = Inbox.record_failure(row, "econnrefused")
    :ok = Inbox.record_failure(row, "econnrefused")
    assert %{update_id: 1, attempts: 2, last_error: "econnrefused"} = Inbox.next_pending(inst.id)

    :ok = Inbox.reject(row, "HTTP 400")
    assert %{update_id: 2} = Inbox.next_pending(inst.id)
    assert %{dropped_reason: "rejected"} = Repo.get!(Inbox, row.id)
  end

  test "housekeep expires rows past 24 h and prunes handled rows past 3 days", %{inst: inst} do
    now = DateTime.utc_now()
    :ok = Inbox.enqueue(inst.id, 1, "{}")
    :ok = Inbox.enqueue(inst.id, 2, "{}")
    :ok = Inbox.enqueue(inst.id, 3, "{}")

    age(inst.id, 1, received: -25 * 3600)
    age(inst.id, 3, received: -5 * 86_400, acked: -4 * 86_400)

    assert {1, 1} = Inbox.housekeep(inst.id, now)
    assert %{dropped_reason: "expired"} = Repo.get_by!(Inbox, instance_id: inst.id, update_id: 1)
    assert Repo.get_by(Inbox, instance_id: inst.id, update_id: 3) == nil
    assert Inbox.pending_count(inst.id) == 1
  end

  defp age(instance_id, update_id, opts) do
    shift = fn s -> DateTime.add(DateTime.utc_now(), s) end

    fields =
      [received_at: shift.(opts[:received])] ++
        if(opts[:acked], do: [acked_at: shift.(opts[:acked])], else: [])

    from(u in Inbox, where: u.instance_id == ^instance_id and u.update_id == ^update_id)
    |> Repo.update_all(set: fields)
  end
end
