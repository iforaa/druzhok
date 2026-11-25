defmodule Druzhok.TtsGateTest do
  use ExUnit.Case, async: false

  alias Druzhok.TtsGate

  setup do
    TtsGate.reset()
    on_exit(&TtsGate.reset/0)
  end

  test "allowed? wants an active plan or money, and no spent window" do
    active = %{subscription: %{status: "active"}, balance_nanorub: 0, limits: nil}
    assert TtsGate.allowed?(active)
    assert TtsGate.allowed?(%{active | limits: %{spent: nil}})
    refute TtsGate.allowed?(%{active | limits: %{spent: "session"}})

    assert TtsGate.allowed?(%{subscription: nil, balance_nanorub: 1, limits: nil})
    refute TtsGate.allowed?(%{subscription: nil, balance_nanorub: 0, limits: nil})

    refute TtsGate.allowed?(%{
             subscription: %{status: "expired"},
             balance_nanorub: 0,
             limits: nil
           })
  end

  test "check_plan refuses a bot without a ruoc key" do
    assert TtsGate.check_plan(%{ruoc_api_key: nil}) == {:error, :plan}
  end

  test "take counts per bot per hour" do
    now = 1_800_000_000
    for _ <- 1..TtsGate.per_hour(), do: assert(TtsGate.take(1, now) == :ok)
    assert TtsGate.take(1, now) == :limit
    assert TtsGate.take(2, now) == :ok
    assert TtsGate.take(1, now + 3600) == :ok
  end
end
