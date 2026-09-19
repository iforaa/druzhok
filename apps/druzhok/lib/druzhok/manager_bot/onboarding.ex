defmodule Druzhok.ManagerBot.Onboarding do
  @moduledoc """
  Pure-function state machine for the manager bot's onboarding flow.

  Steps: :idle → :name → :language → :confirm → :done
  Each step returns {:ok, session, reply} or {:retry, session, reply}.
  Reply types: {:text, text}, {:keyboard, text, rows}, {:edit, text, rows},
               {:confirm, session}, {:edit_confirm, session}
  """

  def new_session do
    %{
      step: :idle,
      name: nil,
      language: nil,
      username: nil,
      # The code the person came in with, until ruoc has redeemed it.
      invite: nil,
      message_id: nil,
      started_at: System.system_time(:second)
    }
  end

  # --- Main menu ---

  @create "🤖 Создать бота"
  @my_bots "📋 Мои боты"
  @my_bot "🤖 Мой бот"
  @pictures "🎨 Картинки"
  @invite "🎁 Пригласить"
  @delete "🗑 Удалить"

  @doc "Every label the reply keyboard can carry; none of them is ever a bot name or a code."
  def menu_texts, do: [@create, @my_bots, @my_bot, @pictures, @invite, @delete]

  @doc """
  The reply keyboard for a person with `bot_count` bots. One bot is the rule;
  the create button exists only until it is used, and a person with several
  (only possible from before the rule) keeps the old list.
  """
  def main_menu_keyboard(bot_count \\ 0) do
    rows =
      case bot_count do
        0 -> [[%{text: @create}]]
        1 -> [[%{text: @my_bot}, %{text: @pictures}], [%{text: @invite}, %{text: @delete}]]
        _ -> [[%{text: @my_bots}]]
      end

    %{keyboard: rows, resize_keyboard: true, one_time_keyboard: false}
  end

  def welcome_message do
    "Привет! Я помогу создать персонального AI-бота."
  end

  # --- Step handlers ---

  # Main menu buttons (text from reply keyboard)
  def handle_input(%{step: step} = session, %{text: @create})
      when step in [:idle, :done] do
    {session, text} = begin_create(session, session.invite)
    {:ok, session, {:text, text}}
  end

  def handle_input(_session, %{text: @my_bots}) do
    {:ok, new_session(), {:my_bots}}
  end

  # Invite step: the person has no admission; whatever they type is a code
  # for ManagerBot to check with ruoc. Menu buttons keep working.
  def handle_input(%{step: :invite} = session, %{text: text}) do
    code = String.trim(text || "")

    cond do
      code in menu_texts() -> handle_input(new_session(), %{text: code})
      code == "" -> {:retry, session, {:text, invite_prompt()}}
      true -> {:ok, session, {:check_invite, code}}
    end
  end

  def handle_input(%{step: :invite} = session, _input), do: {:retry, session, {:text, invite_prompt()}}

  # Name step
  def handle_input(%{step: :name} = session, %{text: text}) do
    name = String.trim(text || "")
    cond do
      name == "" ->
        {:retry, session, {:text, "Имя не может быть пустым. Как назовём бота?"}}
      name in menu_texts() ->
        # Re-dispatch menu buttons during name entry from a fresh session;
        # re-dispatching with step :name would loop forever.
        handle_input(new_session(), %{text: name})
      true ->
        username = generate_bot_username(name)
        # Every transition restamps the clock, so the TTL measures idleness and
        # not the whole flow: naming a bot in Telegram takes minutes.
        session = %{session | step: :language, name: name, username: username, started_at: System.system_time(:second)}
        {:ok, session, {:keyboard, "Язык:", language_buttons()}}
    end
  end

  # Language step
  def handle_input(%{step: :language} = session, %{callback_data: "lang:" <> lang})
      when lang in ["ru", "en"] do
    session = %{session | step: :confirm, language: lang, started_at: System.system_time(:second)}
    {:ok, session, {:edit_confirm, session}}
  end

  def handle_input(%{step: :language} = session, _input) do
    {:retry, session, {:edit, "Язык:", language_buttons()}}
  end

  # Confirm step
  def handle_input(%{step: :confirm} = session, _input) do
    {:retry, session, {:edit_confirm, session}}
  end

  # Done / idle
  def handle_input(%{step: :done}, _input) do
    {:ok, new_session(), {:text, "Бот уже создан! Используй меню внизу."}}
  end

  def handle_input(session, _input) do
    {:retry, session, {:text, "Используй кнопки меню внизу."}}
  end

  @doc "Put the session at the invite step; ManagerBot sends the prompt."
  def ask_invite(session), do: {%{session | step: :invite, started_at: System.system_time(:second)}, invite_prompt()}

  def invite_prompt, do: "Создание по приглашению. Введи код или открой ссылку от друга."

  @doc """
  Park the session while ruoc is asked about `code`. Nothing the person sends
  counts until the answer lands, which is what keeps one user from spending
  the poll loop on a round trip per message.
  """
  def begin_check(session, code), do: %{session | step: :checking, invite: code, started_at: System.system_time(:second)}

  def invite_status_message(:spent), do: "Этот код уже использован."
  def invite_status_message(:expired), do: "Срок этого кода истёк."
  def invite_status_message(:invalid), do: "Код не найден. Проверь ссылку или попроси новый."
  def invite_status_message(_), do: "Не получилось проверить код, попробуй позже."

  @doc "Start naming the bot, carrying the (checked) code to provisioning."
  def begin_create(session, invite \\ nil) do
    {%{session | step: :name, invite: invite, started_at: System.system_time(:second)}, "Как назовём бота?"}
  end

  def create_race_message, do: "Код успели использовать. Попроси новый и создай бота заново."
  def after_create_message, do: "Управление ботом — в меню внизу."
  def after_delete_message, do: "Можно создать нового бота."

  # --- Message builders ---

  def confirm_message(session, manager_username) do
    username = session.username || generate_bot_username(session.name)
    encoded_name = URI.encode(session.name)
    link = "https://t.me/newbot/#{manager_username}/#{username}?name=#{encoded_name}"

    lang_label = if session.language == "ru", do: "Русский", else: "English"

    text = "📋 *#{session.name}*\nЯзык: #{lang_label}\n\nНажми кнопку чтобы создать:"
    keyboard = [[%{text: "🤖 Создать «#{session.name}»", url: link}]]

    {text, keyboard, link}
  end

  @provision_steps [
    "Выращиваю нейроны",
    "Загружаю сознание",
    "Прикручиваю инструменты",
    "Прививаю чувство юмора",
    "Объясняю, кто тут главный",
    "Наливаю кофе",
    "Учу здороваться"
  ]

  @doc "The checklist a creator watches while their bot is provisioned, in order."
  def provision_steps, do: @provision_steps

  @doc """
  Progress message with the first `step` items ticked and the next one
  pending. Past the last step it keeps showing the last one, so a slow
  provision never claims to be done early.
  """
  def progress_message(bot_username, step) do
    step = min(step, length(@provision_steps) - 1)
    {done, [current | _]} = Enum.split(@provision_steps, step)
    lines = Enum.map(done, &"✅ #{&1}") ++ ["⏳ #{current}…"]
    "🥚 Создаю @#{bot_username}\n\n" <> Enum.join(lines, "\n")
  end

  def completion_message(bot_username) do
    "✅ Бот @#{bot_username} создан и запущен!\n→ Написать боту: https://t.me/#{bot_username}"
  end

  def limit_message, do: "У тебя уже есть бот. Удали его, чтобы создать нового."

  @doc "The one-bot card: the bot line and a button into its chat."
  def my_bot_message(bot) do
    {bot_line(bot), [[%{text: "💬 Написать", url: "https://t.me/#{bot_handle(bot)}"}]]}
  end

  @doc """
  What «🎁 Пригласить» sends, in order: an intro, one message per available
  code with its deep link and a share button, then one message listing the
  redeemed codes. `codes` is `Druzhok.Ruoc.referrals/1`'s list.
  """
  def referrals_messages(codes, manager_username) do
    available = Enum.filter(codes, &(&1.status == "available" and is_binary(&1.code)))
    redeemed = Enum.filter(codes, &(&1.status == "redeemed"))

    shares =
      Enum.map(available, fn c ->
        link = "https://t.me/#{manager_username}?start=ref_#{c.code}"

        caption =
          if c.you_rub != "0.00",
            do: "Создай своего AI-бота по моей ссылке — мне за это начислят #{c.you_rub} ₽",
            else: "Создай своего AI-бота по моей ссылке"

        share = "https://t.me/share/url?url=#{URI.encode_www_form(link)}&text=#{URI.encode_www_form(caption)}"
        {link, [[%{text: "Поделиться", url: share}]]}
      end)

    intro = if shares == [], do: [], else: [{"Пригласи друга — по этой ссылке он сможет создать своего бота:", []}]

    used =
      case redeemed do
        [] ->
          []

        list ->
          line =
            Enum.map_join(list, "\n", &String.trim("Использован " <> if(&1.redeemed_at, do: short_date(&1.redeemed_at), else: "")))

          [{line, []}]
      end

    case intro ++ shares ++ used do
      [] -> [{"У тебя пока нет приглашений.", []}]
      messages -> messages
    end
  end

  def my_bots_message(bots) do
    if bots == [] do
      {"У тебя пока нет ботов. Нажми «🤖 Создать бота» чтобы начать!", []}
    else
      lines = Enum.map(bots, &bot_line/1)
      text = "Твои боты:\n\n" <> Enum.join(lines, "\n")

      buttons = Enum.map(bots, fn bot ->
        handle = bot_handle(bot)
        [
          %{text: "💬 @#{handle}", url: "https://t.me/#{handle}"},
          %{text: "🎨", callback_data: "img:#{bot[:id]}"},
          %{text: "🗑", callback_data: "del:#{bot[:id]}"}
        ]
      end)

      {text, buttons}
    end
  end

  # --- Image generation menu ---

  @doc """
  The picture menu for one bot: what is on now, then «Выкл» and one button
  per ruoc image model with its price, ✅ on the current choice. `models` is
  `Druzhok.Ruoc.image_models/0`'s result; a failed list leaves only «Назад».
  """
  def image_menu(bot, {:error, _}) do
    text = "🎨 Картинки для @#{bot_handle(bot)}\n\nСписок моделей сейчас недоступен, попробуй позже"
    {text, [back_row()]}
  end

  def image_menu(bot, {:ok, models}) do
    enabled? = bot[:image_gen_enabled] == true
    current = current_image_model(bot, models)

    status =
      cond do
        not enabled? -> "выключено"
        is_map(current) -> "#{model_label(current)} за картинку"
        true -> bot[:image_gen_model]
      end

    text = "🎨 Картинки для @#{bot_handle(bot)}\n\nСейчас: #{status}"

    off = [%{text: tick(not enabled?) <> "🚫 Выкл", callback_data: "imgoff:#{bot[:id]}"}]

    choices =
      Enum.map(models, fn m ->
        chosen? = enabled? and is_map(current) and current.id == m.id
        [%{text: tick(chosen?) <> model_label(m), callback_data: "imgset:#{bot[:id]}:#{m.id}"}]
      end)

    {text, [off | choices] ++ [back_row()]}
  end

  @doc "The model a bot with pictures on is using: its own, or ruoc's default when it names none."
  def current_image_model(bot, models) do
    case bot[:image_gen_model] do
      nil -> Enum.find(models, & &1.default) || List.first(models)
      id -> Enum.find(models, &(&1.id == id))
    end
  end

  def image_restarting(:enabled, handle), do: "⏳ Включаю картинки для @#{handle}…"
  def image_restarting(:disabled, handle), do: "⏳ Выключаю картинки для @#{handle}…"

  def image_result(:enabled, _handle, model), do: "✅ Картинки включены: #{model_label(model)} за картинку"
  def image_result(:disabled, handle, _model), do: "✅ Картинки выключены для @#{handle}"
  def image_failed(handle), do: "Не получилось перезапустить @#{handle}, попробуй ещё раз."

  defp model_label(%{name: name, rub_per_image: rub}), do: "#{name} · #{rub} ₽"
  defp tick(true), do: "✅ "
  defp tick(false), do: ""
  defp back_row, do: [%{text: "« Назад", callback_data: "imgback"}]

  @doc "Confirm prompt + Yes/No keyboard for deleting a bot."
  def delete_confirm(id, handle) do
    text = "⚠️ Точно удалить @#{handle}? Это навсегда — память и история пропадут."
    rows = [[
      %{text: "✅ Да, удалить", callback_data: "delyes:#{id}"},
      %{text: "❌ Отмена", callback_data: "delno"}
    ]]
    {text, rows}
  end

  def delete_done(handle), do: "✅ Бот @#{handle} удалён."
  def delete_cancelled, do: "Отменено."

  defp bot_line(bot) do
    status = if bot[:active], do: "🟢", else: "🔴"

    "#{status} *#{bot.name}* — #{format_balance(bot[:ruoc_balance_rub])}#{format_plan(bot[:ruoc_subscription])}"
  end

  defp format_balance(nil), do: "баланс —"
  defp format_balance(rub), do: "баланс #{rub} ₽"

  defp format_plan(%{plan_name: name, status: "active", period_end: %DateTime{} = at}),
    do: " · план «#{name}», продление #{short_date(at)}"

  defp format_plan(%{plan_name: name, status: "cancelled", period_end: %DateTime{} = at}),
    do: " · план «#{name}» отменён, до #{short_date(at)}"

  defp format_plan(%{plan_name: name}), do: " · план «#{name}»"
  defp format_plan(_), do: ""

  @months ~w(янв фев мар апр мая июн июл авг сен окт ноя дек)

  @doc "Day and short month in Moscow time: `5 окт`."
  def short_date(%DateTime{} = at) do
    local = DateTime.shift_zone!(at, "Europe/Moscow")
    "#{local.day} #{Enum.at(@months, local.month - 1)}"
  end

  defp bot_handle(bot) do
    case bot[:trigger_name] do
      handle when is_binary(handle) and handle != "" -> handle
      _ ->
        name = bot.name
        if String.ends_with?(name, "_bot"), do: name, else: name <> "_bot"
    end
  end

  # --- Username generation ---

  def generate_bot_username(display_name) do
    slug =
      display_name
      |> transliterate()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")
      |> String.slice(0, 20)

    slug = if slug == "", do: "bot", else: slug
    # Telegram usernames must start with a letter — prefix if the slug
    # begins with a digit (e.g. a name like "3000" → "b3000_…_bot").
    slug = if String.match?(slug, ~r/^[a-z]/), do: slug, else: "b#{slug}"
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{slug}_#{suffix}_bot"
  end

  # --- Private ---

  defp language_buttons do
    [[%{text: "🇷🇺 Русский", callback_data: "lang:ru"}, %{text: "🇬🇧 English", callback_data: "lang:en"}]]
  end

  @transliteration %{
    "а" => "a", "б" => "b", "в" => "v", "г" => "g", "д" => "d",
    "е" => "e", "ё" => "yo", "ж" => "zh", "з" => "z", "и" => "i",
    "й" => "y", "к" => "k", "л" => "l", "м" => "m", "н" => "n",
    "о" => "o", "п" => "p", "р" => "r", "с" => "s", "т" => "t",
    "у" => "u", "ф" => "f", "х" => "kh", "ц" => "ts", "ч" => "ch",
    "ш" => "sh", "щ" => "shch", "ъ" => "", "ы" => "y", "ь" => "",
    "э" => "e", "ю" => "yu", "я" => "ya",
  }

  defp transliterate(text) do
    text
    |> String.graphemes()
    |> Enum.map(fn char ->
      lower = String.downcase(char)
      Map.get(@transliteration, lower, char)
    end)
    |> Enum.join()
  end
end
