defmodule Druzhok.I18n do
  @moduledoc "Localized messages druzhok itself sends to a bot's users."

  @strings %{
    # Sent by `ops/druzhok approve <bot> <id>` unless the bot has its own.
    welcome_default: %{
      "ru" => "Доступ одобрен! Можете начать общение с ботом.",
      "en" => "Access approved! You can now start chatting with the bot."
    }
  }

  @doc "Get a translated string. Supports %{key} interpolation."
  def t(key, lang, params \\ %{}) do
    lang = lang || "ru"

    case @strings[key] do
      nil ->
        "??#{key}??"

      translations ->
        text = translations[lang] || translations["ru"] || "??#{key}??"

        Enum.reduce(params, text, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
    end
  end
end
