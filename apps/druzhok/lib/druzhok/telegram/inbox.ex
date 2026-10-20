defmodule Druzhok.Telegram.Inbox do
  @moduledoc """
  The `telegram_updates` queue: what Telegram pushed to druzhok for a
  webhook-mode bot, waiting for (or already handed to) the bot.

  A row is pending while `acked_at` is nil. The bot's 2xx sets it; a row the
  bot rejected as malformed, or that waited past Telegram's own 24 h
  retention, is set too, with `dropped_reason`.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Druzhok.Repo

  schema "telegram_updates" do
    field(:instance_id, :integer)
    field(:update_id, :integer)
    field(:payload, :string)
    field(:received_at, :utc_datetime_usec)
    field(:acked_at, :utc_datetime_usec)
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)
    field(:dropped_reason, :string)
  end

  @expire_after_s 24 * 60 * 60
  @prune_after_s 3 * 24 * 60 * 60

  @doc """
  Store one update. A redelivery of an `update_id` already stored is a no-op,
  so Telegram retrying a late ack cannot queue a message twice.
  """
  def enqueue(instance_id, update_id, payload)
      when is_integer(update_id) and is_binary(payload) do
    row = %{
      instance_id: instance_id,
      update_id: update_id,
      payload: payload,
      received_at: DateTime.utc_now(),
      attempts: 0
    }

    case Repo.insert_all(__MODULE__, [row],
           on_conflict: :nothing,
           conflict_target: [:instance_id, :update_id]
         ) do
      {n, _} when n in [0, 1] -> :ok
    end
  end

  @doc "The oldest pending row by Telegram's own order, or nil."
  def next_pending(instance_id) do
    from(u in __MODULE__,
      where: u.instance_id == ^instance_id and is_nil(u.acked_at),
      order_by: [asc: u.update_id],
      limit: 1
    )
    |> Repo.one()
  end

  def ack(%__MODULE__{id: id}), do: set(id, acked_at: DateTime.utc_now())

  def reject(%__MODULE__{id: id}, error),
    do: set(id, acked_at: DateTime.utc_now(), dropped_reason: "rejected", last_error: trim(error))

  def record_failure(%__MODULE__{id: id}, error) do
    from(u in __MODULE__, where: u.id == ^id)
    |> Repo.update_all(inc: [attempts: 1], set: [last_error: trim(error)])

    :ok
  end

  defp set(id, fields) do
    from(u in __MODULE__, where: u.id == ^id) |> Repo.update_all(set: fields)
    :ok
  end

  defp trim(error), do: error |> to_string() |> String.slice(0, 200)

  def pending_count(instance_id) do
    from(u in __MODULE__,
      where: u.instance_id == ^instance_id and is_nil(u.acked_at),
      select: count()
    )
    |> Repo.one()
  end

  @doc "`%{pending, oldest_received_at, last_error}` for the dashboard and smoke."
  def stats(instance_id) do
    from(u in __MODULE__,
      where: u.instance_id == ^instance_id and is_nil(u.acked_at),
      select: %{
        pending: count(),
        oldest_received_at: type(min(u.received_at), :utc_datetime_usec),
        last_error: max(u.last_error)
      }
    )
    |> Repo.one()
  end

  def drop_pending(instance_id, reason) do
    from(u in __MODULE__, where: u.instance_id == ^instance_id and is_nil(u.acked_at))
    |> Repo.update_all(set: [acked_at: DateTime.utc_now(), dropped_reason: reason])
  end

  @doc """
  Expire pending rows older than 24 h and delete handled rows older than 3 days.
  Returns `{expired, pruned}`.
  """
  def housekeep(instance_id, now \\ DateTime.utc_now()) do
    expire_before = DateTime.add(now, -@expire_after_s)
    prune_before = DateTime.add(now, -@prune_after_s)

    {expired, _} =
      from(u in __MODULE__,
        where:
          u.instance_id == ^instance_id and is_nil(u.acked_at) and u.received_at < ^expire_before
      )
      |> Repo.update_all(set: [acked_at: now, dropped_reason: "expired"])

    {pruned, _} =
      from(u in __MODULE__,
        where:
          u.instance_id == ^instance_id and not is_nil(u.acked_at) and u.acked_at < ^prune_before
      )
      |> Repo.delete_all()

    {expired, pruned}
  end
end
