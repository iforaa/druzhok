defmodule Druzhok.Telegram.Relay.HousekeeperTest do
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import Ecto.Query
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.Inbox
  alias Druzhok.Telegram.Relay.Housekeeper

  test "old rows of a bot switched back to polling are still pruned and expired" do
    inst = relay_instance(%{telegram_mode: "webhook", telegram_webhook_secret: "s"})
    :ok = Inbox.enqueue(inst.id, 1, ~s({"update_id":1}))
    :ok = Inbox.enqueue(inst.id, 2, ~s({"update_id":2}))
    :ok = Inbox.ack(Inbox.next_pending(inst.id))

    # Rolled back to polling with one row still queued (a forced switch would
    # have dropped it; this is the row the housekeeper must still expire).
    from(i in Instance, where: i.id == ^inst.id)
    |> Repo.update_all(set: [telegram_mode: "polling"])

    # Four days on: the queued row expires, the acked one is past 3 days.
    later = DateTime.add(DateTime.utc_now(), 4 * 86_400)
    assert {inst.id, 1, 1} in Housekeeper.sweep(later)
    # Another four: the expired row (handled at `later`) goes too.
    assert {inst.id, 0, 1} in Housekeeper.sweep(DateTime.add(later, 4 * 86_400))
    assert Repo.all(from(u in Inbox, where: u.instance_id == ^inst.id)) == []
  end
end
