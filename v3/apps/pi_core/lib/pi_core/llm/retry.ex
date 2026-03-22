defmodule PiCore.LLM.Retry do
  @moduledoc """
  Retry with exponential backoff for LLM API calls.
  Handles transient failures: timeouts, 429 rate limits, 500+ server errors.
  """

  @default_max_retries 3
  @default_initial_delay_ms 1_000
  @default_max_delay_ms 30_000

  @retryable_statuses [429, 500, 502, 503, 504]

  def with_retry(fun, opts \\ []) do
    max_retries = opts[:max_retries] || @default_max_retries
    initial_delay = opts[:initial_delay_ms] || @default_initial_delay_ms
    max_delay = opts[:max_delay_ms] || @default_max_delay_ms

    do_retry(fun, 0, max_retries, initial_delay, max_delay)
  end

  defp do_retry(fun, attempt, max_retries, _initial_delay, _max_delay) when attempt > max_retries do
    fun.()
  end

  defp do_retry(fun, attempt, max_retries, initial_delay, max_delay) do
    case fun.() do
      {:error, reason} when is_binary(reason) ->
        if retryable?(reason) && attempt < max_retries do
          delay = calculate_delay(attempt, initial_delay, max_delay)
          Process.sleep(delay)
          do_retry(fun, attempt + 1, max_retries, initial_delay, max_delay)
        else
          {:error, reason}
        end

      other ->
        other
    end
  end

  @retryable_patterns ["timeout", "ECONNREFUSED", "ECONNRESET"]

  defp retryable?(reason) do
    Enum.any?(@retryable_patterns, &String.contains?(reason, &1)) ||
      Enum.any?(@retryable_statuses, &String.contains?(reason, "#{&1}"))
  end

  defp calculate_delay(attempt, initial_delay, max_delay) do
    # Exponential backoff with jitter
    base = initial_delay * :math.pow(2, attempt) |> round()
    jitter = :rand.uniform(div(base, 4) + 1)
    min(base + jitter, max_delay)
  end
end
