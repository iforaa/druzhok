defmodule Druzhok.Agent.StreamerTest do
  use ExUnit.Case, async: true

  alias Druzhok.Agent.Streamer

  # --- new/1 ---

  test "new creates default state" do
    state = Streamer.new()
    assert Streamer.text(state) == ""
    assert state.min_chars == 30
    assert state.edit_interval_ms == 1_000
    assert state.message_id == nil
    assert state.last_edit_at == nil
  end

  test "new accepts custom options" do
    state = Streamer.new(min_chars: 10, edit_interval_ms: 500)
    assert state.min_chars == 10
    assert state.edit_interval_ms == 500
  end

  # --- append/2 + text/1 ---

  test "accumulates text deltas" do
    state =
      Streamer.new()
      |> Streamer.append("Hello ")
      |> Streamer.append("world")

    assert Streamer.text(state) == "Hello world"
  end

  test "append handles empty string" do
    state = Streamer.new() |> Streamer.append("")
    assert Streamer.text(state) == ""
  end

  # --- should_send?/1 ---

  test "should_send? returns false before min chars" do
    state = Streamer.new(min_chars: 30) |> Streamer.append("Hi")
    refute Streamer.should_send?(state)
  end

  test "should_send? returns true after min chars" do
    state = Streamer.new(min_chars: 5) |> Streamer.append("Hello world, this is long enough")
    assert Streamer.should_send?(state)
  end

  test "should_send? returns true at exactly min chars" do
    state = Streamer.new(min_chars: 5) |> Streamer.append("Hello")
    assert Streamer.should_send?(state)
  end

  test "should_send? returns false after message already sent" do
    now = System.monotonic_time(:millisecond)

    state =
      Streamer.new(min_chars: 5)
      |> Streamer.append("Hello world")
      |> Streamer.mark_sent(now, 123)

    refute Streamer.should_send?(state)
  end

  # --- should_edit?/2 ---

  test "should_edit? returns true when no edit yet" do
    state = Streamer.new() |> Streamer.mark_sent(1000, 123)
    # mark_sent sets last_edit_at, so this checks throttling
    # Let's test the nil case directly
    fresh = %Streamer{message_id: 123, last_edit_at: nil}
    assert Streamer.should_edit?(fresh, 5000)
  end

  test "throttles edits within interval" do
    now = 10_000
    state = Streamer.new() |> Streamer.mark_sent(now, 123)
    refute Streamer.should_edit?(state, now + 500)
  end

  test "allows edit after interval elapsed" do
    now = 10_000
    state = Streamer.new(edit_interval_ms: 1_000) |> Streamer.mark_sent(now, 123)
    assert Streamer.should_edit?(state, now + 1_000)
  end

  test "allows edit well after interval" do
    now = 10_000
    state = Streamer.new() |> Streamer.mark_sent(now, 123)
    assert Streamer.should_edit?(state, now + 5_000)
  end

  # --- mark_sent/3 ---

  test "mark_sent records message_id and timestamp" do
    state = Streamer.new() |> Streamer.mark_sent(42_000, 99)
    assert state.message_id == 99
    assert state.last_edit_at == 42_000
  end

  test "mark_sent without message_id only updates timestamp" do
    state = Streamer.new() |> Streamer.mark_sent(42_000)
    assert state.message_id == nil
    assert state.last_edit_at == 42_000
  end

  test "mark_sent preserves existing message_id when nil passed" do
    state =
      Streamer.new()
      |> Streamer.mark_sent(1000, 55)
      |> Streamer.mark_sent(2000)

    assert state.message_id == 55
    assert state.last_edit_at == 2000
  end

  # --- reset/1 ---

  test "reset clears state" do
    state =
      Streamer.new()
      |> Streamer.append("text")
      |> Streamer.mark_sent(1000, 42)
      |> Streamer.reset()

    assert Streamer.text(state) == ""
    assert state.message_id == nil
    assert state.last_edit_at == nil
  end

  test "reset preserves configuration" do
    state =
      Streamer.new(min_chars: 10, edit_interval_ms: 500)
      |> Streamer.append("stuff")
      |> Streamer.reset()

    assert state.min_chars == 10
    assert state.edit_interval_ms == 500
  end
end
