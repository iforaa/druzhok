defmodule Druzhok.Cabinet do
  @moduledoc """
  The bot cabinet's druzhok side: ruoc serves a Telegram Mini App where a
  bot's owner sees the bot's account and pays for it (ruoc-gateway
  docs/superpowers/specs/2026-10-24-telegram-mini-app-design.md). Druzhok
  tells ruoc which bot and owner each account is for, puts the cabinet on the
  owner's menu button, and offers it when ruoc refuses a request for an empty
  balance.

  One process does every outward call, so no bot's controller ever waits on
  ruoc or Telegram for it: `sync/1` and `out_of_money/1` are casts, which
  cannot block or raise in the caller, and a crash here restarts only this
  process. It runs where druzhok.service serves (DruzhokWeb.Application);
  elsewhere a cast finds nobody and is dropped, and `ops/druzhok
  bind-cabinet` calls `bind_now/1` itself.

  `instances.cabinet_binding` (`"<bot_id>:<owner_tg_id>"`) and `cabinet_url`
  are written when ruoc accepts a binding, `cabinet_menu_set` when Telegram
  takes the menu button. A matching binding with the button set costs nothing,
  so a wake from sleep makes no call. The button usually fails at first: a new
  bot is started before its owner has pressed Start, and Telegram answers 400.
  It is tried again on every start, on the owner's first private message
  (the webhook controller calls `sync/1`) and with every out-of-money notice.
  """

  use GenServer
  require Logger
  import Ecto.Query
  alias Druzhok.{Instance, Repo, Ruoc}
  alias Druzhok.Telegram.API

  # At most one out-of-money message per bot in this long: a run of refused
  # requests is one message.
  @notice_every_ms 6 * 60 * 60 * 1000

  @button %{"ru" => "Кабинет", "en" => "Cabinet"}
  @notice %{
    "ru" => {"💳 Баланс бота исчерпан. Пополнить его можно в кабинете.", "Открыть кабинет"},
    "en" =>
      {"💳 The bot's balance is used up. You can top it up in the cabinet.", "Open the cabinet"}
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Binds the bot and sets the owner's button when anything changed. A cast."
  def sync(instance_id), do: GenServer.cast(__MODULE__, {:sync, instance_id})

  @doc "ruoc refused a request for an empty balance: tell the owner, at most every 6 h. A cast."
  def out_of_money(instance_id), do: GenServer.cast(__MODULE__, {:out_of_money, instance_id})

  @doc """
  Whether a webhook update is the moment to retry the owner's menu button:
  the button is not set yet and the update is the owner writing to the bot
  privately, so Telegram will now accept it.
  """
  def button_moment?(%Instance{cabinet_menu_set: false, owner_telegram_id: owner}, %{
        "message" => %{"from" => %{"id" => owner}, "chat" => %{"type" => "private"}}
      })
      when is_integer(owner),
      do: true

  def button_moment?(_instance, _update), do: false

  @impl true
  def init(_opts), do: {:ok, %{noticed: %{}}}

  @impl true
  def handle_cast({:sync, id}, state) do
    guarded(id, fn -> with %Instance{} = inst <- Repo.get(Instance, id), do: bind_now(inst) end)
    {:noreply, state}
  end

  def handle_cast({:out_of_money, id}, state) do
    now = System.monotonic_time(:millisecond)

    case state.noticed do
      %{^id => at} when now - at < @notice_every_ms ->
        {:noreply, state}

      _ ->
        sent = guarded(id, fn -> notify(id) end)
        noticed = if sent == :sent, do: Map.put(state.noticed, id, now), else: state.noticed
        {:noreply, %{state | noticed: noticed}}
    end
  end

  # Nothing here may take the process down with it: a raise or an exit from
  # ruoc, Telegram or the database is logged and the next trigger tries again.
  defp guarded(id, fun) do
    fun.()
  rescue
    e ->
      Logger.error("[cabinet] #{id}: #{Exception.message(e)}")
      :error
  catch
    :exit, reason ->
      Logger.error("[cabinet] #{id}: exit #{inspect(reason)}")
      :error
  end

  @doc """
  Brings one bot's cabinet up to date, synchronously: binds it at ruoc when
  the bot or owner changed (or was never bound), then sets the owner's menu
  button when it is not set. Returns `{:ok, :unchanged | :bound | :button}`
  or `{:error, reason}`; `:not_eligible` for a bot with no ruoc account, owner
  or token.
  """
  def bind_now(%Instance{} = inst) do
    bot = Instance.telegram_bot_id(inst)

    cond do
      is_nil(inst.ruoc_account_id) or is_nil(inst.owner_telegram_id) or is_nil(bot) ->
        {:error, :not_eligible}

      true ->
        binding = "#{bot}:#{inst.owner_telegram_id}"

        cond do
          binding == inst.cabinet_binding and inst.cabinet_menu_set and
              is_binary(inst.cabinet_url) ->
            {:ok, :unchanged}

          binding == inst.cabinet_binding and is_binary(inst.cabinet_url) ->
            with :ok <- set_button(inst, inst.cabinet_url), do: {:ok, :button}

          true ->
            with {:ok, url} <- bind(inst, bot, binding),
                 :ok <- set_button(%{inst | cabinet_url: url}, url) do
              {:ok, :bound}
            end
        end
    end
  end

  defp bind(inst, bot, binding) do
    case Ruoc.bind_telegram(inst.ruoc_account_id, bot, inst.owner_telegram_id) do
      {:ok, url} ->
        # Written before the button: a bound bot always has its address, so
        # the out-of-money notice can offer it while the button is not set.
        set(inst.id, cabinet_binding: binding, cabinet_url: url, cabinet_menu_set: false)
        Logger.info("[cabinet] #{inst.name}: bound bot #{bot}")
        {:ok, url}

      {:error, reason} ->
        Logger.warning("[cabinet] #{inst.name}: ruoc did not bind: #{reason}")
        {:error, reason}
    end
  end

  defp set_button(inst, url) do
    button = %{type: "web_app", text: text(@button, inst), web_app: %{url: url}}

    case API.set_chat_menu_button(inst.telegram_token, inst.owner_telegram_id, button) do
      {:ok, _} ->
        set(inst.id, cabinet_menu_set: true)
        :ok

      {:error, reason} ->
        Logger.info(
          "[cabinet] #{inst.name}: menu button not set (#{short(reason)}); retried later"
        )

        {:error, :menu_button}
    end
  end

  @doc "Puts the owner's menu button back to Telegram's default and forgets the cabinet's state."
  def unset_now(%Instance{} = inst) do
    if inst.telegram_token && inst.owner_telegram_id do
      case API.set_chat_menu_button(inst.telegram_token, inst.owner_telegram_id, %{
             type: "default"
           }) do
        {:ok, _} ->
          set(inst.id, cabinet_binding: nil, cabinet_url: nil, cabinet_menu_set: false)
          {:ok, :unset}

        {:error, reason} ->
          {:error, short(reason)}
      end
    else
      {:error, :not_eligible}
    end
  end

  defp notify(id) do
    with %Instance{cabinet_url: url} = inst when is_binary(url) <- Repo.get(Instance, id) do
      {line, label} = text(@notice, inst)
      markup = %{inline_keyboard: [[%{text: label, web_app: %{url: url}}]]}

      result =
        case API.send_message(inst.telegram_token, inst.owner_telegram_id, line, %{
               reply_markup: markup
             }) do
          {:ok, _} ->
            Logger.info("[cabinet] #{inst.name}: out-of-money notice sent")
            :sent

          {:error, reason} ->
            Logger.warning(
              "[cabinet] #{inst.name}: out-of-money notice not sent (#{short(reason)})"
            )

            :error
        end

      # The owner has just been written to, so the button may take now.
      unless inst.cabinet_menu_set, do: set_button(inst, url)
      result
    else
      _ -> :skipped
    end
  end

  defp set(id, fields), do: Repo.update_all(from(i in Instance, where: i.id == ^id), set: fields)

  defp text(map, %Instance{language: lang}), do: Map.get(map, lang, map["en"])

  defp short(reason) when is_binary(reason), do: String.slice(reason, 0, 160)
  defp short(%{"description" => d}), do: d
  defp short(reason), do: inspect(reason) |> String.slice(0, 160)
end
