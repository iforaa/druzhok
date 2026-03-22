defmodule PiCore.LLM.RetryTest do
  use ExUnit.Case

  alias PiCore.LLM.Retry

  test "returns success immediately" do
    result = Retry.with_retry(fn -> {:ok, "success"} end)
    assert result == {:ok, "success"}
  end

  test "retries on timeout error" do
    counter = :counters.new(1, [:atomics])

    result = Retry.with_retry(fn ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if count < 2 do
        {:error, "timeout"}
      else
        {:ok, "success after retry"}
      end
    end, max_retries: 3, initial_delay_ms: 10)

    assert result == {:ok, "success after retry"}
  end

  test "retries on 429 rate limit" do
    counter = :counters.new(1, [:atomics])

    result = Retry.with_retry(fn ->
      count = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if count < 1 do
        {:error, "HTTP error: 429"}
      else
        {:ok, "success"}
      end
    end, max_retries: 2, initial_delay_ms: 10)

    assert result == {:ok, "success"}
  end

  test "does not retry on non-retryable error" do
    counter = :counters.new(1, [:atomics])

    result = Retry.with_retry(fn ->
      :counters.add(counter, 1, 1)
      {:error, "Invalid API key"}
    end, max_retries: 3, initial_delay_ms: 10)

    assert result == {:error, "Invalid API key"}
    assert :counters.get(counter, 1) == 1  # called only once
  end

  test "gives up after max retries" do
    result = Retry.with_retry(fn ->
      {:error, "HTTP error: 500"}
    end, max_retries: 2, initial_delay_ms: 10)

    assert result == {:error, "HTTP error: 500"}
  end
end
