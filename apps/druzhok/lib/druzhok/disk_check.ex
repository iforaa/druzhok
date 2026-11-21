defmodule Druzhok.DiskCheck do
  @moduledoc """
  Every 10 minutes: one `Host.disk_all/0` read, its figures written to each
  bot's row (`disk_used_kb`, `disk_limit_kb`, `disk_files`, `disk_file_limit`,
  `disk_checked_at`), and the owner and the operator told by the state table
  in `docs/superpowers/specs/2026-11-21-bot-disk-limit-design.md`, "The disk check".

  It runs only where druzhok.service serves (`DruzhokWeb.Application`, beside
  `Druzhok.Cabinet` and `Druzhok.Lifecycle`), never in an `ops/druzhok` or
  `druzhok-run.sh` BEAM, so there is one sender of each message.

  The owner's messages go through the bot's own token, as Cabinet's «Поддержка
  ответила» does, which never wakes or restarts the bot. `disk_warned` is
  written once the message is settled: sent, refused for good (the owner
  blocked the bot), or the bot has no owner or no token. A failure that may
  pass writes nothing, and the next check sends again. The operator is told
  through the superbot (`manager_bot_token`) at `operator_telegram_id`, once per
  full episode: `disk_operator_alerted_at` is set when that send succeeds and
  cleared when the bot drops back below 90%.

  It reports two conditions itself, at most once an hour each, in the log and
  to the operator: quotas that were on and are now off (only once it has seen
  them on, the settings row `disk_quota_seen`), and bots with no limit while
  they should have one.
  """

  use GenServer
  require Logger
  import Ecto.Query
  alias Druzhok.{Cabinet, DiskLimit, Host, Instance, Repo, Settings}
  alias Druzhok.Telegram.API

  @every_ms 10 * 60 * 1000
  # The first check soon after a boot, not 10 minutes into it.
  @first_ms 60 * 1000
  @report_every_s 3600

  @warn_size "Память бота почти заполнена: ~used из ~limit. Попросите бота удалить ненужные файлы."
  @warn_files "У бота почти закончилось место под файлы: ~used из ~limit. Попросите бота удалить ненужные файлы."
  @full "Память бота заполнена, он не может сохранять новое. Напишите в поддержку: Кабинет → Поддержка."

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    Process.send_after(self(), :check, Keyword.get(opts, :first_ms, @first_ms))
    {:ok, %{reported: %{}, every_ms: Keyword.get(opts, :every_ms, @every_ms)}}
  end

  @impl true
  def handle_info(:check, state) do
    # Timed from the end of a check, so a slow one never overlaps the next.
    state =
      try do
        run(state, DateTime.utc_now())
      rescue
        e ->
          Logger.error("[disk] check failed: #{Exception.message(e)}")
          state
      end

    Process.send_after(self(), :check, state.every_ms)
    {:noreply, state}
  end

  @doc """
  One check, synchronously. `state` carries when each self-report was last
  made (`%{reported: %{}}` to start); the new one is returned.
  """
  def run(state \\ %{reported: %{}}, now \\ DateTime.utc_now()) do
    case Host.disk_all() do
      :unknown ->
        state

      :off ->
        quotas_off(state, now)

      {:ok, disks} ->
        quotas_on(disks, state, now)

      {:error, reason} ->
        Logger.error("[disk] cannot read disk use: #{inspect(reason)}")
        state
    end
  end

  # --- quotas off -------------------------------------------------------------

  # Usage is unknown, so the last readings are dropped rather than shown as
  # current. Warning states stay as they are, for when quotas come back.
  defp quotas_off(state, now) do
    put_quota("off")

    from(i in Instance, where: not is_nil(i.disk_checked_at))
    |> Repo.update_all(
      set: [
        disk_used_kb: nil,
        disk_limit_kb: nil,
        disk_files: nil,
        disk_file_limit: nil,
        disk_checked_at: nil
      ]
    )

    # Silent until quotas were seen on once: nothing warns between the deploy
    # and the window, or on a box without a data disk. `bot_disk_mb=off` is
    # the operator's own choice.
    if Settings.get("disk_quota_seen") && Settings.bot_disk_mb() != :off,
      do:
        report(
          state,
          :off,
          now,
          "Квоты на диске /data были включены и теперь выключены: лимиты ботов не действуют. " <>
            "Проверьте usrquota в /etc/fstab и смонтируйте /data заново."
        ),
      else: state
  end

  # --- quotas on --------------------------------------------------------------

  defp quotas_on(disks, state, now) do
    unless Settings.get("disk_quota_seen"), do: Settings.set("disk_quota_seen", "1")
    put_quota("on")
    checked_at = DateTime.truncate(now, :second)

    bots =
      from(i in Instance, where: i.delete_requested == false, order_by: i.name)
      |> Repo.all()
      |> Enum.filter(&Map.has_key?(disks, &1.name))

    Enum.each(bots, fn inst ->
      try do
        check_bot(inst, disks[inst.name], checked_at)
      rescue
        e -> Logger.error("[disk] #{inst.name}: #{Exception.message(e)}")
      end
    end)

    case for(inst <- bots, unlimited?(inst, disks[inst.name]), do: inst.name) do
      [] ->
        state

      names ->
        report(
          state,
          :unlimited,
          now,
          "У ботов нет лимита на диске, хотя должен быть: #{Enum.join(names, ", ")}. " <>
            "Поставить: sudo ops/druzhok disk-apply"
        )
    end
  end

  defp unlimited?(inst, reading),
    do: DiskLimit.pct(reading) == nil and DiskLimit.limit(inst) != :off

  defp check_bot(inst, r, checked_at) do
    set(inst.id,
      disk_used_kb: r.used_kb,
      disk_limit_kb: r.limit_kb,
      disk_files: r.files,
      disk_file_limit: r.file_limit,
      disk_checked_at: checked_at
    )

    warned =
      case transition(inst.disk_warned, DiskLimit.pct(r)) do
        {nil, new} ->
          if new != inst.disk_warned, do: write_state(inst, new)
          new

        {message, new} ->
          case tell_owner(inst, message, r) do
            :settled ->
              write_state(inst, new)
              new

            :retry ->
              inst.disk_warned
          end
      end

    # Any check that finds the bot full and the operator not yet told about
    # this episode, so it survives a restart and is retried until it gets through.
    if warned == "full" and is_nil(inst.disk_operator_alerted_at) and DiskLimit.pct(r) != nil do
      if tell_operator(operator_alert(inst, r)) == :ok,
        do: set(inst.id, disk_operator_alerted_at: DateTime.utc_now())
    end
  end

  # Leaving "full" ends the episode: the next one alerts the operator again.
  defp write_state(inst, new) do
    if inst.disk_warned == "full" and new != "full",
      do: set(inst.id, disk_warned: new, disk_operator_alerted_at: nil),
      else: set(inst.id, disk_warned: new)
  end

  @doc """
  The state table: `{message, new_state}` for the bot's state and how full it
  is now (nil: no limit). `message` is `:warn` (80%), `:full` or nil. A bot
  that jumps straight past 98% gets the full message alone. A bot with no
  limit (`bot_disk_mb=off`, or one cleared by hand) cannot be full or nearly
  so: its state is cleared, which ends a full episode and its pending alert.
  """
  def transition(_state, nil), do: {nil, nil}
  def transition(state, pct) when state in [nil, "80"] and pct >= 98, do: {:full, "full"}
  def transition(nil, pct) when pct >= 80, do: {:warn, "80"}
  def transition("full", pct) when pct < 90, do: {nil, "80"}
  def transition("80", pct) when pct < 70, do: {nil, nil}
  def transition(state, _pct) when state in [nil, "80", "full"], do: {nil, state}
  # A value the table does not know is no warning yet.
  def transition(_other, pct), do: transition(nil, pct)

  @doc "The owner's text for `:warn` (by whichever of size and files is fuller) or `:full`."
  def owner_text(:full, _r), do: @full

  def owner_text(:warn, r) do
    {template, used, limit} =
      case DiskLimit.fuller(r) do
        :files ->
          {@warn_files, DiskLimit.count(r.files), DiskLimit.count(r.file_limit)}

        _ ->
          {@warn_size, DiskLimit.size(r.used_kb), DiskLimit.size(r.limit_kb)}
      end

    template |> String.replace("~used", used) |> String.replace("~limit", limit)
  end

  # :settled or :retry, as Cabinet's support note.
  defp tell_owner(%Instance{telegram_token: token, owner_telegram_id: owner} = inst, message, r)
       when is_binary(token) and token != "" and is_integer(owner) do
    case API.send_message(token, owner, owner_text(message, r)) do
      {:ok, _} ->
        Logger.info("[disk] #{inst.name}: told the owner (#{message})")
        :settled

      {:error, reason} ->
        if Cabinet.undeliverable?(reason) do
          Logger.info("[disk] #{inst.name}: owner message undeliverable (#{short(reason)})")
          :settled
        else
          Logger.warning("[disk] #{inst.name}: owner message not sent (#{short(reason)})")
          :retry
        end
    end
  end

  defp tell_owner(inst, message, _r) do
    Logger.info("[disk] #{inst.name}: no owner or token for the #{message} message")
    :settled
  end

  @doc false
  # The raise is twice the limit the bot should have, never the host's figure,
  # which may be 0 (`disk_mb` must be positive). With the limit off there is
  # nothing to raise.
  def operator_alert(inst, r) do
    advice =
      case DiskLimit.limit(inst) do
        {mb, _files} ->
          "Поднять лимит: sudo ops/druzhok set #{inst.name} disk_mb=#{mb * 2}"

        :off ->
          "Лимит в настройках выключен (bot_disk_mb=off): sudo ops/druzhok disk-apply снимет его на диске."
      end

    "Диск бота #{inst.name} заполнен: #{DiskLimit.size(r.used_kb)} из #{DiskLimit.size(r.limit_kb)}, " <>
      "#{DiskLimit.count(r.files)} из #{DiskLimit.count(r.file_limit)} файлов. " <> advice
  end

  @doc """
  Sends `text` to the operator through the superbot. `:ok` or `:error`; a
  missing setting is an error in the log.
  """
  def tell_operator(text) do
    token = Settings.get("manager_bot_token")
    chat = Settings.operator_telegram_id()

    if is_binary(token) and chat not in [nil, ""] do
      case API.send_message(token, chat, text) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("[disk] operator alert not sent (#{short(reason)}): #{text}")
          :error
      end
    else
      Logger.error(
        "[disk] no manager_bot_token or operator_telegram_id to alert the operator: #{text}"
      )

      :error
    end
  end

  # At most once an hour per kind, in the log and to the operator.
  defp report(state, kind, now, text) do
    case state.reported[kind] do
      %DateTime{} = last ->
        if DateTime.diff(now, last) >= @report_every_s,
          do: do_report(state, kind, now, text),
          else: state

      _ ->
        do_report(state, kind, now, text)
    end
  end

  defp do_report(state, kind, now, text) do
    Logger.error("[disk] #{text}")
    tell_operator(text)
    %{state | reported: Map.put(state.reported, kind, now)}
  end

  defp put_quota(value) do
    if Settings.get("disk_quota") != value, do: Settings.set("disk_quota", value)
  end

  defp set(id, fields), do: Repo.update_all(from(i in Instance, where: i.id == ^id), set: fields)

  defp short(reason) when is_binary(reason), do: String.slice(reason, 0, 160)
  defp short(%{"description" => d}), do: d
  defp short(reason), do: inspect(reason) |> String.slice(0, 160)
end
