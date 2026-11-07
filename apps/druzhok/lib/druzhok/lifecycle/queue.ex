defmodule Druzhok.Lifecycle.Queue do
  @moduledoc """
  Queue mode's switch and timings (bot queue spec, "Queue mode"). Queue mode
  is on only while the Settings key `bot_slots` is a positive integer; unset,
  every lifecycle path behaves as it did before the queue. The timings live
  in app env `:druzhok, :lifecycle`, so tests can shorten them.
  """

  @defaults [
    queue_tick_ms: 2_000,
    grace_s: 60,
    extension_s: 180,
    drain_check_ms: 5_000,
    settle_s: 10,
    max_drain_s: 30 * 60,
    notice_after_s: 60,
    inflight_stale_s: 15 * 60,
    sweep_ms: 60_000,
    switch_check_ms: 10_000,
    oldest_warn_s: 6 * 60 * 60
  ]
  @default_slice_minutes 5

  @doc "How many bots may hold memory at once, or nil: queue mode off."
  def slots do
    case opt(:bot_slots) do
      n when is_integer(n) and n > 0 -> n
      _ -> positive_setting("bot_slots")
    end
  end

  def on?, do: slots() != nil

  @doc "Seconds a bot keeps its slot while others wait (`slice_minutes`, default 5)."
  def slice_s do
    case opt(:slice_s) do
      s when is_integer(s) and s >= 0 -> s
      _ -> (positive_setting("slice_minutes") || @default_slice_minutes) * 60
    end
  end

  @doc "How long a switch's relay hold lasts: the whole drain plus a slow stop."
  def hold_s, do: opt(:max_drain_s) + 300

  def opt(key),
    do: Keyword.get(Application.get_env(:druzhok, :lifecycle, []), key, @defaults[key])

  # A typo must not turn queue mode on with a nonsense number: anything but a
  # positive integer reads as unset.
  defp positive_setting(key) do
    case Integer.parse(Druzhok.Settings.get(key) || "") do
      {n, ""} when n > 0 -> n
      _ -> nil
    end
  end
end
