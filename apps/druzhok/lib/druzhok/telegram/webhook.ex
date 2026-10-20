defmodule Druzhok.Telegram.Webhook do
  @moduledoc """
  Per-bot Telegram delivery mode (docs/superpowers/specs/2026-10-20-telegram-webhook-relay-design.md).

  A bot in `"polling"` mode long-polls `getUpdates` itself. A bot in
  `"webhook"` mode runs hermes's PTB webhook server on `127.0.0.1:<port>`,
  registers `public_url/1` with Telegram on every connect, and receives its
  updates from `Druzhok.Telegram.Relay` out of the `telegram_updates` queue.

  Every bot gets a port (`20000 + id`), polling ones too: `druzhok-ctl` turns
  it into the nftables `uid . port` element, so only the bot's own uid can
  answer druzhok from that port, and `Druzhok.Telegram.ListenerOwner` checks
  the listener's uid before the relay sends anything to it.

  The relay pause is a column, not process state, so a one-off
  `ops/druzhok-run.sh` BEAM can pause and resume the relay that runs inside
  druzhok.service.
  """

  import Ecto.Query
  alias Druzhok.{Instance, Repo}
  alias Druzhok.Telegram.Inbox

  @port_base 20_000
  # Ports 20000-20999: the block checked free on the box (spec, "Port"). The
  # nft set and the systemd drop-in take any port, so raising this means
  # checking the next block is free first.
  @max_id 999
  @path_prefix "/telegram/webhook/"
  @stop_pause_s 5 * 60

  @modes ~w(polling webhook)
  def modes, do: @modes

  def webhook?(instance), do: Map.get(instance, :telegram_mode) == "webhook"

  @doc "The bot's loopback port, or nil when its id is outside the isolated range."
  def port(%{id: id}) when is_integer(id) and id > 0 and id <= @max_id, do: @port_base + id
  def port(_), do: nil

  def path(%{name: name}), do: @path_prefix <> name

  @doc "The URL hermes registers with Telegram (`setWebhook`)."
  def public_url(instance), do: "https://" <> public_host() <> path(instance)

  defp public_host,
    do: System.get_env("PHX_HOST") || Application.get_env(:druzhok, :public_host, "localhost")

  def generate_secret, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  @doc """
  Switch a bot's mode. Takes effect on its next `BotManager.restart/1`.
  Returns `{:ok, instance, dropped_count}`.

  Leaving webhook mode while updates are still queued would strand them (a
  polling bot cannot be relayed to), so it is refused unless `force: true`,
  which drops them and reports how many.
  """
  def set_mode(name, mode, opts \\ []) when mode in @modes do
    case Repo.get_by(Instance, name: name) do
      nil -> {:error, :not_found}
      instance -> do_set_mode(instance, mode, Keyword.get(opts, :force, false))
    end
  end

  defp do_set_mode(instance, "webhook", _force) do
    if port(instance) do
      secret = instance.telegram_webhook_secret || generate_secret()

      with {:ok, inst} <-
             save(instance, %{telegram_mode: "webhook", telegram_webhook_secret: secret}),
           do: {:ok, inst, 0}
    else
      {:error, {:id_out_of_range, instance.id}}
    end
  end

  defp do_set_mode(instance, "polling", false) do
    if to_polling_if_drained(instance.id),
      do: {:ok, Repo.get!(Instance, instance.id), 0},
      else: {:error, {:pending, Inbox.pending_count(instance.id)}}
  end

  # A row stored between the drop and the switch makes the switch a no-op;
  # drop again. Inbox.enqueue/3 stores nothing once the mode is polling.
  defp do_set_mode(instance, "polling", true), do: force_polling(instance.id, 0, 3)

  defp force_polling(_id, _dropped, 0), do: {:error, :busy}

  defp force_polling(id, dropped, tries) do
    {n, _} = Inbox.drop_pending(id, "mode_switch")

    if to_polling_if_drained(id),
      do: {:ok, Repo.get!(Instance, id), dropped + n},
      else: force_polling(id, dropped + n, tries - 1)
  end

  # One statement, so it cannot interleave with Inbox.enqueue/3: either a row
  # committed first and this changes nothing, or the mode is polling first and
  # that insert stores nothing.
  defp to_polling_if_drained(id) do
    pending =
      from(u in Inbox, where: u.instance_id == parent_as(:instance).id and is_nil(u.acked_at))

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {n, _} =
      from(i in Instance, as: :instance, where: i.id == ^id and not exists(pending))
      |> Repo.update_all(set: [telegram_mode: "polling", updated_at: now])

    n == 1
  end

  defp save(instance, attrs), do: instance |> Instance.changeset(attrs) |> Repo.update()

  @doc """
  Hold delivery for a bot. `:stopping` (from `BotManager.stop/1`) lifts by
  itself after 5 min; the relay's own faults pass their retry time.
  """
  def pause(instance_id, reason, seconds \\ @stop_pause_s) do
    until = DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)

    from(i in Instance, where: i.id == ^instance_id)
    |> Repo.update_all(
      set: [telegram_relay_paused_until: until, telegram_relay_pause_reason: to_string(reason)]
    )

    :ok
  end

  @doc "Clear any pause; a fault that is still there pauses again on the next attempt."
  def resume(instance_id) do
    from(i in Instance, where: i.id == ^instance_id)
    |> Repo.update_all(set: [telegram_relay_paused_until: nil, telegram_relay_pause_reason: nil])

    :ok
  end

  @doc "`{reason, until}` while paused, else nil."
  def paused(%{
        telegram_relay_paused_until: %DateTime{} = until,
        telegram_relay_pause_reason: reason
      }) do
    if DateTime.compare(until, DateTime.utc_now()) == :gt, do: {reason, until}, else: nil
  end

  def paused(_), do: nil
end
