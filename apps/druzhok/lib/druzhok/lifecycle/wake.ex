defmodule Druzhok.Lifecycle.Wake do
  @moduledoc """
  Why a sleeping bot should be awake, or nil (sleep/wake spec, rule 5). Outside
  queue mode its controller wakes it for this reason; in queue mode the reason
  makes it a candidate in `Lifecycle.Scheduler`'s line (bot queue spec, "The
  line and admission"), where two things differ: a failed start comes back as
  `:retry`, and an unreadable jobs file is not a reason, since a bot woken for
  it could never be told to sleep and would hold a slot for good.
  """

  alias Druzhok.Lifecycle.Idle
  alias Druzhok.Telegram.Inbox

  @type reason :: :update | :requested | :cron | :sleep_disabled | :mode | :retry

  @doc """
  The reason, first match wins. Options: `queue: true` for queue mode's rules;
  `waking_at:` (the oldest waking row's `received_at`, or nil) and `cron:` (an
  `Idle.cron_wake_at/1` result) when the caller has already read them.
  """
  @spec reason(map, keyword) :: reason | nil
  def reason(inst, opts \\ []) do
    queue = Keyword.get(opts, :queue, false)

    cond do
      waking?(inst, opts) -> :update
      inst.start_seq > inst.applied_seq -> :requested
      cron_due?(inst, queue, opts) -> :cron
      not inst.sleep_enabled -> :sleep_disabled
      inst.telegram_mode != "webhook" or inst.telegram_mode != inst.started_mode -> :mode
      queue and (inst.start_failures || 0) > 0 -> :retry
      true -> nil
    end
  end

  defp waking?(inst, opts) do
    case Keyword.fetch(opts, :waking_at) do
      {:ok, at} -> not is_nil(at)
      :error -> not is_nil(Inbox.next_waking(inst.id))
    end
  end

  # Outside queue mode an unreadable jobs file wakes the bot: it cannot be
  # asleep through a run no one can see. In queue mode a job it hides runs late
  # on the next wake, which hermes's HERMES_CRON_ONESHOT_LATE_S makes safe.
  defp cron_due?(inst, queue, opts) do
    case Keyword.get_lazy(opts, :cron, fn -> Idle.cron_wake_at(inst) end) do
      {:ok, nil} -> false
      {:ok, at} -> DateTime.compare(at, DateTime.utc_now()) != :gt
      :error -> not queue
    end
  end
end
