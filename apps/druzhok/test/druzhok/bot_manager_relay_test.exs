defmodule Druzhok.BotManagerRelayTest do
  @moduledoc """
  The lifecycle controller holds the Telegram relay across a stop and lifts
  it on a successful start, except a `wrong_owner` pause a restart cannot fix.
  """
  # async: false — real fake_hermes.sh processes.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{BotManager, Instance, Repo}
  alias Druzhok.Telegram.Webhook

  setup do
    %{data_root: root} = with_tmp_data_root()
    start_lifecycle()
    id = 100 + rem(System.unique_integer([:positive]), 899)
    name = "relay#{id}"
    cleanup_instance(name)

    inst =
      relay_instance(%{
        id: id,
        name: name,
        active: false,
        workspace: Path.join([root, name, "workspace"]),
        telegram_mode: "webhook",
        telegram_webhook_secret: "s"
      })

    %{inst: inst}
  end

  defp paused(inst), do: Webhook.paused(Repo.get!(Instance, inst.id))

  test "stop pauses the relay and start resumes it", %{inst: inst} do
    assert {:ok, _} = BotManager.start(inst.name, wait: true)
    refute paused(inst)

    :ok = BotManager.stop(inst.name, wait: true)
    assert {"stopping", _} = paused(inst)

    assert {:ok, _} = BotManager.start(inst.name, wait: true)
    refute paused(inst)
  end

  test "restart ends unpaused", %{inst: inst} do
    assert {:ok, _} = BotManager.start(inst.name, wait: true)
    assert {:ok, _} = BotManager.restart(inst.name, wait: true)
    refute paused(inst)
  end

  test "a start lifts rejected_config and keeps wrong_owner", %{inst: inst} do
    Webhook.pause(inst.id, :rejected_config)
    assert {:ok, _} = BotManager.start(inst.name, wait: true)
    refute paused(inst)

    Webhook.pause(inst.id, :wrong_owner)
    assert {:ok, _} = BotManager.restart(inst.name, wait: true)
    assert {"wrong_owner", _} = paused(inst)
  end

  test "a failed start is reported to its waiter and leaves the relay held", %{inst: inst} do
    # Host.Process refuses a name druzhok-ctl would reject.
    inst |> Ecto.Changeset.change(%{name: "Not Valid #{inst.id}"}) |> Repo.update!()

    assert {:error, ":invalid_name"} = BotManager.start("Not Valid #{inst.id}", wait: true)
    row = Repo.get!(Instance, inst.id)
    assert row.start_failures >= 1
    assert row.failed_seq == row.start_seq
    assert {"stopping", _} = paused(inst)
  end
end
