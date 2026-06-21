defmodule Druzhok.ManagerBot do
  @moduledoc """
  Telegram manager bot GenServer.

  Long-polls the Telegram Bot API for a dedicated manager bot token.
  Handles onboarding conversations via inline keyboards (edited in place),
  a persistent reply keyboard for navigation, and provisions hermes
  instances when users create managed bots.
  """
  use GenServer
  require Logger

  alias Druzhok.Telegram.API
  alias Druzhok.ManagerBot.{Onboarding, Provisioner}

  @session_ttl_seconds 600
  @poll_timeout 30
  @max_bots_per_user 2

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    state = %{
      token: nil,
      bot_username: nil,
      offset: 0,
      sessions: %{},
      polling: false
    }
    send(self(), :try_start)
    {:ok, state}
  end

  @impl true
  def handle_info(:try_start, state) do
    token = Druzhok.Settings.get("manager_bot_token")

    if token && token != "" do
      case API.get_me(token) do
        {:ok, %{"username" => username}} ->
          Logger.info("ManagerBot started as @#{username}")
          send(self(), :poll)
          {:noreply, %{state | token: token, bot_username: username, polling: true}}

        {:error, reason} ->
          Logger.warning("ManagerBot: getMe failed (#{inspect(reason)}), retrying in 30s")
          Process.send_after(self(), :try_start, 30_000)
          {:noreply, state}
      end
    else
      Logger.info("ManagerBot: no manager_bot_token configured, staying idle")
      Process.send_after(self(), :try_start, 60_000)
      {:noreply, state}
    end
  end

  def handle_info(:poll, %{token: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    case API.get_updates(state.token, state.offset, @poll_timeout) do
      {:ok, updates} when is_list(updates) ->
        state = Enum.reduce(updates, state, &process_update/2)
        new_offset = if updates != [], do: List.last(updates)["update_id"] + 1, else: state.offset
        state = cleanup_expired_sessions(%{state | offset: new_offset})
        send(self(), :poll)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("ManagerBot poll error: #{inspect(reason)}")
        Process.send_after(self(), :poll, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- Update processing ---

  defp process_update(%{"message" => msg}, state) do
    user_id = get_in(msg, ["from", "id"])
    chat_id = msg["chat"]["id"]
    text = msg["text"] || ""

    cond do
      text == "/start" ->
        show_main_menu(state, user_id, chat_id)

      text in ["🤖 Создать бота", "📋 Мои боты"] ->
        dispatch_input(state, user_id, chat_id, %{text: text})

      Map.has_key?(state.sessions, user_id) and
          state.sessions[user_id].step in [:name, :language, :confirm] ->
        # Mid-onboarding: route stray text through the state machine (which
        # re-prompts) instead of resetting the session to the main menu.
        dispatch_input(state, user_id, chat_id, %{text: text})

      true ->
        show_main_menu(state, user_id, chat_id)
    end
  end

  defp process_update(%{"callback_query" => cb}, state) do
    # Telegram can send a callback whose `message` is inaccessible (too old) —
    # `cb["message"]` is then nil. Acknowledge and ignore rather than crash.
    case cb["message"] do
      nil ->
        API.answer_callback_query(state.token, cb["id"])
        state

      message ->
        user_id = cb["from"]["id"]
        chat_id = message["chat"]["id"]
        message_id = message["message_id"]
        data = cb["data"]

        API.answer_callback_query(state.token, cb["id"])

        # Store message_id in session for editing
        state = update_in(state, [:sessions, user_id], fn
          nil -> %{Onboarding.new_session() | message_id: message_id}
          session -> %{session | message_id: message_id}
        end)

        dispatch_input(state, user_id, chat_id, %{callback_data: data})
    end
  end

  defp process_update(%{"managed_bot" => managed_bot}, state) do
    handle_managed_bot(state, managed_bot)
  end

  defp process_update(_update, state), do: state

  # --- Main menu ---

  defp show_main_menu(state, user_id, chat_id) do
    menu = Onboarding.main_menu_keyboard()
    API.send_message(state.token, chat_id, Onboarding.welcome_message(),
      %{reply_markup: Jason.encode!(menu)})
    put_in(state, [:sessions, user_id], Onboarding.new_session())
  end

  # --- Onboarding dispatch ---

  defp dispatch_input(state, user_id, chat_id, input) do
    session = state.sessions[user_id] || Onboarding.new_session()

    # Check bot limit before starting creation
    if input == %{text: "🤖 Создать бота"} and user_bot_count(user_id) >= @max_bots_per_user do
      API.send_message(state.token, chat_id, Onboarding.limit_message())
      state
    else
      case Onboarding.handle_input(session, input) do
        {_status, session, {:my_bots}} ->
          send_my_bots(state, user_id, chat_id)
          put_in(state, [:sessions, user_id], session)

        {_status, session, {:text, text}} ->
          API.send_message(state.token, chat_id, text)
          put_in(state, [:sessions, user_id], session)

        {_status, session, {:keyboard, text, rows}} ->
          # First inline keyboard — send new message, store its ID
          case send_inline(state.token, chat_id, text, rows) do
            {:ok, %{"message_id" => mid}} ->
              session = %{session | message_id: mid}
              put_in(state, [:sessions, user_id], session)
            _ ->
              put_in(state, [:sessions, user_id], session)
          end

        {_status, session, {:edit, text, rows}} ->
          # Edit existing inline message
          if session.message_id do
            edit_inline(state.token, chat_id, session.message_id, text, rows)
          else
            case send_inline(state.token, chat_id, text, rows) do
              {:ok, %{"message_id" => mid}} ->
                session = %{session | message_id: mid}
              _ -> :ok
            end
          end
          put_in(state, [:sessions, user_id], session)

        {_status, session, {:confirm, session}} ->
          {text, keyboard, _link} = Onboarding.confirm_message(session, state.bot_username)
          send_url_keyboard(state.token, chat_id, text, keyboard)
          put_in(state, [:sessions, user_id], session)

        {_status, session, {:edit_confirm, session}} ->
          {text, keyboard, _link} = Onboarding.confirm_message(session, state.bot_username)
          if session.message_id do
            edit_url_keyboard(state.token, chat_id, session.message_id, text, keyboard)
          else
            send_url_keyboard(state.token, chat_id, text, keyboard)
          end
          put_in(state, [:sessions, user_id], session)
      end
    end
  end

  # --- My Bots ---

  defp send_my_bots(state, user_id, chat_id) do
    import Ecto.Query
    bots = Druzhok.Repo.all(
      from(i in Druzhok.Instance,
        where: i.owner_telegram_id == ^user_id,
        order_by: [desc: i.active, asc: i.name])
    )
    |> Enum.map(fn inst ->
      inst
      |> Map.from_struct()
      |> Map.put(:spent_today_cents, Druzhok.Budget.spent_today_cents(inst.id))
    end)

    {text, buttons} = Onboarding.my_bots_message(bots)

    if buttons == [] do
      API.send_message(state.token, chat_id, text)
    else
      send_url_keyboard(state.token, chat_id, text, buttons)
    end
  end

  # --- Managed bot creation ---

  defp handle_managed_bot(state, managed_bot) do
    creator_id = get_in(managed_bot, ["user", "id"])
    bot_id = get_in(managed_bot, ["bot", "id"])
    bot_username = get_in(managed_bot, ["bot", "username"])

    session = Map.get(state.sessions, creator_id, %{})
    session = Map.put(session, :owner_id, creator_id)

    token = state.token

    Task.start(fn ->
      try do
        case Provisioner.provision(token, bot_id, bot_username, session) do
          {:ok, _name, username} ->
            msg = Onboarding.completion_message(username)
            API.send_message(token, creator_id, msg)

          {:error, reason} ->
            API.send_message(token, creator_id,
              "Ошибка создания бота: #{inspect(reason)}\nПопробуй ещё раз.")
        end
      rescue
        e ->
          Logger.error("Provisioning crashed for @#{bot_username}: #{Exception.message(e)}")
          API.send_message(token, creator_id,
            "Ошибка создания бота. Попробуй ещё раз.")
      end
    end)

    update_in(state, [:sessions], &Map.delete(&1, creator_id))
  end

  # --- Helpers ---

  defp user_bot_count(user_id) do
    import Ecto.Query
    Druzhok.Repo.aggregate(
      from(i in Druzhok.Instance, where: i.owner_telegram_id == ^user_id),
      :count
    )
  end

  defp cleanup_expired_sessions(state) do
    now = System.system_time(:second)
    sessions =
      state.sessions
      |> Enum.reject(fn {_uid, session} ->
        (now - (session[:started_at] || 0)) > @session_ttl_seconds
      end)
      |> Map.new()
    %{state | sessions: sessions}
  end

  # --- Telegram message helpers ---

  defp send_inline(token, chat_id, text, rows) do
    keyboard = build_callback_keyboard(rows)
    API.send_message(token, chat_id, text, %{reply_markup: Jason.encode!(keyboard)})
  end

  defp edit_inline(token, chat_id, message_id, text, rows) do
    keyboard = build_callback_keyboard(rows)
    API.edit_message_text(token, chat_id, message_id, text,
      %{reply_markup: Jason.encode!(keyboard)})
  end

  defp send_url_keyboard(token, chat_id, text, rows) do
    keyboard = build_url_keyboard(rows)
    API.send_message(token, chat_id, text,
      %{reply_markup: Jason.encode!(keyboard), parse_mode: "Markdown"})
  end

  defp edit_url_keyboard(token, chat_id, message_id, text, rows) do
    keyboard = build_url_keyboard(rows)
    API.edit_message_text(token, chat_id, message_id, text,
      %{reply_markup: Jason.encode!(keyboard), parse_mode: "Markdown"})
  end

  defp build_callback_keyboard(rows) do
    %{inline_keyboard: Enum.map(rows, fn row ->
      Enum.map(row, fn btn ->
        %{text: btn.text, callback_data: btn.callback_data}
      end)
    end)}
  end

  defp build_url_keyboard(rows) do
    %{inline_keyboard: Enum.map(rows, fn row ->
      Enum.map(row, fn btn ->
        if btn[:url] do
          %{text: btn.text, url: btn.url}
        else
          %{text: btn.text, callback_data: btn[:callback_data] || "noop"}
        end
      end)
    end)}
  end
end
