defmodule Druzhok.ManagerBot do
  @moduledoc """
  Telegram manager bot GenServer.

  Long-polls the Telegram Bot API for a dedicated manager bot token.
  Handles onboarding conversations via inline keyboards, then provisions
  hermes instances when users create managed bots.
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
      text == "/start" or not Map.has_key?(state.sessions, user_id) ->
        start_onboarding(state, user_id, chat_id)

      true ->
        dispatch_input(state, user_id, chat_id, %{text: text})
    end
  end

  defp process_update(%{"callback_query" => cb}, state) do
    user_id = cb["from"]["id"]
    chat_id = cb["message"]["chat"]["id"]
    data = cb["data"]

    API.answer_callback_query(state.token, cb["id"])
    dispatch_input(state, user_id, chat_id, %{callback_data: data})
  end

  defp process_update(%{"managed_bot" => managed_bot}, state) do
    handle_managed_bot(state, managed_bot)
  end

  defp process_update(_update, state), do: state

  # --- Onboarding ---

  defp start_onboarding(state, user_id, chat_id) do
    if user_bot_count(user_id) >= @max_bots_per_user do
      API.send_message(state.token, chat_id, Onboarding.limit_message())
      state
    else
      session = Onboarding.new_session()
      API.send_message(state.token, chat_id, Onboarding.welcome_message())
      put_in(state, [:sessions, user_id], session)
    end
  end

  defp dispatch_input(state, user_id, chat_id, input) do
    session = state.sessions[user_id] || Onboarding.new_session()

    case Onboarding.handle_input(session, input) do
      {_status, session, {:confirm, session}} ->
        {text, keyboard, _link} = Onboarding.confirm_message(session, state.bot_username)
        send_with_inline_keyboard(state.token, chat_id, text, keyboard)
        put_in(state, [:sessions, user_id], session)

      {_status, session, {:keyboard, text, rows}} ->
        send_with_callback_keyboard(state.token, chat_id, text, rows)
        put_in(state, [:sessions, user_id], session)

      {_status, session, {:text, text}} ->
        API.send_message(state.token, chat_id, text)
        put_in(state, [:sessions, user_id], session)
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
      case Provisioner.provision(token, bot_id, bot_username, session) do
        {:ok, _name, username} ->
          msg = Onboarding.completion_message(username)
          API.send_message(token, creator_id, msg)

        {:error, reason} ->
          API.send_message(token, creator_id,
            "Ошибка создания бота: #{inspect(reason)}\nПопробуй ещё раз.")
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

  defp send_with_callback_keyboard(token, chat_id, text, rows) do
    keyboard = %{
      inline_keyboard: Enum.map(rows, fn row ->
        Enum.map(row, fn btn ->
          %{text: btn.text, callback_data: btn.callback_data}
        end)
      end)
    }
    API.send_message(token, chat_id, text, %{reply_markup: Jason.encode!(keyboard)})
  end

  defp send_with_inline_keyboard(token, chat_id, text, rows) do
    keyboard = %{
      inline_keyboard: Enum.map(rows, fn row ->
        Enum.map(row, fn btn ->
          if btn[:url] do
            %{text: btn.text, url: btn.url}
          else
            %{text: btn.text, callback_data: btn[:callback_data] || "noop"}
          end
        end)
      end)
    }
    API.send_message(token, chat_id, text, %{reply_markup: Jason.encode!(keyboard)})
  end
end
