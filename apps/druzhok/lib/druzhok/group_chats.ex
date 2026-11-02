defmodule Druzhok.GroupChats do
  @moduledoc """
  Which Telegram groups a bot may answer in (CleoHub release spec, PR M).

  Everything is decided here, called by `TelegramWebhookController` before
  `Inbox.enqueue`: the relay is too late, since a queued row can wake a sleeping
  bot. `gate/3` answers `:drop` for a group that is not approved, owner's own
  messages included, and for an approved group past its rate limits. A dropped
  update is acknowledged to Telegram and stored nowhere, so it wakes nothing and
  costs nothing.

  The first update from an unknown group makes a `pending` row and tells the owner
  (`Druzhok.Cabinet`). Only the owner's panel changes a status (`decide/3`).

  Hermes reads the approved ids from `DRUZHOK_GROUP_CHATS` at start and refuses
  any other group (`env_value/1`). Approving restarts an awake bot at once, because
  hermes would refuse the chat until then, and a quiet restart can wait as long as
  the group keeps talking. Blocking or removing holds here at once, and reaches the
  env through the usual `settings_seq` quiet restart.
  """

  use Ecto.Schema
  import Ecto.Query
  alias Druzhok.{BotManager, Cabinet, Instance, Repo, Settings}
  alias Druzhok.Telegram.{Addressed, Inbox, Webhook}

  schema "group_chats" do
    field(:instance_id, :integer)
    field(:chat_id, :integer)
    field(:title, :string)
    field(:status, :string, default: "pending")
    field(:decided_by, :integer)
    field(:notified_at, :utc_datetime_usec)
    field(:rate_notice_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @title_limit 255

  # Anyone on Telegram can add a bot to a group. This bounds the rows and the owner's
  # notes one stranger can cause; a group past it gets no row until some are decided.
  @max_pending 50

  @minute 60
  @hour 3600

  @message_keys ~w(message edited_message channel_post edited_channel_post)

  # --- The gate ----------------------------------------------------------------

  @doc """
  `:pass` to store the update as usual, or `:drop` to acknowledge it and store nothing.
  """
  def gate(%Instance{} = inst, update_id, update) when is_map(update) do
    case chat_of(update) do
      :none -> if chatless_poll?(update), do: :drop, else: :pass
      :private -> :pass
      {:group, %{"id" => id} = chat} when is_integer(id) -> group(inst, update_id, update, chat)
      {:group, _malformed} -> :drop
    end
  end

  @doc """
  Where an update's chat is, whatever its type: `update.<kind>.chat` (messages,
  membership, reactions, boosts, join requests), `update.<kind>.message.chat`
  (callback queries) or `update.poll_answer.voter_chat`. Looked for generically, so
  a type Telegram adds later is gated too. Only `"private"` counts as private: a chat
  of any other or missing type is gated.
  """
  def chat_of(update) when is_map(update) do
    update
    |> Enum.find_value(fn
      {_kind, %{"chat" => %{} = chat}} -> chat
      {_kind, %{"message" => %{"chat" => %{} = chat}}} -> chat
      {_kind, %{"voter_chat" => %{} = chat}} -> chat
      _ -> nil
    end)
    |> case do
      nil -> :none
      %{"type" => "private"} -> :private
      chat -> {:group, chat}
    end
  end

  # A poll update names no chat, so it could come from any group, and hermes has no
  # handler for it: it could only wake the bot for nothing.
  defp chatless_poll?(update), do: Map.has_key?(update, "poll") or Map.has_key?(update, "poll_answer")

  defp group(inst, update_id, update, chat) do
    case refresh_title(Repo.get_by(__MODULE__, instance_id: inst.id, chat_id: chat["id"]), chat) do
      nil ->
        if bot_left?(update), do: :ok, else: first_seen(inst, chat)
        :drop

      %__MODULE__{status: "approved"} = row ->
        limit(inst, row, update_id, update)

      %__MODULE__{status: "pending"} = row ->
        tell_owner(row)
        :drop

      _blocked ->
        :drop
    end
  end

  # The note about a bot leaving a group nobody decided on would only confuse.
  defp bot_left?(%{"my_chat_member" => %{"new_chat_member" => %{"status" => status}}}),
    do: status in ["left", "kicked"]

  defp bot_left?(_update), do: false

  defp first_seen(inst, chat) do
    if pending_count(inst.id) < @max_pending do
      now = DateTime.utc_now()

      Repo.insert_all(
        __MODULE__,
        [
          %{
            instance_id: inst.id,
            chat_id: chat["id"],
            title: title(chat),
            status: "pending",
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:instance_id, :chat_id]
      )

      tell_owner(%__MODULE__{instance_id: inst.id, chat_id: chat["id"]})
    end
  end

  defp pending_count(instance_id) do
    from(g in __MODULE__, where: g.instance_id == ^instance_id and g.status == "pending")
    |> Repo.aggregate(:count)
  end

  # Until it went through: a lost cast or a Telegram outage is retried on the
  # group's next update. Cabinet re-reads the row, so a burst sends one note.
  defp tell_owner(%__MODULE__{notified_at: nil} = row),
    do: Cabinet.group_seen(row.instance_id, row.chat_id)

  defp tell_owner(_row), do: :ok

  defp refresh_title(nil, _chat), do: nil

  defp refresh_title(row, chat) do
    case title(chat) do
      new when is_binary(new) and new != row.title ->
        from(g in __MODULE__, where: g.id == ^row.id)
        |> Repo.update_all(set: [title: new, updated_at: DateTime.utc_now()])

        %{row | title: new}

      _ ->
        row
    end
  end

  defp title(%{"title" => t}) when is_binary(t), do: String.slice(t, 0, @title_limit)
  defp title(_chat), do: nil

  # --- Rate limits -------------------------------------------------------------

  # Only what would be answered counts: chatter a mention-only bot skips neither
  # counts nor is limited, and stays queued as before.
  defp limit(inst, row, update_id, update) do
    case answered_message(inst, update) do
      nil ->
        :pass

      msg ->
        case record(inst.id, row.chat_id, sender(msg), update_id) do
          :ok ->
            :pass

          :over ->
            notice(row)
            :drop
        end
    end
  end

  defp answered_message(inst, update) do
    msg = Enum.find_value(@message_keys, &update[&1])
    if is_map(msg) and Addressed.wakes?(inst, update), do: msg
  end

  # Someone posting as a channel or as the group has no `from` of their own.
  defp sender(msg) do
    case get_in(msg, ["sender_chat", "id"]) || get_in(msg, ["from", "id"]) do
      id when is_integer(id) -> id
      _ -> 0
    end
  end

  # One statement, so two updates at once cannot both take the last place. An
  # attempt over the limit is not recorded: someone who keeps sending is not kept
  # out longer for it, and does not use up the group's hour. The same update_id
  # again (Telegram retrying after our 500) passes without counting twice.
  defp record(instance_id, chat_id, user_id, update_id) do
    now = System.system_time(:second)

    sql = """
    INSERT INTO group_rate_events (instance_id, chat_id, user_id, update_id, at)
    SELECT ?1, ?2, ?3, ?4, ?5
    WHERE (SELECT count(*) FROM group_rate_events
           WHERE instance_id = ?1 AND chat_id = ?2 AND user_id = ?3 AND at > ?6) < ?7
      AND (SELECT count(*) FROM group_rate_events
           WHERE instance_id = ?1 AND chat_id = ?2 AND at > ?8) < ?9
    ON CONFLICT (instance_id, update_id) DO NOTHING
    RETURNING id
    """

    params = [
      instance_id,
      chat_id,
      user_id,
      update_id,
      now,
      now - @minute,
      Settings.group_rate_user_per_min(),
      now - @hour,
      Settings.group_rate_chat_per_hour()
    ]

    case Repo.query!(sql, params).rows do
      [_] -> :ok
      [] -> if counted?(instance_id, update_id), do: :ok, else: :over
    end
  end

  defp counted?(instance_id, update_id) do
    from(e in "group_rate_events",
      where: e.instance_id == ^instance_id and e.update_id == ^update_id
    )
    |> Repo.exists?()
  end

  # At most one an hour per chat, marked before the send and kept in the row, so a
  # restart does not repeat it. The notice wakes nothing: a bot's own message is no update.
  defp notice(row) do
    now = DateTime.utc_now()
    since = DateTime.add(now, -@hour)

    {marked, _} =
      from(g in __MODULE__,
        where:
          g.id == ^row.id and (is_nil(g.rate_notice_at) or g.rate_notice_at <= ^since)
      )
      |> Repo.update_all(set: [rate_notice_at: now])

    if marked == 1, do: Cabinet.group_over_limit(row.instance_id, row.chat_id)
  end

  @doc "Forgets rate events too old to count. Hourly, from `Relay.Housekeeper`."
  def prune_rate_events(now \\ System.system_time(:second)) do
    before = now - @hour

    {pruned, _} = from(e in "group_rate_events", where: e.at <= ^before) |> Repo.delete_all()
    pruned
  end

  # --- Env ---------------------------------------------------------------------

  @doc """
  `DRUZHOK_GROUP_CHATS`: the approved chat ids, comma-separated, no spaces. Empty
  for a polling bot: druzhok's gate never sees its updates, so hermes refuses every group.
  """
  def env_value(instance) do
    id = Map.get(instance, :id)

    if is_integer(id) and Webhook.webhook?(instance) do
      from(g in __MODULE__,
        where: g.instance_id == ^id and g.status == "approved",
        order_by: g.chat_id,
        select: g.chat_id
      )
      |> Repo.all()
      |> Enum.join(",")
    else
      ""
    end
  end

  # --- The owner's decisions ---------------------------------------------------

  @doc "The bot's groups for the panel: those waiting first."
  def list(%Instance{id: id}) do
    from(g in __MODULE__, where: g.instance_id == ^id)
    |> Repo.all()
    |> Enum.sort_by(&{status_rank(&1.status), &1.title || "", &1.chat_id})
    |> Enum.map(&%{chat_id: &1.chat_id, title: &1.title, status: &1.status})
  end

  defp status_rank("pending"), do: 0
  defp status_rank("approved"), do: 1
  defp status_rank(_), do: 2

  @doc """
  The owner's `"approve"`, `"block"` or `"remove"`. Returns `{:ok, instance}`, or
  `{:error, :not_found | :invalid_action | :polling}`. Repeating a decision changes
  nothing. Only a change to the approved list asks for a restart: a stranger's group
  being blocked is no reason to restart anyone's bot.
  """
  def decide(%Instance{} = inst, chat_id, action) when action in ~w(approve block remove) do
    :global.trans({{__MODULE__, inst.id}, self()}, fn ->
      case Repo.get_by(__MODULE__, instance_id: inst.id, chat_id: chat_id) do
        nil -> {:error, :not_found}
        row -> apply_decision(inst, row, action)
      end
    end)
  end

  def decide(%Instance{}, _chat_id, _action), do: {:error, :invalid_action}

  defp apply_decision(inst, row, "approve") do
    cond do
      not Webhook.webhook?(inst) ->
        {:error, :polling}

      row.status == "approved" ->
        {:ok, Repo.get!(Instance, inst.id)}

      true ->
        {:ok, latest} =
          Repo.transaction(fn ->
            set_status(row, "approved", inst.owner_telegram_id)
            bump_settings(inst.id)
            Repo.get!(Instance, inst.id)
          end)

        # A sleeping or stopped bot reads the list at its next start.
        if latest.active and not latest.sleeping and not latest.delete_requested,
          do: BotManager.restart(latest.name)

        {:ok, Repo.get!(Instance, inst.id)}
    end
  end

  defp apply_decision(inst, row, "block") do
    if row.status != "blocked" do
      Repo.transaction(fn ->
        set_status(row, "blocked", inst.owner_telegram_id)
        if row.status == "approved", do: bump_settings(inst.id)
      end)

      drop_queued(inst.id, row.chat_id)
    end

    {:ok, Repo.get!(Instance, inst.id)}
  end

  defp apply_decision(inst, row, "remove") do
    Repo.transaction(fn ->
      Repo.delete!(row)
      if row.status == "approved", do: bump_settings(inst.id)
    end)

    drop_queued(inst.id, row.chat_id)
    {:ok, Repo.get!(Instance, inst.id)}
  end

  defp set_status(row, status, decided_by) do
    from(g in __MODULE__, where: g.id == ^row.id)
    |> Repo.update_all(
      set: [status: status, decided_by: decided_by, updated_at: DateTime.utc_now()]
    )
  end

  # The lifecycle controller restarts an awake bot at a quiet moment, and any start
  # applies it; a sleeping bot is not woken for this.
  defp bump_settings(instance_id) do
    from(i in Instance, where: i.id == ^instance_id)
    |> Repo.update_all(inc: [settings_seq: 1], set: [settings_saved_at: DateTime.utc_now()])
  end

  # What was queued before the decision would still wake a sleeping bot, and an awake
  # one still has the chat in its env: "at once" has to include these.
  defp drop_queued(instance_id, chat_id) do
    Inbox.drop_pending_where(
      instance_id,
      fn update ->
        match?({:group, %{"id" => ^chat_id}}, chat_of(update))
      end,
      "group_refused"
    )
  end
end
