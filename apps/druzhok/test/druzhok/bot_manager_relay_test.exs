defmodule Druzhok.BotManagerRelayTest do
  @moduledoc "BotManager holds the Telegram relay across a stop and always releases it on start."
  # async: false — real fake_hermes.sh processes.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{BotManager, Instance, Repo}
  alias Druzhok.Telegram.Webhook

  setup do
    %{data_root: root} = with_tmp_data_root()
    id = 100 + rem(System.unique_integer([:positive]), 899)
    name = "relay#{id}"
    cleanup_instance(name)

    inst =
      relay_instance(%{
        id: id,
        name: name,
        workspace: Path.join([root, name, "workspace"]),
        telegram_mode: "webhook",
        telegram_webhook_secret: "s"
      })

    %{inst: inst}
  end

  defp paused(inst), do: Webhook.paused(Repo.get!(Instance, inst.id))

  test "stop pauses the relay and start resumes it", %{inst: inst} do
    assert {:ok, _} = BotManager.start(inst.name)
    refute paused(inst)

    :ok = BotManager.stop(inst.name)
    assert {"stopping", _} = paused(inst)

    assert {:ok, _} = BotManager.start(inst.name)
    refute paused(inst)
  end

  test "restart (stop then start) ends unpaused", %{inst: inst} do
    assert {:ok, _} = BotManager.start(inst.name)
    BotManager.restart(inst.name)
    refute paused(inst)
  end

  test "a start that fails still releases the relay", %{inst: inst} do
    Webhook.pause(inst.id, :stopping)
    # Host.Process refuses a name druzhok-ctl would reject.
    inst |> Ecto.Changeset.change(%{name: "Not Valid #{inst.id}"}) |> Repo.update!()

    assert {:error, :invalid_name} = BotManager.start("Not Valid #{inst.id}")
    refute paused(inst)
  end
end
