defmodule Druzhok.InflightTest do
  use ExUnit.Case, async: false

  alias Druzhok.Inflight

  test "a call is open from enter to leave" do
    id = 900_000 + System.unique_integer([:positive])
    refute Inflight.busy?(id)

    ref = Inflight.enter(id)
    assert Inflight.busy?(id)
    refute Inflight.busy?(id + 1)

    second = Inflight.enter(id)
    Inflight.leave(ref)
    assert Inflight.busy?(id)
    Inflight.leave(second)
    refute Inflight.busy?(id)
  end

  test "an entry older than the stale limit is ignored" do
    prev = Application.get_env(:druzhok, :lifecycle)
    on_exit(fn -> Application.put_env(:druzhok, :lifecycle, prev) end)
    id = 900_000 + System.unique_integer([:positive])
    ref = Inflight.enter(id)
    on_exit(fn -> Inflight.leave(ref) end)

    Application.put_env(:druzhok, :lifecycle, Keyword.merge(prev, inflight_stale_s: 0))
    Process.sleep(5)
    refute Inflight.busy?(id)
  end
end
