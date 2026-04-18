defmodule Druzhok.ManagerBot.Onboarding do
  @moduledoc """
  Pure-function state machine for the manager bot's onboarding flow.

  Steps: :name → :personality → :language → :confirm → :done
  Each step returns {:ok, session, reply} or {:retry, session, reply}.
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
      step: :name,
      name: nil,
      personality: nil,
      language: nil,
      started_at: System.system_time(:second)
    }
  end

  # --- Step handlers ---

  def handle_input(%{step: :name} = session, %{text: text}) do
    name = String.trim(text || "")
    if name == "" do
      {:retry, session, {:text, "Имя не может быть пустым. Как назовём бота?"}}
    else
      session = %{session | step: :personality, name: name}
      {:ok, session, personality_reply()}
    end
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "personality:" <> key}) do
    if key in @personality_keys do
      session = %{session | step: :language, personality: key}
      {:ok, session, language_reply()}
    else
      {:retry, session, personality_reply()}
    end
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "more_personalities"}) do
    {:ok, session, personality_reply_page2()}
  end

  def handle_input(%{step: :personality} = session, %{callback_data: "back_personalities"}) do
    {:ok, session, personality_reply()}
  end

  def handle_input(%{step: :personality} = session, _input) do
    {:retry, session, personality_reply()}
  end

  def handle_input(%{step: :language} = session, %{callback_data: "lang:" <> lang})
      when lang in ["ru", "en"] do
    session = %{session | step: :confirm, language: lang}
    {:ok, session, {:confirm, session}}
  end

  def handle_input(%{step: :language} = session, _input) do
    {:retry, session, language_reply()}
  end

  def handle_input(%{step: :confirm} = session, _input) do
    {:retry, session, {:confirm, session}}
  end

  def handle_input(%{step: :done} = session, _input) do
    {:retry, session, {:text, "Бот уже создан!"}}
  end

  def handle_input(session, _input) do
    {:retry, session, {:text, "Что-то пошло не так. Начни заново: /start"}}
  end

  # --- Message builders ---

  def welcome_message do
    "Привет! Я создам тебе персонального AI-бота.\n\nКак его назвать?"
  end

  def confirm_message(session, manager_username) do
    username = generate_bot_username(session.name)
    encoded_name = URI.encode(session.name)
    link = "https://t.me/newbot/#{manager_username}/#{username}?name=#{encoded_name}"

    text = "Создать бота «#{session.name}»? Нажми кнопку:"
    keyboard = [[%{text: "🤖 Создать «#{session.name}»", url: link}]]

    {text, keyboard, link}
  end

  def completion_message(bot_username) do
    "✅ Бот @#{bot_username} создан и запущен!\n→ Написать боту: https://t.me/#{bot_username}"
  end

  def limit_message do
    "У тебя уже 2 бота — это максимум. Удали один из существующих чтобы создать новый."
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
    page1 = Enum.take(@personalities, 8)
    buttons = Enum.map(page1, fn {key, label} ->
      %{text: label, callback_data: "personality:#{key}"}
    end)
    rows = Enum.chunk_every(buttons, 4)
    rows = rows ++ [[%{text: "Ещё...", callback_data: "more_personalities"}]]
    {:keyboard, "Характер бота:", rows}
  end

  defp personality_reply_page2 do
    page2 = Enum.drop(@personalities, 8)
    buttons = Enum.map(page2, fn {key, label} ->
      %{text: label, callback_data: "personality:#{key}"}
    end)
    rows = Enum.chunk_every(buttons, 4)
    rows = rows ++ [[%{text: "← Назад", callback_data: "back_personalities"}]]
    {:keyboard, "Характер бота:", rows}
  end

  defp language_reply do
    {:keyboard, "Язык:", [
      [%{text: "Русский", callback_data: "lang:ru"}, %{text: "English", callback_data: "lang:en"}]
    ]}
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
