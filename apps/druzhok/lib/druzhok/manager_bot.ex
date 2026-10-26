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
  alias Druzhok.{Admissions, BotManager, Repo, Instance, Settings}

  @session_ttl_seconds 600
  @poll_timeout 30
  @max_bots_per_user 1

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

  # The answer to a check started in `start_invite_check/5`. A /start or a TTL
  # prune in the meantime makes it stale, so the session has to still be the one
  # waiting on this exact code.
  def handle_info({:invite_result, user_id, chat_id, code, result}, state) do
    case state.sessions[user_id] do
      %{step: :checking, invite: ^code} = session ->
        {:noreply, apply_invite_result(state, user_id, chat_id, session, code, result)}

      _ ->
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
      # A code of theirs is already with ruoc. Everything they send until the
      # answer lands is dropped: that is what stops one person from spending a
      # round trip of the shared poll loop per message.
      checking?(state, user_id) ->
        state

      text == "/start" ->
        show_main_menu(state, user_id, chat_id)

      String.starts_with?(text, "/start ref_") ->
        handle_start_ref(state, user_id, chat_id, text |> String.trim_leading("/start ref_") |> String.trim())

      String.starts_with?(text, "/start") ->
        show_main_menu(state, user_id, chat_id)

      text in Onboarding.menu_texts() ->
        handle_menu(state, user_id, chat_id, text)

      Map.has_key?(state.sessions, user_id) and
          state.sessions[user_id].step in [:name, :language, :confirm, :invite] ->
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
        data = cb["data"] || ""

        if moved_to_panel?(data, user_id) do
          # Old 🎨/🗑 buttons of a bot whose controls are in its panel now.
          API.answer_callback_query(state.token, cb["id"], %{
            text: Onboarding.moved_to_panel_alert(),
            show_alert: true
          })

          state
        else
          API.answer_callback_query(state.token, cb["id"])
          handle_callback(state, user_id, chat_id, message_id, data)
        end
    end
  end

  defp process_update(%{"managed_bot" => managed_bot}, state) do
    handle_managed_bot(state, managed_bot)
  end

  defp process_update(_update, state), do: state

  defp handle_callback(state, user_id, chat_id, message_id, data) do
    cond do
      String.starts_with?(data, "pdel:") ->
        handle_panel_delete(state, user_id, chat_id, message_id, data)

      String.starts_with?(data, "pdelno:") ->
        handle_panel_delete_cancel(state, chat_id, message_id, data)

      String.starts_with?(data, "del:") ->
        handle_delete_request(state, user_id, chat_id, message_id, data)

      String.starts_with?(data, "delyes:") ->
        handle_delete_confirm(state, user_id, chat_id, message_id, data)

      data == "delno" ->
        edit_plain(state.token, chat_id, message_id, Onboarding.delete_cancelled())
        state

      String.starts_with?(data, "img:") ->
        handle_image_menu(state, user_id, chat_id, message_id, data)

      String.starts_with?(data, "imgset:") ->
        handle_image_set(state, user_id, chat_id, message_id, data)

      String.starts_with?(data, "imgoff:") ->
        handle_image_off(state, user_id, chat_id, message_id, data)

      data == "imgback" ->
        # One bot means there is no list to go back to: the card is «Назад».
        case user_bots(user_id) do
          [bot] ->
            # Same ruoc round trip as the «🤖 Мой бот» card, same reason to
            # build it off the loop.
            token = state.token

            Task.start(fn ->
              {text, rows} = Onboarding.my_bot_message(with_balance(bot))
              edit_url_keyboard(token, chat_id, message_id, text, rows)
            end)

          _ ->
            edit_my_bots(state, user_id, chat_id, message_id)
        end

        state

      true ->
        # Store message_id in session for editing
        state = update_in(state, [:sessions, user_id], fn
          nil -> %{Onboarding.new_session() | message_id: message_id}
          session -> %{session | message_id: message_id}
        end)

        dispatch_input(state, user_id, chat_id, %{callback_data: data})
    end
  end

  @old_controls ~w(img: imgset: imgoff: del: delyes:)

  # The callbacks of the superbot's own picture and delete controls, on a bot
  # whose panel works (panel controls spec, «Superbot»): they do nothing.
  defp moved_to_panel?(data, user_id) do
    cond do
      prefix = Enum.find(@old_controls, &String.starts_with?(data, &1)) ->
        id_str = data |> String.replace_prefix(prefix, "") |> String.split(":") |> hd()

        case owned_instance(user_id, id_str) do
          {:ok, inst} -> Onboarding.panel_ready?(inst)
          _ -> false
        end

      data in ["delno", "imgback"] ->
        case user_bots(user_id) do
          [bot] -> Onboarding.panel_ready?(bot)
          _ -> false
        end

      true ->
        false
    end
  end

  # --- Main menu ---

  defp show_main_menu(state, user_id, chat_id) do
    send_menu(state, chat_id, user_id, Onboarding.welcome_message())
    put_in(state, [:sessions, user_id], Onboarding.new_session())
  end

  # Any message that should also (re)place the reply keyboard. The keyboard is
  # computed from the bot count every time, never cached: creation and
  # deletion change it, and both happen in tasks after this GenServer replied.
  defp send_menu(state, chat_id, user_id, text) do
    API.send_message(state.token, chat_id, text, %{reply_markup: Jason.encode!(menu_for(user_id))})
  end

  defp menu_for(user_id) do
    case user_bots(user_id) do
      [bot] -> Onboarding.main_menu_keyboard(1, Onboarding.panel_ready?(bot))
      bots -> Onboarding.main_menu_keyboard(length(bots))
    end
  end

  defp panel_ready_for?(user_id) do
    case user_bots(user_id) do
      [bot] -> Onboarding.panel_ready?(bot)
      _ -> false
    end
  end

  defp handle_menu(state, user_id, chat_id, "🤖 Создать бота"),
    do: dispatch_input(state, user_id, chat_id, %{text: "🤖 Создать бота"})

  defp handle_menu(state, user_id, chat_id, "📋 Мои боты"),
    do: dispatch_input(state, user_id, chat_id, %{text: "📋 Мои боты"})

  defp handle_menu(state, user_id, chat_id, text) do
    case user_bots(user_id) do
      [bot] ->
        one_bot_menu(state, chat_id, bot, text)

      # The keyboard on their screen is stale (bot deleted or a second one
      # appeared); the fresh one comes with the menu.
      _ ->
        show_main_menu(state, user_id, chat_id)
    end
  end

  # The three read-only cards each wait on a ruoc round trip. One GenServer
  # serves everybody, so they run in a task: a hung gateway then keeps one
  # person waiting instead of stopping the whole superbot. All three leave the
  # state untouched, so there is nothing to carry back.
  defp one_bot_menu(state, chat_id, bot, "🤖 Мой бот") do
    token = state.token

    Task.start(fn ->
      {text, rows} = Onboarding.my_bot_message(with_balance(bot))
      send_url_keyboard(token, chat_id, text, rows)
    end)

    state
  end

  # A stale 🎨/🗑 label of a bot set up in its panel: say where it went, and
  # replace the persistent keyboard. Other bots keep the superbot's controls.
  defp one_bot_menu(state, chat_id, bot, label) when label in ["🎨 Картинки", "🗑 Удалить"] do
    if Onboarding.panel_ready?(bot) do
      menu = Onboarding.main_menu_keyboard(1, true)

      API.send_message(state.token, chat_id, Onboarding.moved_to_panel(), %{
        reply_markup: Jason.encode!(menu)
      })

      state
    else
      own_control(state, chat_id, bot, label)
    end
  end

  defp one_bot_menu(state, chat_id, bot, "🎁 Пригласить") do
    token = state.token
    manager_username = state.bot_username
    api_key = bot.ruoc_api_key

    Task.start(fn ->
      case api_key && Druzhok.Ruoc.referrals(api_key) do
        {:ok, codes} ->
          for {text, rows} <- Onboarding.referrals_messages(codes, manager_username) do
            if rows == [],
              do: API.send_message(token, chat_id, text),
              else: send_url_keyboard_plain(token, chat_id, text, rows)
          end

        _ ->
          API.send_message(token, chat_id, "Не получилось загрузить приглашения, попробуй позже.")
      end
    end)

    state
  end

  defp own_control(state, chat_id, bot, "🎨 Картинки") do
    token = state.token

    Task.start(fn ->
      {text, rows} = Onboarding.image_menu(Map.from_struct(bot), Druzhok.Ruoc.image_models())
      send_inline(token, chat_id, text, rows)
    end)

    state
  end

  defp own_control(state, chat_id, bot, "🗑 Удалить") do
    {text, rows} = Onboarding.delete_confirm(bot.id, bot_display_handle(bot))
    send_inline(state.token, chat_id, text, rows)
    state
  end

  defp user_bots(user_id) do
    import Ecto.Query

    Repo.all(
      from(i in Instance,
        where: i.owner_telegram_id == ^user_id and not i.delete_requested,
        order_by: [desc: i.active, asc: i.name]
      )
    )
  end

  defp with_balance(inst) do
    {balance, subscription} =
      case inst.ruoc_api_key && Druzhok.Ruoc.balance(inst.ruoc_api_key) do
        {:ok, %{balance_rub: rub, subscription: sub}} -> {rub, sub}
        _ -> {nil, nil}
      end

    inst
    |> Map.from_struct()
    |> Map.put(:ruoc_balance_rub, balance)
    |> Map.put(:ruoc_subscription, subscription)
    |> Map.put(:panel_ready, Onboarding.panel_ready?(inst))
  end

  # --- Onboarding dispatch ---

  defp dispatch_input(state, user_id, chat_id, input) do
    session = state.sessions[user_id] || Onboarding.new_session()

    cond do
      input == %{text: "🤖 Создать бота"} and closed?(user_id) ->
        API.send_message(state.token, chat_id, Onboarding.closed_message())
        state

      # Check bot limit before starting creation; the operator has no limit.
      input == %{text: "🤖 Создать бота"} and not operator?(user_id) and
          user_bot_count(user_id) >= @max_bots_per_user ->
        API.send_message(state.token, chat_id, Onboarding.limit_message())
        state

      input == %{text: "🤖 Создать бота"} and not may_create?(user_id) ->
        {session, prompt} = Onboarding.ask_invite(session)
        API.send_message(state.token, chat_id, prompt)
        put_in(state, [:sessions, user_id], session)

      true ->
        case Onboarding.handle_input(session, input) do
          {_status, session, {:check_invite, code}} ->
            start_invite_check(state, user_id, chat_id, session, code)

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
            # Edit existing inline message, or send a fresh one if we lost it
            session =
              if session.message_id do
                edit_inline(state.token, chat_id, session.message_id, text, rows)
                session
              else
                case send_inline(state.token, chat_id, text, rows) do
                  {:ok, %{"message_id" => mid}} -> %{session | message_id: mid}
                  _ -> session
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

  # --- Invite gate ---

  # Admitted people and the operator skip the prompt; nobody else does. A code
  # sitting on the session is never permission: the deep link checks it before
  # naming begins, and pressing create again mid-naming drops it, so trusting
  # it would create a bot whose code was never redeemed.
  defp may_create?(user_id) do
    operator?(user_id) or Admissions.admitted?(user_id)
  end

  # Creation closed in Settings (`bot_creation`). The operator is never shut out.
  defp closed?(user_id) do
    Settings.bot_creation_closed?() and not operator?(user_id)
  end

  defp operator?(user_id) do
    case Settings.operator_telegram_id() do
      nil -> false
      id -> to_string(id) == to_string(user_id)
    end
  end

  defp checking?(state, user_id) do
    case state.sessions[user_id] do
      %{step: :checking} -> true
      _ -> false
    end
  end

  # Asking ruoc about a code is a round trip, and it is the one ruoc call an
  # unadmitted stranger can trigger at will. It runs in a task and answers this
  # GenServer with a message; the session parks at :checking meanwhile.
  defp start_invite_check(state, user_id, chat_id, session, code) do
    server = self()

    Task.start(fn ->
      result =
        try do
          Druzhok.Ruoc.check_invite(code)
        rescue
          e -> {:error, Exception.message(e)}
        end

      send(server, {:invite_result, user_id, chat_id, code, result})
    end)

    put_in(state, [:sessions, user_id], Onboarding.begin_check(session, code))
  end

  defp apply_invite_result(state, user_id, chat_id, session, code, result) do
    case result do
      {:ok, :available} ->
        {session, text} = Onboarding.begin_create(session, code)
        API.send_message(state.token, chat_id, text)
        put_in(state, [:sessions, user_id], session)

      {:ok, status} ->
        API.send_message(state.token, chat_id, Onboarding.invite_status_message(status))
        put_in(state, [:sessions, user_id], Onboarding.new_session())

      {:error, reason} ->
        Logger.warning("invite check failed for #{user_id}: #{inspect(reason)}")
        API.send_message(state.token, chat_id, Onboarding.invite_status_message(:error))
        put_in(state, [:sessions, user_id], Onboarding.new_session())
    end
  end

  # /start ref_<code>: the welcome and keyboard first, as any /start, then —
  # for somebody not yet admitted — the code is checked and naming begins.
  defp handle_start_ref(state, user_id, chat_id, code) do
    state = show_main_menu(state, user_id, chat_id)

    cond do
      code == "" or may_create?(user_id) or user_bot_count(user_id) >= @max_bots_per_user ->
        state

      closed?(user_id) ->
        API.send_message(state.token, chat_id, Onboarding.closed_message())
        state

      true ->
        start_invite_check(state, user_id, chat_id, Onboarding.new_session(), code)
    end
  end

  # --- My Bots ---

  defp send_my_bots(state, user_id, chat_id) do
    {text, buttons} = my_bots_payload(user_id)

    if buttons == [] do
      API.send_message(state.token, chat_id, text)
    else
      send_url_keyboard(state.token, chat_id, text, buttons)
    end
  end

  # «Назад» from a bot's submenu: the same list, edited into that message.
  defp edit_my_bots(state, user_id, chat_id, message_id) do
    {text, buttons} = my_bots_payload(user_id)

    if buttons == [] do
      edit_plain(state.token, chat_id, message_id, text)
    else
      edit_url_keyboard(state.token, chat_id, message_id, text, buttons)
    end
  end

  defp my_bots_payload(user_id) do
    user_bots(user_id) |> Enum.map(&with_balance/1) |> Onboarding.my_bots_message()
  end

  # --- Picture menu (image generation on/off + model, owner-only) ---

  defp handle_image_menu(state, user_id, chat_id, message_id, "img:" <> id_str) do
    with_owned(state, user_id, chat_id, message_id, id_str, fn instance ->
      show_image_menu(state.token, chat_id, message_id, instance)
    end)
  end

  defp handle_image_set(state, user_id, chat_id, message_id, "imgset:" <> rest) do
    {id_str, model} =
      case String.split(rest, ":", parts: 2) do
        [id_str, model] -> {id_str, model}
        [id_str] -> {id_str, nil}
      end

    with_owned(state, user_id, chat_id, message_id, id_str, fn instance ->
      case BotManager.update_image_gen(instance.name, true, model) do
        {:ok, updated} ->
          if instance.image_gen_enabled do
            # The proxy reads the model per request: nothing to restart.
            show_image_menu(state.token, chat_id, message_id, updated)
          else
            restart_for_images(state.token, chat_id, message_id, updated, :enabled)
          end

        {:error, _} ->
          edit_plain(state.token, chat_id, message_id, Onboarding.image_failed(bot_display_handle(instance)))
      end
    end)
  end

  defp handle_image_off(state, user_id, chat_id, message_id, "imgoff:" <> id_str) do
    with_owned(state, user_id, chat_id, message_id, id_str, fn instance ->
      if instance.image_gen_enabled do
        case BotManager.update_image_gen(instance.name, false, instance.image_gen_model) do
          {:ok, updated} -> restart_for_images(state.token, chat_id, message_id, updated, :disabled)
          {:error, _} -> edit_plain(state.token, chat_id, message_id, Onboarding.image_failed(bot_display_handle(instance)))
        end
      else
        show_image_menu(state.token, chat_id, message_id, instance)
      end
    end)
  end

  defp show_image_menu(token, chat_id, message_id, instance) do
    {text, rows} = Onboarding.image_menu(Map.from_struct(instance), Druzhok.Ruoc.image_models())
    edit_inline(token, chat_id, message_id, text, rows)
  end

  # Only the on/off state reaches hermes's config, so a restart is needed for
  # that and nothing else. Async like deletion: stopping a unit takes seconds.
  defp restart_for_images(token, chat_id, message_id, instance, change) do
    handle = bot_display_handle(instance)
    name = instance.name
    edit_plain(token, chat_id, message_id, Onboarding.image_restarting(change, handle))

    Task.start(fn ->
      text =
        try do
          case BotManager.restart(name, wait: true) do
            {:ok, _} ->
              model =
                case change do
                  :enabled ->
                    case Druzhok.Ruoc.image_models() do
                      {:ok, models} -> Onboarding.current_image_model(Map.from_struct(instance), models)
                      _ -> nil
                    end

                  :disabled ->
                    nil
                end

              if change == :enabled and is_nil(model),
                do: "✅ Картинки включены для @#{handle}",
                else: Onboarding.image_result(change, handle, model)

            _ ->
              Onboarding.image_failed(handle)
          end
        rescue
          e ->
            Logger.error("Image restart crashed for #{name}: #{Exception.message(e)}")
            Onboarding.image_failed(handle)
        end

      edit_plain(token, chat_id, message_id, text)
    end)
  end

  defp with_owned(state, user_id, chat_id, message_id, id_str, fun) do
    case owned_instance(user_id, id_str) do
      {:ok, instance} -> fun.(instance)
      {:error, :not_owner} -> API.send_message(state.token, chat_id, "Это не твой бот.")
      {:error, :not_found} -> edit_plain(state.token, chat_id, message_id, "Бот не найден.")
    end

    state
  end

  # --- Bot deletion (two-step confirm, owner-only) ---

  defp handle_delete_request(state, user_id, chat_id, message_id, "del:" <> id_str) do
    case owned_instance(user_id, id_str) do
      {:ok, instance} ->
        {text, rows} = Onboarding.delete_confirm(instance.id, bot_display_handle(instance))
        edit_inline(state.token, chat_id, message_id, text, rows)

      {:error, :not_owner} ->
        API.send_message(state.token, chat_id, "Это не твой бот.")

      {:error, :not_found} ->
        API.send_message(state.token, chat_id, "Бот не найден.")
    end

    state
  end

  defp handle_delete_confirm(state, user_id, chat_id, message_id, "delyes:" <> id_str) do
    case owned_instance(user_id, id_str) do
      {:ok, instance} ->
        handle = bot_display_handle(instance)
        name = instance.name
        token = state.token
        owner_id = user_id

        # Run the wipe async — stopping the unit can take a couple seconds and must
        # not block the poll loop.
        Task.start(fn ->
          try do
            case BotManager.delete(name, wait: true) do
              :ok ->
                edit_plain(token, chat_id, message_id, Onboarding.delete_done(handle))
                menu = menu_for(owner_id)

                API.send_message(token, chat_id, Onboarding.after_delete_message(), %{
                  reply_markup: Jason.encode!(menu)
                })

              {:error, reason} ->
                edit_plain(token, chat_id, message_id, Onboarding.delete_failed_message(reason))
            end
          rescue
            e ->
              Logger.error("Delete crashed for #{name}: #{Exception.message(e)}")
              edit_plain(token, chat_id, message_id, "Ошибка удаления, попробуй ещё раз.")
          end
        end)

      {:error, :not_owner} ->
        API.send_message(state.token, chat_id, "Это не твой бот.")

      {:error, :not_found} ->
        edit_plain(state.token, chat_id, message_id, "Бот не найден.")
    end

    state
  end

  # --- Delete started in the bot panel (panel controls spec, «Delete») ---

  # The confirm the panel asked for. The token, its expiry and the tapping
  # user are all checked; clearing the token is the one-shot (a second tap
  # finds nothing). The delete is a request the lifecycle controller carries
  # out, so nothing waits here.
  defp handle_panel_delete(state, user_id, chat_id, message_id, "pdel:" <> token) do
    import Ecto.Query
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    claimed =
      from(i in Instance,
        where:
          i.delete_confirm_token == ^token and i.owner_telegram_id == ^user_id and
            i.delete_confirm_expires_at > ^now and not i.delete_requested,
        select: i
      )
      |> Repo.update_all(set: [delete_confirm_token: nil, delete_confirm_expires_at: nil])

    case {token, claimed} do
      {t, {1, [inst]}} when t != "" ->
        Logger.info("[superbot] #{inst.name}: delete confirmed by the owner (panel)")
        BotManager.delete(inst.name)

        edit_plain(
          state.token,
          chat_id,
          message_id,
          Onboarding.panel_delete_started(panel_handle(inst))
        )

        API.send_message(state.token, chat_id, Onboarding.after_delete_message(), %{
          reply_markup: Jason.encode!(menu_for(user_id))
        })

      _ ->
        edit_plain(state.token, chat_id, message_id, Onboarding.panel_delete_stale())
    end

    state
  end

  defp handle_panel_delete_cancel(state, chat_id, message_id, "pdelno:" <> token) do
    import Ecto.Query

    if token != "" do
      from(i in Instance, where: i.delete_confirm_token == ^token)
      |> Repo.update_all(set: [delete_confirm_token: nil, delete_confirm_expires_at: nil])
    end

    edit_plain(state.token, chat_id, message_id, Onboarding.delete_cancelled())
    state
  end

  defp panel_handle(inst) do
    Druzhok.Telegram.Addressed.username(inst) || bot_display_handle(inst)
  end

  # Look up an instance by id and confirm it belongs to the requesting user.
  # Ownership is verified here (never trust the callback_data alone).
  defp owned_instance(user_id, id_str) do
    with {id, ""} <- Integer.parse(id_str),
         %Instance{} = inst <- Repo.get(Instance, id) do
      if inst.owner_telegram_id == user_id, do: {:ok, inst}, else: {:error, :not_owner}
    else
      _ -> {:error, :not_found}
    end
  end

  defp bot_display_handle(instance) do
    case instance.trigger_name do
      h when is_binary(h) and h != "" -> h
      _ -> instance.name
    end
  end

  defp edit_plain(token, chat_id, message_id, text) do
    API.edit_message_text(token, chat_id, message_id, text, %{})
  end

  # --- Managed bot creation ---

  defp handle_managed_bot(state, managed_bot) do
    creator_id = get_in(managed_bot, ["user", "id"])
    bot_id = get_in(managed_bot, ["bot", "id"])
    bot_username = get_in(managed_bot, ["bot", "username"])

    session = Map.get(state.sessions, creator_id, %{})
    session = Map.put(session, :owner_id, creator_id)

    token = state.token

    cond do
      # Last line of defence: a flow started before the switch, or the public
      # t.me/newbot link, both arrive here.
      closed?(creator_id) ->
        API.send_message(token, creator_id, Onboarding.closed_message())
        state

      not operator?(creator_id) and user_bot_count(creator_id) >= @max_bots_per_user ->
        API.send_message(token, creator_id, Onboarding.limit_message())
        state

      # The public t.me/newbot link reaches here with no gate of its own, and a
      # pruned session would otherwise create a bot whose code was never
      # redeemed. A code on the session counts here, unlike in `may_create?/1`:
      # this is the call site that forwards it to ruoc.
      not (may_create?(creator_id) or is_binary(session[:invite])) ->
        API.send_message(token, creator_id, Onboarding.invite_prompt())
        state

      true ->
        provision_managed_bot(state, creator_id, bot_id, bot_username, session, token)
    end
  end

  defp provision_managed_bot(state, creator_id, bot_id, bot_username, session, token) do
    Task.start(fn ->
      progress = start_progress(token, creator_id, bot_username)

      result =
        try do
          Provisioner.provision(token, bot_id, bot_username, session)
        rescue
          e ->
            Logger.error("Provisioning crashed for @#{bot_username}: #{Exception.message(e)}")
            {:error, :crashed}
        end

      text =
        case result do
          {:ok, _name, username} -> Onboarding.completion_message(username)
          {:error, :crashed} -> "Ошибка создания бота. Попробуй ещё раз."
          {:error, {:invite, _}} -> Onboarding.create_race_message()
          {:error, :name_taken} -> Onboarding.name_taken_message()
          # Druzhok.Ruoc logged "ruoc partner quota reached" for the operator.
          {:error, :ruoc_quota} -> Onboarding.ruoc_quota_message()
          {:error, reason} -> "Ошибка создания бота: #{inspect(reason)}\nПопробуй ещё раз."
        end

      # The result lands in the progress message first; the keyboard follows it.
      finish_progress(progress, token, creator_id, text)

      case result do
        {:ok, _name, _username} ->
          # A new bot is panel-ready only once its «Кабинет» button is set,
          # so text and keyboard both follow the same check.
          menu = menu_for(creator_id)

          API.send_message(token, creator_id, Onboarding.after_create_message(panel_ready_for?(creator_id)), %{
            reply_markup: Jason.encode!(menu)
          })

        _ ->
          :ok
      end
    end)

    update_in(state, [:sessions], &Map.delete(&1, creator_id))
  end

  # Provisioning takes tens of seconds (ruoc account, linux user, unit start),
  # so the creator gets one message right away that a ticker keeps editing
  # through the checklist; the result is edited into that same message.
  defp progress_tick_ms, do: Application.get_env(:druzhok, :provision_progress_tick_ms, 5_000)

  defp start_progress(token, chat_id, bot_username) do
    case API.send_message(token, chat_id, Onboarding.progress_message(bot_username, 0)) do
      {:ok, %{"message_id" => message_id}} ->
        ticker = spawn(fn -> progress_loop(token, chat_id, message_id, bot_username, 1) end)
        %{message_id: message_id, ticker: ticker}

      _ ->
        nil
    end
  end

  defp progress_loop(token, chat_id, message_id, bot_username, step) do
    receive do
      :stop -> :ok
    after
      progress_tick_ms() ->
        edit_plain(token, chat_id, message_id, Onboarding.progress_message(bot_username, step))
        progress_loop(token, chat_id, message_id, bot_username, step + 1)
    end
  end

  defp finish_progress(nil, token, chat_id, text), do: API.send_message(token, chat_id, text)

  defp finish_progress(%{message_id: message_id, ticker: ticker}, token, chat_id, text) do
    # Wait for the ticker to exit so no in-flight edit lands after the result.
    ref = Process.monitor(ticker)
    send(ticker, :stop)

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      10_000 -> Process.exit(ticker, :kill)
    end

    case edit_plain(token, chat_id, message_id, text) do
      {:ok, _} -> :ok
      _ -> API.send_message(token, chat_id, text)
    end
  end

  # --- Helpers ---

  defp user_bot_count(user_id) do
    import Ecto.Query
    Druzhok.Repo.aggregate(
      from(i in Druzhok.Instance, where: i.owner_telegram_id == ^user_id and not i.delete_requested),
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

  # Same, without Markdown: the invite links carry `start=ref_…`, and Markdown
  # would eat the underscore.
  defp send_url_keyboard_plain(token, chat_id, text, rows) do
    keyboard = build_url_keyboard(rows)
    API.send_message(token, chat_id, text, %{reply_markup: Jason.encode!(keyboard)})
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
