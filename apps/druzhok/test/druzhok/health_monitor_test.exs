defmodule Druzhok.HealthMonitorTest do
  # async: false — reads every instance row, which other tests create and drop.
  use ExUnit.Case, async: false

  alias Druzhok.{HealthMonitor, Instance, Repo}

  defp insert!(name, active?) do
    %Instance{}
    |> Instance.changeset(%{
      name: name,
      model: "ruoc-flash",
      workspace: "/tmp/#{name}",
      active: active?
    })
    |> Repo.insert!()

    on_exit(fn -> Repo.get_by(Instance, name: name) |> then(&(&1 && Repo.delete(&1))) end)
    name
  end

  defp start_monitor do
    name = :"health_monitor_#{System.unique_integer([:positive])}"
    start_supervised!({HealthMonitor, name: name})
    # The seed runs in handle_continue, so the first call already sees it.
    HealthMonitor.list(name)
  end

  test "the watch list is seeded from the active instances on boot" do
    running = insert!("hm_seed_up_#{System.unique_integer([:positive])}", true)
    stopped = insert!("hm_seed_off_#{System.unique_integer([:positive])}", false)

    bots = start_monitor()

    assert %{status: :healthy, failures: 0} = bots[running]
    refute Map.has_key?(bots, stopped)
  end

  test "a seeded bot starts trusted, so one bad sweep cannot restart it" do
    name = insert!("hm_seed_fresh_#{System.unique_integer([:positive])}", true)

    assert %{status: :healthy, reasons: [], failures: 0, llm: :ok} = start_monitor()[name]
  end
end
