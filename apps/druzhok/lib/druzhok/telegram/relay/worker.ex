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
    instead of dropping the queue; a successful start re-syncs the env and
    lifts it (the lifecycle controller keeps only a `wrong_owner` pause).
  - any other 4xx: this row is malformed; rejected, next row.

  The instance row is re-read before every step, so a secret rotation, a
  mode switch or a pause written by another BEAM takes effect at once.

  Rows wait while the bot is stopped (`!active`), being deleted or asleep
  (sleep/wake spec, "Relay changes"); for an asleep bot with a row that
  wakes it (`Inbox.next_waking/1`) the worker pokes the lifecycle controller,
  which wakes it. For a minute after a wake the retry
  backoff is capped at 1 s, so the first update is delivered as soon as the
  listener is up, long before systemd reports the unit ready. `quiesce/1`
  answers between delivery steps only, so once it returns no POST is in
  flight.
  """

  import Ecto.Query
  use GenServer, restart: :transient
  require Logger
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.{API, Inbox, ListenerOwner, Webhook}

  def key(instance_id), do: {:telegram_relay, instance_id}

  def start_link(instance_id),
    do:
      GenServer.start_link(__MODULE__, instance_id,
        name: {:via, Registry, {Druzhok.Registry, key(instance_id)}}
      )

  @impl true
  def init(instance_id) do
    send(self(), :work)
    Process.send_after(self(), :notices, opt(:notice_poll_ms))

    {:ok,
     %{
       id: instance_id,
       failing: false,
       backoff: opt(:backoff_min_ms),
       timer: nil,
       notices: %{},
       inflight: nil,
       quiescers: []
     }}
  end

  @impl true
  # Answered only between steps: the caller knows no POST is in flight, and
  # the next step reads the pause it has written.
  def handle_call(:quiesce, from, %{inflight: flight} = state) when not is_nil(flight),
    do: {:noreply, %{state | quiescers: [from | state.quiescers]}}

  def handle_call(:quiesce, _from, state), do: {:reply, :ok, state}

  @impl true
  # A new update must not cut a backoff short: the bot is down either way.
  def handle_info(:notify, %{failing: true} = state), do: {:noreply, state}
  def handle_info(:notify, state), do: step(state)
  def handle_info(:work, state), do: step(%{state | timer: nil})

  def handle_info({:delivered, instance, row, result}, state) do
    Enum.each(state.quiescers, &GenServer.reply(&1, :ok))
    handle_response(%{state | inflight: nil, quiescers: []}, instance, row, result)
  end

  def handle_info(:notices, state) do
    Process.send_after(self(), :notices, opt(:notice_poll_ms))
    {:noreply, refresh_notices(state)}
  end

  def handle_info({:notice_sent, sender, chat, ref, result}, state) do
    state = refresh_notices(state)
    case {state.notices[chat], result} do
      {%{ref: ^ref} = notice, {:ok, %{"message_id" => mid}}} ->
        send(sender, {:notice_kept, ref})
        {:noreply, put_in(state.notices[chat], %{notice | message_id: mid})}

      {_, {:ok, %{"message_id" => _mid}}} ->
        send(sender, {:notice_discarded, ref})
        {:noreply, state}

      _ ->
        Logger.warning("[relay] preparing notice failed")
        {:noreply, state}
    end
  end

  defp refresh_notices(state) do
    inst = Repo.get(Instance, state.id)

    rows =
      from(u in Inbox, where: u.instance_id == ^state.id and is_nil(u.acked_at)) |> Repo.all()

    waiting =
      if inst && inst.active && !inst.delete_requested && inst.telegram_mode == "webhook" do
        rows
        |> Enum.filter(& &1.wakes)
        |> Enum.reduce(%{}, fn row, chats ->
          case Druzhok.Lifecycle.Typing.chat_id(row.payload) do
            nil ->
              chats

            chat ->
              Map.update(chats, chat, row.received_at, &Enum.min([&1, row.received_at], DateTime))
          end
        end)
      else
        %{}
      end

    state =
      Enum.reduce(Map.keys(state.notices) -- Map.keys(waiting), state, &clear_notice(&2, &1))

    Enum.reduce(waiting, state, fn {chat, at}, state ->
      age = DateTime.diff(DateTime.utc_now(), at, :millisecond)
      after_ms = opt(:notice_after_ms)
      edit_ms = opt(:notice_edit_after_ms)

      case state.notices[chat] do
        nil when age >= after_ms ->
          ref = make_ref()
          worker = self()
          token = inst.telegram_token

          notice_task(fn ->
            monitor = Process.monitor(worker)
            result = API.send_message(token, chat, preparing(inst.language, false))
            send(worker, {:notice_sent, self(), chat, ref, result})

            case result do
              {:ok, %{"message_id" => mid}} ->
                receive do
                  {:notice_kept, ^ref} -> :ok
                  {:notice_discarded, ^ref} -> API.delete_message(token, chat, mid)
                  {:DOWN, ^monitor, :process, ^worker, _} -> API.delete_message(token, chat, mid)
                end

              _ ->
                :ok
            end

            Process.demonitor(monitor, [:flush])
            result
          end)

          put_in(state.notices[chat], %{
            ref: ref,
            token: token,
            message_id: :sending,
            edited: false
          })

        %{message_id: mid, edited: false} = notice when is_integer(mid) and age >= edit_ms ->
          notice_task(fn ->
            API.edit_message_text(notice.token, chat, mid, preparing(inst.language, true))
          end)

          put_in(state.notices[chat].edited, true)

        _ ->
          state
      end
    end)
  end

  defp preparing("ru", false), do: "⏳ Готовлюсь, немного подождите…"
  defp preparing("ru", true), do: "⏳ Ещё немного…"
  defp preparing(_, false), do: "⏳ Getting ready, please wait…"
  defp preparing(_, true), do: "⏳ Almost there…"

  defp clear_notice(state, nil), do: state

  defp clear_notice(state, chat) do
    case state.notices[chat] do
      %{message_id: mid, token: token} when is_integer(mid) ->
        notice_task(fn -> API.delete_message(token, chat, mid) end)

      _ ->
        :ok
    end

    %{state | notices: Map.delete(state.notices, chat)}
  end

  defp notice_task(fun) do
    Task.start(fn ->
      try do
        case fun.() do
          {:error, _} -> Logger.warning("[relay] preparing notice API call failed")
          _ -> :ok
        end
      rescue
        _ -> Logger.warning("[relay] preparing notice API call failed")
      end
    end)
  end

  defp step(%{inflight: flight} = state) when not is_nil(flight), do: {:noreply, state}

  defp step(state) do
    case Repo.get(Instance, state.id) do
      %Instance{telegram_mode: "webhook"} = instance ->
        deliver(state, instance)

      _ ->
        state = Enum.reduce(Map.keys(state.notices), state, &clear_notice(&2, &1))
        {:stop, :normal, state}
    end
  end

  defp deliver(state, instance) do
    cond do
      not instance.active or instance.delete_requested ->
        schedule(state, opt(:paused_poll_ms))

      instance.sleeping ->
        # notify/1 brings a new row's worker back here; the poke wakes the bot.
        # Rows that do not wake it (Telegram.Addressed) wait for the next wake.
        if Inbox.next_waking(instance.id) do
          Druzhok.Lifecycle.poke(instance.id)
          schedule(state, opt(:paused_poll_ms))
        else
          schedule(state, opt(:idle_poll_ms))
        end

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
        worker = self()

        Task.start(fn ->
          result =
            try do
              post(instance, port, row)
            rescue
              error -> {:error, error}
            catch
              :exit, _ -> {:error, RuntimeError.exception("delivery task exited")}
            end

          send(worker, {:delivered, instance, row, result})
        end)

        {:noreply, %{state | inflight: row.id}}

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
    Druzhok.Cabinet.delivered(instance.id, row.payload)
    state = clear_notice(state, Druzhok.Lifecycle.Typing.chat_id(row.payload))
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
    state = clear_notice(state, Druzhok.Lifecycle.Typing.chat_id(row.payload))
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

    cap = if just_woken?(instance), do: opt(:waking_backoff_ms), else: opt(:backoff_max_ms)

    schedule(
      %{state | failing: true, backoff: min(state.backoff * 2, cap)},
      min(state.backoff, cap)
    )
  end

  defp just_woken?(%Instance{woke_at: %DateTime{} = at}),
    do: DateTime.diff(DateTime.utc_now(), at) < 60

  defp just_woken?(_), do: false

  defp schedule(state, ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :work, ms)}}
  end

  @defaults [
    notice_poll_ms: 250,
    notice_after_ms: 3_000,
    notice_edit_after_ms: 60_000,
    backoff_min_ms: 1_000,
    backoff_max_ms: 30_000,
    waking_backoff_ms: 1_000,
    paused_poll_ms: 2_000,
    idle_poll_ms: 30_000,
    timeout_ms: 10_000,
    wrong_owner_pause_s: 30,
    rejected_pause_s: 5 * 60
  ]

  defp opt(key),
    do: Keyword.get(Application.get_env(:druzhok, :telegram_relay, []), key, @defaults[key])
end
