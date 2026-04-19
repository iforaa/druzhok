defmodule Druzhok.ManagerBot.Onboarding do
  @moduledoc """
  Pure-function state machine for the manager bot's onboarding flow.

  Steps: :idle → :name → :personality → :language → :confirm → :done
  Each step returns {:ok, session, reply} or {:retry, session, reply}.
  Reply types: {:text, text}, {:keyboard, text, rows}, {:edit, text, rows},
               {:confirm, session}, {:edit_confirm, session}
  """

  @personalities [
    {"helpful", "Помощник"},
    {"kawaii", "Кавай"},
    {"pirate", "Пират"},
    {"noir", "Нуар"},
    {"philosopher", "Философ"},
    {"shakespeare", "Шекспир"},
    {"surfer", "Сёрфер"},
    {"hype", "Хайп"},
    {"concise", "Краткий"},
    {"technical", "Технарь"},
    {"creative", "Креативный"},
    {"teacher", "Учитель"},
    {"catgirl", "Кошкодевочка"},
    {"uwu", "UwU"},
  ]

  @personality_keys Enum.map(@personalities, fn {k, _} -> k end)

  def personalities, do: @personalities

  def new_session do
    %{
      step: :idle,
      name: nil,
      personality: nil,
      language: nil,
      username: nil,
      message_id: nil,
      started_at: System.system_time(:second)
    }
  end

  # --- Main menu ---

  def main_menu_keyboard do
    %{
      keyboard: [[%{text: "🤖 Создать бота"}, %{text: "📋 Мои боты"}]],
      resize_keyboard: true,
      one_time_keyboard: false
    }
  end

  def welcome_message do
    "Привет! Я помогу создать персонального AI-бота."
  end

  # --- Step handlers ---

  # Main menu buttons (text from reply keyboard)
  def handle_input(%{step: step} = session, %{text: "🤖 Создать бота"})
      when step in [:idle, :done] do
    session = %{session | step: :name, started_at: System.system_time(:second)}
    {:ok, session, {:text, "Как назовём бота?"}}
  end

  def handle_input(_session, %{text: "📋 Мои боты"}) do
    {:ok, new_session(), {:my_bots}}
  end

  # Name step
  def handle_input(%{step: :name} = session, %{text: text}) do
    name = String.trim(text || "")
    cond do
      name == "" ->
        {:retry, session, {:text, "Имя не может быть пустым. Как назовём бота?"}}
      name in ["🤖 Создать бота", "📋 Мои боты"] ->
        # Re-dispatch menu buttons during name entry
        handle_input(session, %{text: name})
      true ->
        username = generate_bot_username(name)
        session = %{session | step: :personality, name: name, username: username}
        {:ok, session, personality_reply()}
    end
  end

  # Personality step
  def handle_input(%{step: :personality} = session, %{callback_data: "personality:" <> key}) do
    if key in @personality_keys do
      session = %{session | step: :language, personality: key}
      {:ok, session, {:edit, "Язык:", language_buttons()}}
    else
      {:retry, session, {:edit, "Характер бота:", personality_buttons_page1()}}
    end
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "more_personalities"}) do
    {:ok, session, {:edit, "Характер бота:", personality_buttons_page2()}}
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "back_personalities"}) do
    {:ok, session, {:edit, "Характер бота:", personality_buttons_page1()}}
  end

  def handle_input(%{step: :personality} = session, _input) do
    {:retry, session, {:edit, "Выбери характер:", personality_buttons_page1()}}
  end

  # Language step
  def handle_input(%{step: :language} = session, %{callback_data: "lang:" <> lang})
      when lang in ["ru", "en"] do
    session = %{session | step: :confirm, language: lang}
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

  # --- Message builders ---

  def confirm_message(session, manager_username) do
    username = session.username || generate_bot_username(session.name)
    encoded_name = URI.encode(session.name)
    link = "https://t.me/newbot/#{manager_username}/#{username}?name=#{encoded_name}"

    personality_label = Enum.find_value(@personalities, session.personality, fn {k, l} ->
      if k == session.personality, do: l
    end)
    lang_label = if session.language == "ru", do: "Русский", else: "English"

    text = "📋 *#{session.name}*\nХарактер: #{personality_label}\nЯзык: #{lang_label}\n\nНажми кнопку чтобы создать:"
    keyboard = [[%{text: "🤖 Создать «#{session.name}»", url: link}]]

    {text, keyboard, link}
  end

  def completion_message(bot_username) do
    "✅ Бот @#{bot_username} создан и запущен!\n→ Написать боту: https://t.me/#{bot_username}"
  end

  def limit_message do
    "У тебя уже 2 бота — это максимум. Удали один из существующих чтобы создать новый."
  end

  def my_bots_message(bots) do
    if bots == [] do
      {"У тебя пока нет ботов. Нажми «🤖 Создать бота» чтобы начать!", []}
    else
      lines = Enum.map(bots, fn bot ->
        status = if bot[:active], do: "🟢", else: "🔴"
        "#{status} *#{bot.name}*"
      end)
      text = "Твои боты:\n\n" <> Enum.join(lines, "\n")

      buttons = Enum.map(bots, fn bot ->
        handle = bot_handle(bot)
        [%{text: "💬 @#{handle}", url: "https://t.me/#{handle}"}]
      end)

      {text, buttons}
    end
  end

  defp bot_handle(bot) do
    name = bot.name || ""
    if String.ends_with?(name, "_bot"), do: name, else: name <> "_bot"
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
    suffix = :crypto.strong_rand_bytes(2) |> Base.encode16(case: :lower)
    "#{slug}_#{suffix}_bot"
  end

  # --- Private ---

  defp personality_reply do
    {:keyboard, "Характер бота:", personality_buttons_page1()}
  end

  defp personality_buttons_page1 do
    page1 = Enum.take(@personalities, 8)
    buttons = Enum.map(page1, fn {key, label} ->
      %{text: label, callback_data: "personality:#{key}"}
    end)
    rows = Enum.chunk_every(buttons, 4)
    rows ++ [[%{text: "Ещё →", callback_data: "more_personalities"}]]
  end

  defp personality_buttons_page2 do
    page2 = Enum.drop(@personalities, 8)
    buttons = Enum.map(page2, fn {key, label} ->
      %{text: label, callback_data: "personality:#{key}"}
    end)
    rows = Enum.chunk_every(buttons, 4)
    rows ++ [[%{text: "← Назад", callback_data: "back_personalities"}]]
  end

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
