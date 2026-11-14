defmodule Druzhok.Cleohub do
  @moduledoc """
  CleoHub's own tools for a tenant bot, served to hermes as the MCP server
  `cleohub` (`DruzhokWebWeb.CleohubMcpController`, spec «CleoHub skill — phase 1»).
  The bot asks about its plan, the plans on offer, what it can do, operator
  notices, an invite link, and redraws its avatar. Every tool takes the bot's
  row and the call's arguments and returns `{:ok, text, structured}` or
  `{:error, text}`; texts are short and Russian, for the model to retell.

  Never a balance or a credit figure: the plan, its windows and the prices on
  offer only. Payment and plan changes stay in «Кабинет».
  """

  require Logger

  alias Druzhok.{Avatar, Instance, Panel, Ruoc, Settings}
  alias Druzhok.Cleohub.AvatarLimit
  alias Druzhok.Telegram.API

  @ruoc_timeout_ms 10_000
  @max_description 300

  @tools [
    %{
      name: "cleohub_account",
      description:
        "Тариф этого бота в CleoHub: название, статус, до какого числа оплачен, сколько израсходовано " <>
          "лимита на 5 часов и на неделю и когда они обновятся. Вызывай, когда спрашивают про тариф, " <>
          "лимиты или «сколько осталось».",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "cleohub_plans",
      description:
        "Тарифы CleoHub, которые сейчас можно купить: название, описание, цена за период; отмечен " <>
          "текущий тариф бота. Вызывай, когда спрашивают о других тарифах или ценах.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "cleohub_help",
      description:
        "Что умеет бот CleoHub и чего не умеет, плюс ответы на частые вопросы владельца. Вызывай, " <>
          "когда спрашивают «что ты умеешь», «как это работает» или о сервисе Cleo.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "cleohub_notices",
      description:
        "Текущие уведомления CleoHub: сбои, работы, новости. Вызывай, когда спрашивают, не сломалось ли " <>
          "что-то, или что нового.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "cleohub_invite",
      description:
        "Ссылка-приглашение для друга, чтобы он создал своего бота, и что за неё начислят. Вызывай, " <>
          "когда просят ссылку для друга или спрашивают о приглашениях.",
      inputSchema: %{type: "object", properties: %{}, required: []}
    },
    %{
      name: "cleohub_set_avatar",
      description:
        "Нарисовать боту новую аватарку по описанию и поставить её. Работает в фоне: результат придёт " <>
          "владельцу отдельным сообщением примерно через минуту. Не больше 3 раз в день.",
      inputSchema: %{
        type: "object",
        properties: %{
          description: %{
            type: "string",
            description: "Как должна выглядеть аватарка, своими словами, до 300 символов.",
            maxLength: @max_description
          }
        },
        required: ["description"]
      }
    }
  ]

  @doc "The tools, as MCP's `tools/list` gives them."
  def tools, do: @tools

  @doc "Whether `name` is one of the tools."
  def tool?(name), do: Enum.any?(@tools, &(&1.name == name))

  @doc "Run tool `name` for bot `inst`: `{:ok, text, structured}` or `{:error, text}`."
  def call(%Instance{} = inst, name, args) when is_map(args) do
    case name do
      "cleohub_account" -> account(inst)
      "cleohub_plans" -> plans(inst)
      "cleohub_help" -> help(inst)
      "cleohub_notices" -> notices()
      "cleohub_invite" -> invite(inst)
      "cleohub_set_avatar" -> set_avatar(inst, args["description"])
    end
  rescue
    e ->
      Logger.error("[cleohub] #{inst.name} #{name} crashed: #{Exception.message(e)}")
      {:error, "Не получилось, попробуйте позже."}
  end

  # --- cleohub_account -------------------------------------------------------

  defp account(inst) do
    case Ruoc.balance(inst.ruoc_api_key, receive_timeout: @ruoc_timeout_ms) do
      {:ok, bal} ->
        sub = bal.subscription
        limits = bal.limits
        trial = bal.trial
        tz = inst.timezone

        lines =
          [
            plan_line(sub, limits, tz),
            limits && window_line("Лимит на 5 часов", limits.session, tz),
            limits && window_line("Лимит на неделю", limits.weekly, tz),
            limits && limits.pool && window_line("Общий бесплатный лимит на сегодня", limits.pool, tz),
            limits && spent_line(limits.spent),
            trial && trial_line(trial, tz),
            "Оплатить или сменить тариф — в «Кабинете» (кнопка меню бота)."
          ]
          |> Enum.reject(&(&1 in [nil, false]))

        structured = %{
          plan: plan_name(sub, limits),
          status: sub && sub.status,
          period_end: sub && iso(sub.period_end),
          session: limits && window_map(limits.session),
          weekly: limits && window_map(limits.weekly),
          pool: limits && limits.pool && window_map(limits.pool),
          spent: limits && limits.spent,
          trial: trial && %{state: trial.state, ends_at: iso(trial.ends_at)}
        }

        {:ok, Enum.join(lines, "\n"), structured}

      {:error, reason} ->
        Logger.warning("[cleohub] #{inst.name} account: #{reason}")
        {:error, "Не удалось узнать тариф: сервис не ответил. Попробуйте чуть позже."}
    end
  end

  defp plan_name(sub, limits), do: (sub && sub.plan_name) || (limits && limits.plan_name)

  defp plan_line(nil, nil, _tz), do: "Тарифа сейчас нет."

  defp plan_line(sub, limits, tz) do
    name = plan_name(sub, limits)

    case sub do
      %{status: status, period_end: period_end} ->
        until = if period_end, do: ", оплачен до #{local(period_end, tz)}", else: ""
        "Тариф: «#{name}» (#{status_word(status)})#{until}."

      nil ->
        "Тариф: «#{name}»."
    end
  end

  defp status_word("active"), do: "действует"
  defp status_word("past_due"), do: "ждёт оплаты"
  defp status_word("canceled"), do: "отменён"
  defp status_word("cancelled"), do: "отменён"
  defp status_word("expired"), do: "закончился"
  defp status_word(other), do: to_string(other)

  defp window_line(label, %{used_percent: pct, resets_at: at}, tz) do
    reset = if at, do: ", обновится #{local(at, tz)}", else: ""
    "#{label}: израсходовано #{pct} %#{reset}."
  end

  defp spent_line("session"), do: "Сейчас лимит на 5 часов исчерпан."
  defp spent_line("weekly"), do: "Сейчас лимит на неделю исчерпан."
  defp spent_line("pool"), do: "Сейчас общий бесплатный лимит на сегодня исчерпан."
  defp spent_line(_), do: nil

  defp trial_line(%{state: "open", ends_at: at}, tz),
    do: "Пробный период идёт" <> if(at, do: " до #{local(at, tz)}.", else: ".")

  defp trial_line(%{state: "ended"}, _tz), do: "Пробный период закончился."
  defp trial_line(%{state: "paused"}, _tz), do: "Пробный период приостановлен."
  defp trial_line(_, _tz), do: nil

  defp window_map(%{used_percent: pct, resets_at: at}), do: %{used_percent: pct, resets_at: iso(at)}

  # --- cleohub_plans ---------------------------------------------------------

  defp plans(inst) do
    current =
      case Ruoc.balance(inst.ruoc_api_key, receive_timeout: @ruoc_timeout_ms) do
        {:ok, bal} -> plan_name(bal.subscription, bal.limits)
        {:error, _} -> nil
      end

    case Ruoc.plans(Panel.billing_url()) do
      {:ok, list} ->
        marked = Enum.map(list, &Map.put(&1, :current, current != nil and &1.name == current))

        plan_lines =
          case marked do
            [] -> ["Сейчас тарифов для покупки нет."]
            _ -> ["Тарифы CleoHub:" | Enum.map(marked, &plan_entry/1)]
          end

        current_line =
          cond do
            current == nil -> nil
            Enum.any?(marked, & &1.current) -> nil
            true -> "Ваш тариф: «#{current}»."
          end

        text =
          (plan_lines ++ [current_line, "Сменить тариф — «Кабинет» → Тариф."])
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        structured = %{
          current: current,
          plans:
            Enum.map(marked, fn p ->
              %{
                name: p.name,
                description: p.description,
                price_rub: rub(p.price_nanorub),
                period_days: p.period_days,
                current: p.current
              }
            end)
        }

        {:ok, text, structured}

      {:error, reason} ->
        Logger.warning("[cleohub] #{inst.name} plans: #{reason}")
        {:error, "Не удалось получить список тарифов. Попробуйте чуть позже или загляните в «Кабинет»."}
    end
  end

  defp plan_entry(p) do
    period = if p.period_days, do: " / #{p.period_days} дн.", else: ""
    desc = if p.description != "", do: " — " <> p.description, else: ""
    mark = if p.current, do: " (ваш тариф)", else: ""
    "- «#{p.name}»: #{rub(p.price_nanorub)} ₽#{period}#{mark}#{desc}"
  end

  # Whole rubles as an integer, otherwise two decimals with a comma.
  defp rub(nano) do
    kopecks = div(nano + 5_000_000, 10_000_000)

    case rem(kopecks, 100) do
      0 -> Integer.to_string(div(kopecks, 100))
      k -> "#{div(kopecks, 100)},#{k |> Integer.to_string() |> String.pad_leading(2, "0")}"
    end
  end

  # --- cleohub_help ----------------------------------------------------------

  @doc """
  The help text for `inst`: `priv/cleohub/faq.<lang>.md` (Russian unless the bot
  speaks English), keeping the section between `<!-- pictures -->` markers when
  pictures are on and the one between `<!-- no-pictures -->` markers otherwise.
  """
  def help_text(inst) do
    lang = if inst.language == "en", do: "en", else: "ru"
    path = Path.join([:code.priv_dir(:druzhok), "cleohub", "faq.#{lang}.md"])
    {keep, drop} = if inst.image_gen_enabled == true, do: {"pictures", "no-pictures"}, else: {"no-pictures", "pictures"}

    path
    |> File.read!()
    |> String.replace(~r/<!-- #{drop} -->.*?<!-- \/#{drop} -->\n?/s, "")
    |> String.replace(~r/<!-- \/?#{keep} -->\n?/, "")
    |> String.trim()
  end

  defp help(inst), do: {:ok, help_text(inst), %{}}

  # --- cleohub_notices -------------------------------------------------------

  defp notices do
    case Settings.get("cleohub_notice") do
      nil -> {:ok, "Сейчас уведомлений нет: всё работает как обычно.", %{notice: nil}}
      notice -> {:ok, String.trim(notice), %{notice: String.trim(notice)}}
    end
  end

  # --- cleohub_invite --------------------------------------------------------

  defp invite(inst) do
    case Panel.invites(inst) do
      {:ok, %{links: [first | _]}} ->
        reward = reward_line(first)

        text =
          ["Ссылка для друга: #{first.link}", "Поделиться: #{first.share_url}", reward]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        {:ok, text, %{link: first.link, share_url: first.share_url}}

      {:ok, %{links: []}} ->
        {:ok, "Свободных приглашений сейчас нет.", %{link: nil}}

      _ ->
        {:error, "Не удалось получить приглашение. Попробуйте чуть позже или загляните в «Кабинет»."}
    end
  end

  # The cabinet's own wording (Пригласить), zero amounts left out.
  defp reward_line(%{friend_rub: friend, you_rub: you}) do
    parts =
      [
        friend != "0.00" && "другу — #{String.replace(friend, ".", ",")} ₽ на счёт",
        you != "0.00" && "вам — #{String.replace(you, ".", ",")} ₽"
      ]
      |> Enum.filter(& &1)

    case parts do
      [] -> nil
      _ -> parts |> Enum.join(", ") |> capitalize()
    end
  end

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest

  # --- cleohub_set_avatar ----------------------------------------------------

  defp set_avatar(inst, description) do
    with {:ok, description} <- description(description),
         :ok <- can_send?(inst),
         :ok <- AvatarLimit.take(inst.id) do
      Task.start(fn -> redraw_and_tell(inst, description) end)
      {:ok, "Рисую новую аватарку, пришлю владельцу через минуту.", %{started: true}}
    else
      {:error, text} -> {:error, text}
      :limit -> {:error, "Лимит: #{AvatarLimit.per_day()} смены аватарки в день. Попробуйте завтра."}
    end
  end

  defp description(d) when is_binary(d) do
    d = d |> String.replace(~r/\s+/u, " ") |> String.replace("\"", "'") |> String.trim()

    cond do
      d == "" -> {:error, "Опишите, как должна выглядеть аватарка."}
      String.length(d) > @max_description -> {:error, "Описание длиннее #{@max_description} символов, сократите."}
      true -> {:ok, d}
    end
  end

  defp description(_), do: {:error, "Опишите, как должна выглядеть аватарка."}

  defp can_send?(%Instance{telegram_token: t, ruoc_api_key: k, owner_telegram_id: o})
       when is_binary(t) and is_binary(k) and is_integer(o),
       do: :ok

  defp can_send?(_), do: {:error, "У этого бота нет владельца, аватарку сменить нельзя."}

  @doc false
  # The owner hears the outcome from druzhok, with the bot's token: they see every change.
  def redraw_and_tell(inst, description) do
    lang = inst.language

    result =
      case Avatar.redraw(inst, description) do
        {:ok, jpeg} ->
          API.send_photo(inst.telegram_token, inst.owner_telegram_id, {:upload, jpeg}, %{caption: done(lang)})

        {:error, reason} ->
          API.send_message(inst.telegram_token, inst.owner_telegram_id, failed(lang) <> Avatar.reason(reason, lang))
      end

    with {:error, why} <- result do
      Logger.warning("[cleohub] #{inst.name}: avatar outcome not delivered: #{inspect(why) |> String.slice(0, 200)}")
    end

    :ok
  end

  defp done("en"), do: "Done — a new avatar"
  defp done(_), do: "Готово — новая аватарка"

  defp failed("en"), do: "Could not change the avatar: "
  defp failed(_), do: "Не получилось сменить аватарку: "

  # --- shared ----------------------------------------------------------------

  defp local(%DateTime{} = at, tz) do
    shown =
      case DateTime.shift_zone(at, tz || "UTC") do
        {:ok, dt} -> dt
        _ -> at
      end

    Calendar.strftime(shown, "%d.%m.%Y %H:%M") <> " (#{shown.zone_abbr})"
  end

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
end
