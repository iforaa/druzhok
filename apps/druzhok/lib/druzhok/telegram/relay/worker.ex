defmodule Druzhok.Telegram.Relay.Worker do
  @moduledoc """
  Delivers one bot's pending updates to its PTB webhook server, one at a
  time in `update_id` order.

  Outcomes of a POST (PTB `TelegramHandler`):

  - 2xx: acked, next row.
  - refused, timeout, 429, 5xx, no listener: the bot is (re)starting; retry
    the same row with backoff, so the head of the line waits.
  - 403, 404: the secret, content type or path disagree with the bot's env.
    That is the same for every row, so the worker pauses (`rejected_config`)
    instead of dropping the queue; a restart re-syncs the env and resumes it.
  - any other 4xx: this row is malformed; rejected, next row.

  The instance row is re-read before every step, so a secret rotation, a
  mode switch or a pause written by another BEAM takes effect at once.
  """

  use GenServer, restart: :transient
  require Logger
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.{Inbox, ListenerOwner, Webhook}

  @housekeep_ms 60 * 60 * 1000

  def key(instance_id), do: {:telegram_relay, instance_id}

  def start_link(instance_id),
    do:
      GenServer.start_link(__MODULE__, instance_id,
        name: {:via, Registry, {Druzhok.Registry, key(instance_id)}}
      )

  @impl true
  def init(instance_id) do
    send(self(), :work)

    {:ok,
     %{
       id: instance_id,
       failing: false,
       backoff: opt(:backoff_min_ms),
       timer: nil,
       housekept_at: nil
     }}
  end

  @impl true
  # A new update must not cut a backoff short: the bot is down either way.
  def handle_info(:notify, %{failing: true} = state), do: {:noreply, state}
  def handle_info(:notify, state), do: step(state)
  def handle_info(:work, state), do: step(%{state | timer: nil})

  defp step(state) do
    case Repo.get(Instance, state.id) do
      %Instance{telegram_mode: "webhook"} = instance ->
        state |> housekeep(instance) |> deliver(instance)

      _ ->
        {:stop, :normal, state}
    end
  end

  defp deliver(state, instance) do
    cond do
      Webhook.paused(instance) ->
        schedule(state, opt(:paused_poll_ms))

      row = Inbox.next_pending(instance.id) ->
        deliver_row(state, instance, row)

      true ->
        # notify/1 wakes us for new rows; the poll only covers a lost notify.
        schedule(state, opt(:idle_poll_ms))
    end
  end

  defp deliver_row(state, instance, row) do
    port = Webhook.port(instance)

    case owner_check().check(instance.name, port) do
      :ok ->
        handle_response(state, instance, row, post(instance, port, row))

      {:error, {:wrong_owner, uids}} ->
        Logger.error(
          "[relay] #{instance.name}: port #{port} is held by uid #{inspect(uids)}, not bot-#{instance.name}; paused"
        )

        Webhook.pause(instance.id, :wrong_owner, opt(:wrong_owner_pause_s))
        schedule(state, 0)

      {:error, reason} ->
        retry(state, instance, row, "no listener (#{inspect(reason)})")
    end
  end

  defp post(instance, port, row) do
    headers = [
      {"content-type", "application/json"},
      {"x-telegram-bot-api-secret-token", instance.telegram_webhook_secret || ""}
    ]

    Finch.build(:post, base_url(port) <> Webhook.path(instance), headers, row.payload)
    |> Finch.request(Druzhok.LocalFinch, receive_timeout: opt(:timeout_ms))
  end

  defp owner_check, do: Application.get_env(:druzhok, :telegram_listener_owner, ListenerOwner)

  defp base_url(port),
    do: Application.get_env(:druzhok, :telegram_relay_base_url) || "http://127.0.0.1:#{port}"

  defp handle_response(state, instance, row, {:ok, %Finch.Response{status: status}})
       when status in 200..299 do
    Inbox.ack(row)
    if state.failing, do: Logger.info("[relay] #{instance.name}: delivering again")
    schedule(%{state | failing: false, backoff: opt(:backoff_min_ms)}, 0)
  end

  defp handle_response(state, instance, row, {:ok, %Finch.Response{status: status}})
       when status in [403, 404] do
    Inbox.record_failure(row, "HTTP #{status}")

    Logger.error(
      "[relay] #{instance.name}: bot answered #{status} (secret, content type or path out of sync); paused, queue kept"
    )

    Webhook.pause(instance.id, :rejected_config, opt(:rejected_pause_s))
    schedule(%{state | failing: false}, 0)
  end

  defp handle_response(state, instance, row, {:ok, %Finch.Response{status: status}})
       when status in 400..499 and status != 429 do
    Logger.warning(
      "[relay] #{instance.name}: bot rejected update #{row.update_id} (HTTP #{status}); dropped"
    )

    Inbox.reject(row, "HTTP #{status}")
    schedule(state, 0)
  end

  defp handle_response(state, instance, row, {:ok, %Finch.Response{status: status}}),
    do: retry(state, instance, row, "HTTP #{status}")

  defp handle_response(state, instance, row, {:error, error}),
    do: retry(state, instance, row, Exception.message(error))

  defp retry(state, instance, row, error) do
    Inbox.record_failure(row, error)

    unless state.failing,
      do: Logger.warning("[relay] #{instance.name}: cannot deliver (#{error}); retrying")

    next = min(state.backoff * 2, opt(:backoff_max_ms))
    schedule(%{state | failing: true, backoff: next}, state.backoff)
  end

  defp housekeep(%{housekept_at: at} = state, instance) do
    now = System.monotonic_time(:millisecond)

    if at == nil or now - at >= @housekeep_ms do
      case Inbox.housekeep(instance.id) do
        {0, _} ->
          :ok

        {expired, _} ->
          Logger.warning(
            "[relay] #{instance.name}: #{expired} update(s) expired after 24 h undelivered"
          )
      end

      %{state | housekept_at: now}
    else
      state
    end
  end

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :work, ms)}}
  end

  @defaults [
    backoff_min_ms: 1_000,
    backoff_max_ms: 30_000,
    paused_poll_ms: 2_000,
    idle_poll_ms: 30_000,
    timeout_ms: 10_000,
    wrong_owner_pause_s: 30,
    rejected_pause_s: 5 * 60
  ]

  defp opt(key),
    do: Keyword.get(Application.get_env(:druzhok, :telegram_relay, []), key, @defaults[key])
end
