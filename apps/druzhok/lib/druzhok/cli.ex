defmodule Druzhok.CLI do
  @moduledoc """
  The operator's command line, replacing the dashboard (dashboard removal
  spec, step 2). On the server: `sudo ops/druzhok <command> [args]`; in dev:
  `mix druzhok <command> [args]`. `main/1` prints and returns the exit status.
  """

  import Ecto.Query, only: [from: 2]
  alias Druzhok.{BotManager, BotSettings, Instance, Repo, Ruoc, Settings}

  @help """
  usage: druzhok <command> [args]

    list                          bots with status
    show <bot>                    settings and state (secrets masked)
    set <bot> key=value...        change settings; a running bot restarts when a
                                  field needs it. value "-" reads it from stdin
    start|stop|restart <bot>      waits for the lifecycle controller's outcome
    users <bot>                   allowed Telegram ids
    allow <bot> <telegram id>     allow a user (restarts the bot)
    disallow <bot> <telegram id>  remove a user (restarts the bot)
    approve <bot> <user id|CODE>  allow a Telegram id and send the welcome,
                                  or approve a hermes pairing code
    clear-history <bot>           drop chat sessions (memory stays), restart
    ruoc-check [--suspend-orphans]
                                  compare ruoc's partner accounts with the bots;
                                  exits 1 when anything is off. --suspend-orphans
                                  suspends orphans created over an hour ago
    bind-cabinet [<bot>]          bind each bot (or one) to ruoc's bot cabinet now and
                                  set its owner's «Кабинет» menu button; prints each
    bind-cabinet --off [<bot>]    put the owners' menu buttons back to the default
    settings                      global settings (secrets masked)
    settings set key=value...     change global settings; value "-" reads stdin

  bot fields: #{Enum.join(BotSettings.fields(), " ")}
  """

  def main(args) do
    case run(args) do
      :ok ->
        0

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        1
    end
  end

  defp run([]), do: run(["help"])
  defp run([h]) when h in ["help", "-h", "--help"], do: IO.write(@help)

  defp run(["list"]) do
    for inst <- BotManager.list() do
      status = Druzhok.Lifecycle.shown_status(inst, BotManager.status(inst.name))
      sleep = if inst.sleep_enabled, do: " sleep-on", else: ""
      IO.puts("#{pad(inst.name, 28)} #{pad(status, 10)} #{inst.model}#{sleep}")
    end

    :ok
  end

  defp run(["show", bot]) do
    with {:ok, rows} <- BotSettings.show(bot) |> explain() do
      for {k, v} <- rows, do: IO.puts("#{pad(to_string(k), 26)} #{format(v)}")
      IO.puts("#{pad("cabinet", 26)} #{cabinet_state(Repo.get_by(Instance, name: bot))}")
      :ok
    end
  end

  # One-off BEAM: Druzhok.Cabinet does not run here, so this calls its work
  # directly and waits for each answer rather than casting.
  defp run(["bind-cabinet" | args]) when length(args) <= 2 do
    {off?, names} = Enum.split_with(args, &(&1 == "--off"))
    off? = off? != []

    bots =
      case names do
        [] -> Repo.all(from(i in Instance, where: i.delete_requested == false, order_by: i.name))
        [name] -> List.wrap(Repo.get_by(Instance, name: name))
        _ -> :usage
      end

    case bots do
      :usage ->
        {:error, "usage: bind-cabinet [--off] [<bot>]"}

      [] ->
        {:error, "no such bot"}

      bots ->
        results =
          for inst <- bots do
            result =
              if off?, do: Druzhok.Cabinet.unset_now(inst), else: Druzhok.Cabinet.bind_now(inst)

            IO.puts("#{pad(inst.name, 28)} #{describe_cabinet(result)}")
            result
          end

        if Enum.any?(results, &match?({:error, r} when r != :not_eligible, &1)),
          do: {:error, "some bots were not done; see above"},
          else: :ok
    end
  end

  defp run(["set", bot | pairs]) when pairs != [] do
    with {:ok, attrs} <- pairs(pairs),
         {:ok, _inst, restarted?} <- BotSettings.update(bot, attrs) |> explain() do
      IO.puts(if restarted?, do: "saved; restart requested", else: "saved")
    end
  end

  defp run([op, bot]) when op in ["start", "restart"] do
    result = apply(BotManager, String.to_existing_atom(op), [bot, [wait: true]])

    case result do
      {:ok, _} -> IO.puts("#{bot}: started")
      {:error, reason} -> {:error, "#{bot}: #{inspect(reason)}"}
    end
  end

  defp run(["stop", bot]) do
    case BotManager.stop(bot, wait: true) do
      :ok -> IO.puts("#{bot}: stopped")
      {:error, reason} -> {:error, "#{bot}: #{inspect(reason)}"}
    end
  end

  defp run(["users", bot]) do
    with {:ok, ids} <- BotSettings.allowed_users(bot) |> explain() do
      Enum.each(ids, &IO.puts/1)
    end
  end

  defp run(["allow", bot, id]),
    do: BotSettings.allow_user(bot, id) |> explain() |> done("allowed")

  defp run(["disallow", bot, id]),
    do: BotSettings.remove_user(bot, id) |> explain() |> done("removed")

  defp run(["approve", bot, who]) do
    case Integer.parse(who) do
      {user_id, ""} ->
        BotSettings.allow_and_welcome(bot, user_id) |> explain() |> done("approved")

      _ ->
        case BotSettings.approve_code(bot, String.upcase(who)) do
          {:ok, out} -> IO.puts(out)
          {:error, out} -> {:error, out}
        end
    end
  end

  defp run(["clear-history", bot]),
    do: BotSettings.clear_history(bot) |> explain() |> done("cleared")

  defp run(["ruoc-check" | flags]) when flags in [[], ["--suspend-orphans"]] do
    with {:ok, accounts} <- Ruoc.list_accounts() |> explain() do
      findings = ruoc_findings(accounts, Repo.all(Instance))
      Enum.each(findings, &IO.puts(describe_finding(&1)))

      if flags == ["--suspend-orphans"], do: suspend_orphans(findings)

      case findings do
        [] -> IO.puts("ok: #{length(accounts)} accounts, all matched")
        list -> {:error, "#{length(list)} problem(s)"}
      end
    end
  end

  defp run(["settings"]) do
    for key <- Settings.keys() do
      v = Settings.get(key)
      v = if key in Settings.secret_keys(), do: BotSettings.mask(v), else: v
      IO.puts("#{pad(key, 22)} #{format(v)}")
    end

    :ok
  end

  defp run(["settings", "set" | pairs]) when pairs != [] do
    with {:ok, attrs} <- pairs(pairs) do
      case Enum.reject(Map.keys(attrs), &(&1 in Settings.keys())) do
        [] ->
          Enum.each(attrs, fn {k, v} -> {:ok, _} = Settings.set(k, v) end)
          IO.puts("saved")

        unknown ->
          {:error,
           "unknown setting #{Enum.join(unknown, ", ")}; known: #{Enum.join(Settings.keys(), " ")}"}
      end
    end
  end

  defp run(args), do: {:error, "unknown command: #{Enum.join(args, " ")} (try: druzhok help)"}

  defp cabinet_state(nil), do: "-"
  defp cabinet_state(%Instance{cabinet_binding: nil}), do: "не привязан"

  defp cabinet_state(%Instance{} = inst),
    do:
      "bot:owner #{inst.cabinet_binding}, button #{if inst.cabinet_menu_set, do: "set", else: "not set yet"}"

  defp describe_cabinet({:ok, :unchanged}), do: "без изменений"
  defp describe_cabinet({:ok, :bound}), do: "привязан, кнопка поставлена"
  defp describe_cabinet({:ok, :button}), do: "кнопка поставлена"
  defp describe_cabinet({:ok, :unset}), do: "кнопка снята"

  defp describe_cabinet({:error, :not_eligible}),
    do: "пропущен: нет ruoc-аккаунта, владельца или токена"

  defp describe_cabinet({:error, :menu_button}),
    do: "привязан, кнопка не поставлена (владелец ещё не открывал бота)"

  defp describe_cabinet({:error, reason}), do: "ошибка: #{reason}"

  # The reconcile report (partner access spec, `ruoc-check`). It reads both
  # sides and changes nothing unless asked to suspend orphans.
  @orphan_min_age_s 3600

  @doc false
  def ruoc_findings(accounts, instances) do
    by_id = Map.new(accounts, &{&1.account_id, &1})
    owned = MapSet.new(instances, & &1.ruoc_account_id)

    orphans =
      for a <- accounts,
          a.status == "active",
          not MapSet.member?(owned, a.account_id),
          do: {:orphan, a}

    per_bot =
      Enum.flat_map(instances, fn inst ->
        account = by_id[inst.ruoc_account_id]
        ref = BotManager.external_ref(inst.name, inst.owner_telegram_id)

        account_finding =
          cond do
            is_nil(account) -> [{:missing, inst}]
            account.status != "active" -> [{:suspended, inst, account}]
            account.external_ref != ref -> [{:ref_mismatch, inst, account, ref}]
            true -> []
          end

        stuck =
          if inst.delete_requested and is_binary(inst.delete_error),
            do: [{:stuck_delete, inst}],
            else: []

        account_finding ++ stuck
      end)

    orphans ++ per_bot
  end

  defp describe_finding({:orphan, a}),
    do:
      "orphan: account #{a.account_id} (#{a.label}, ref #{a.external_ref}, created #{format(a.created_at)}) has no bot"

  defp describe_finding({:missing, inst}),
    do:
      "missing: bot #{inst.name} has account #{format(inst.ruoc_account_id)}, not among the partner's accounts"

  defp describe_finding({:suspended, inst, a}),
    do: "suspended: bot #{inst.name} has account #{a.account_id}, which is #{a.status}"

  defp describe_finding({:ref_mismatch, inst, a, ref}),
    do:
      "ref mismatch: bot #{inst.name} account #{a.account_id} has ref #{format(a.external_ref)}, expected #{ref}"

  defp describe_finding({:stuck_delete, inst}),
    do: "stuck delete: bot #{inst.name} (#{inst.delete_failures} attempts): #{inst.delete_error}"

  defp suspend_orphans(findings) do
    cutoff = DateTime.add(DateTime.utc_now(), -@orphan_min_age_s)

    for {:orphan, a} <- findings do
      cond do
        not (a.created_at && DateTime.compare(a.created_at, cutoff) == :lt) ->
          IO.puts("left orphan #{a.account_id}: created under an hour ago")

        # A create retried since the snapshot may have claimed it (409, then
        # a reissued key): look again right before acting.
        Repo.exists?(from(i in Instance, where: i.ruoc_account_id == ^a.account_id)) ->
          IO.puts("left orphan #{a.account_id}: a bot holds it now")

        true ->
          case Ruoc.suspend(a.account_id) do
            :ok -> IO.puts("suspended orphan #{a.account_id}")
            {:error, reason} -> IO.puts("could not suspend orphan #{a.account_id}: #{reason}")
          end
      end
    end
  end

  # key=value pairs; "-" reads the value from stdin, so a secret stays out of
  # the shell history and the process list.
  defp pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn pair, {:ok, acc} ->
      case String.split(pair, "=", parts: 2) do
        [k, "-"] -> {:cont, {:ok, Map.put(acc, k, read_stdin())}}
        [k, v] when k != "" -> {:cont, {:ok, Map.put(acc, k, v)}}
        _ -> {:halt, {:error, "expected key=value, got #{inspect(pair)}"}}
      end
    end)
  end

  defp read_stdin do
    case IO.read(:stdio, :line) do
      line when is_binary(line) -> String.trim(line)
      _ -> ""
    end
  end

  defp done(:ok, message), do: IO.puts(message)
  defp done(error, _message), do: error

  defp explain({:error, :not_found}), do: {:error, "no such bot"}

  defp explain({:error, {:unknown_field, f}}),
    do: {:error, "unknown field #{f}; fields: #{Enum.join(BotSettings.fields(), " ")}"}

  defp explain({:error, %Ecto.Changeset{} = cs}), do: {:error, inspect(cs.errors)}
  defp explain({:error, reason}) when not is_binary(reason), do: {:error, inspect(reason)}
  defp explain(other), do: other

  defp format(nil), do: "-"
  defp format(v) when is_binary(v), do: v
  defp format(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp format(v), do: inspect(v)

  defp pad(s, n), do: String.pad_trailing(s, n)
end
