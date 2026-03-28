defmodule Druzhok.I18n do
  @moduledoc "Localized system messages. All framework-generated strings go here."

  @strings %{
    # Pairing
    bot_private: %{"ru" => "Этот бот приватный.", "en" => "This bot is private."},
    activation_code: %{"ru" => "Код активации: %{code}\nВведи его в дашборде.", "en" => "Your activation code: %{code}\nEnter it in the dashboard."},
    bot_unavailable: %{"ru" => "Этот бот недоступен.", "en" => "This bot is not available."},
    activation_error: %{"ru" => "Ошибка генерации кода активации.", "en" => "Error generating activation code."},
    group_approval_required: %{"ru" => "Этот бот требует одобрения. Попросите админа одобрить эту группу в дашборде.", "en" => "This bot requires approval. Ask the admin to approve this group in the dashboard."},

    # Session control
    session_reset: %{"ru" => "Сессия сброшена!", "en" => "Session reset!"},
    aborted: %{"ru" => "Прервано.", "en" => "Aborted."},

    # Mode command
    mode_buffer_label: %{"ru" => "буфер (отвечаю только когда обращаются)", "en" => "buffer (respond only when addressed)"},
    mode_always_label: %{"ru" => "всегда (вижу все сообщения)", "en" => "always (see all messages)"},
    mode_set: %{"ru" => "Режим: %{label}", "en" => "Mode: %{label}"},
    mode_help: %{"ru" => "Текущий режим: %{current}\nИспользование: /mode buffer | /mode always", "en" => "Current mode: %{current}\nUsage: /mode buffer | /mode always"},

    # Prompt command
    prompt_not_set: %{"ru" => "(не задан)", "en" => "(not set)"},
    prompt_help: %{"ru" => "Текущий промпт: %{current}\nИспользование: /prompt <текст> для установки, /prompt clear для удаления", "en" => "Current prompt: %{current}\nUsage: /prompt <text> to set, /prompt clear to remove"},
    prompt_cleared: %{"ru" => "Групповой промпт удалён.", "en" => "Group prompt cleared."},
    prompt_set: %{"ru" => "Групповой промпт задан: %{text}", "en" => "Group prompt set: %{text}"},

    # Group intros (injected into LLM context)
    group_intro_buffer: %{
      "ru" => "[Системная инструкция: Ты в групповом чате. Тебя вызвали по имени или ответом на твоё сообщение. Контекст недавних сообщений прикреплён ниже. Всегда отвечай — раз ты это видишь, значит к тебе обратились. Будь краток.]\n",
      "en" => "[System instruction: You are in a group chat. You were called by name or reply. Recent messages context is below. Always respond — if you see this, someone is addressing you. Be brief.]\n"
    },
    group_intro_always: %{
      "ru" => "[Системная инструкция: Ты в групповом чате и видишь все сообщения. Если к тебе не обращаются и ты не можешь добавить ценности — ответь [NO_REPLY]. Не доминируй в разговоре.]\n",
      "en" => "[System instruction: You are in a group chat and see all messages. If not addressed and can't add value — reply [NO_REPLY]. Don't dominate the conversation.]\n"
    },
    group_custom_prompt: %{"ru" => "[Инструкция для этого чата: %{prompt}]\n", "en" => "[Instruction for this chat: %{prompt}]\n"},
    address_required: %{"ru" => "[обращение к тебе — ответ обязателен]", "en" => "[addressing you — response required]"},

    # Voice/file annotations
    voice_message: %{"ru" => "[голосовое сообщение]:", "en" => "[voice message]:"},
    image_default_caption: %{"ru" => "Пользователь отправил изображение", "en" => "User sent an image"},
    user_sent_file: %{"ru" => "Пользователь отправил файл: %{path}", "en" => "User sent a file: %{path}"},
    file_attached: %{"ru" => "[Прикреплён файл: %{path}]", "en" => "[User attached a file: %{path}]"},

    # Tool status
    tool_web_search: %{"ru" => "Ищу в интернете...", "en" => "Searching the web..."},
    tool_web_fetch: %{"ru" => "Загружаю страницу...", "en" => "Fetching page..."},
    tool_bash: %{"ru" => "Выполняю команду...", "en" => "Running command..."},
    tool_read: %{"ru" => "Читаю файл...", "en" => "Reading file..."},
    tool_write: %{"ru" => "Пишу файл...", "en" => "Writing file..."},
    tool_edit: %{"ru" => "Редактирую файл...", "en" => "Editing file..."},
    tool_grep: %{"ru" => "Ищу в файлах...", "en" => "Searching files..."},
    tool_find: %{"ru" => "Ищу в файлах...", "en" => "Searching files..."},
    tool_memory_search: %{"ru" => "Ищу в памяти...", "en" => "Searching memory..."},
    tool_memory_write: %{"ru" => "Сохраняю в память...", "en" => "Saving to memory..."},
    tool_generate_image: %{"ru" => "Генерирую изображение...", "en" => "Generating image..."},
    tool_send_file: %{"ru" => "Отправляю файл...", "en" => "Sending file..."},
    tool_set_reminder: %{"ru" => "Устанавливаю напоминание...", "en" => "Setting reminder..."},
    tool_default: %{"ru" => "Работаю...", "en" => "Working..."},

    # Token budget
    token_limit_exceeded: %{"ru" => "⚠️ Дневной лимит токенов исчерпан. Попробуй завтра.", "en" => "⚠️ Daily token limit exceeded. Try again tomorrow."},
    token_warning_80: %{"ru" => "⚠️ Экономь токены — отвечай кратко, минимум инструментов.", "en" => "⚠️ Save tokens — be brief, minimize tool usage."},
    tokens_today_unlimited: %{"ru" => "Токены сегодня: %{used} (без лимита)", "en" => "Tokens today: %{used} (unlimited)"},
    tokens_today_limited: %{"ru" => "Токены сегодня: %{used} из %{limit} (%{pct}% осталось)", "en" => "Tokens today: %{used} of %{limit} (%{pct}% remaining)"},

    # Errors
    error_timeout: %{"ru" => "⏱ Сервер не ответил. Попробуй ещё раз.", "en" => "⏱ Server timed out. Try again."},
    error_connection_lost: %{"ru" => "🔌 Соединение потеряно. Попробуй ещё раз.", "en" => "🔌 Connection lost. Try again."},
    error_unavailable: %{"ru" => "🚫 Сервер недоступен. Попробуй позже.", "en" => "🚫 Server unavailable. Try later."},
    error_rate_limited: %{"ru" => "⏳ Слишком много запросов. Подожди немного.", "en" => "⏳ Rate limited. Wait a moment."},
    error_server: %{"ru" => "💥 Ошибка сервера. Попробуй ещё раз.", "en" => "💥 Server error. Try again."},

    # Runtime section
    runtime_model: %{"ru" => "Модель", "en" => "Model"},
    runtime_date: %{"ru" => "Дата", "en" => "Date"},
    runtime_sandbox: %{"ru" => "Sandbox", "en" => "Sandbox"},
    sandbox_docker: %{"ru" => "Docker (python3, node, bash)", "en" => "Docker (python3, node, bash)"},
    sandbox_firecracker: %{"ru" => "Firecracker (isolated VM)", "en" => "Firecracker (isolated VM)"},
    sandbox_local: %{"ru" => "Local (без песочницы)", "en" => "Local (no sandbox)"},
  }

  @doc "Get a translated string. Supports %{key} interpolation."
  def t(key, lang, params \\ %{})
  def t(key, lang, params) do
    lang = lang || "ru"
    case @strings[key] do
      nil -> "??#{key}??"
      translations ->
        text = translations[lang] || translations["ru"] || "??#{key}??"
        Enum.reduce(params, text, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)
    end
  end

  @doc "Get the language for an instance."
  def lang(instance_name) do
    case Druzhok.Repo.get_by(Druzhok.Instance, name: instance_name) do
      %{language: l} when l in ["ru", "en"] -> l
      _ -> "ru"
    end
  end
end
