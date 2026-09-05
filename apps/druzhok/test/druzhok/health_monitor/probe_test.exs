defmodule Druzhok.HealthMonitor.ProbeTest do
  use ExUnit.Case, async: true
  alias Druzhok.HealthMonitor.Probe

  @inst %{name: "b", telegram_token: "t", tenant_key: "k", model: "m"}

  defp opts(over) do
    Keyword.merge(
      [
        unit_status: fn _ -> :active end,
        telegram_get_me: fn _ -> {:ok, %{}} end,
        llm_ping: fn _ -> :ok end,
        egress_check: fn _ -> :closed end
      ],
      over
    )
  end

  test "all green" do
    assert {:healthy, []} = Probe.run(@inst, opts([]))
  end

  test "unit not active is down and skips the rest" do
    parent = self()

    o =
      opts(
        unit_status: fn _ -> :failed end,
        telegram_get_me: fn _ ->
          send(parent, :called)
          {:ok, %{}}
        end
      )

    assert {:down, {:unit, :failed}} = Probe.run(@inst, o)
    refute_received :called
  end

  test "telegram + llm failures are degraded with both reasons" do
    o = opts(telegram_get_me: fn _ -> {:error, :unauthorized} end, llm_ping: fn _ -> {:error, 429} end)
    assert {:degraded, reasons} = Probe.run(@inst, o)
    assert {:telegram, :unauthorized} in reasons
    assert {:llm, 429} in reasons
  end

  test "open egress is degraded" do
    assert {:degraded, [:egress_open]} = Probe.run(@inst, opts(egress_check: fn _ -> :open end))
  end

  test "unenforced egress (dev host) is not a reason" do
    assert {:healthy, []} = Probe.run(@inst, opts(egress_check: fn _ -> :unenforced end))
  end
end
