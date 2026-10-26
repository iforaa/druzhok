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

  `instances.cabinet_binding` (`"<bot_id>:<owner_tg_id>:<language>"`) and
  `cabinet_url` are written when ruoc accepts a binding; `cabinet_url` and
  `cabinet_menu_set` together whenever Telegram takes the menu button; and `cabinet_off` by `ops/druzhok
  bind-cabinet --off`, which nothing undoes but a plain `bind-cabinet`. A matching binding with the button set costs nothing,
  so a wake from sleep makes no call. The button usually fails at first: a new
  bot is started before its owner has pressed Start, and Telegram answers 400.
  It is tried again on every start, on the owner's first private message
  (the webhook controller calls `sync/1`) and with every out-of-money notice.

  With a public host the button opens druzhok's bot panel (`Druzhok.Panel.url/2`,
  spec `docs/superpowers/specs/2026-10-24-bot-panel-design.md`) instead of
  ruoc's page; a bot still on another address counts as "button not set", so
  the same triggers move it, with no ruoc call.
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
    "ru" =>
      {"Лимит тарифа на сейчас исчерпан. Когда он обновится и как сменить тариф — в кабинете.",
       "Открыть кабинет"},
    "en" =>
      {"The plan's limit is used up for now. When it resets and how to change plans — in the cabinet.",
       "Open the cabinet"}
  }

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Binds the bot and sets the owner's button when anything changed. A cast."
  def sync(instance_id), do: GenServer.cast(__MODULE__, {:sync, instance_id})

  @doc "ruoc refused a request for an empty balance: tell the owner, at most every 6 h. A cast."
  def out_of_money(instance_id), do: GenServer.cast(__MODULE__, {:out_of_money, instance_id})

  @doc """
  Whether a webhook update is the moment to retry the owner's cabinet: the
  update is the owner writing to the bot privately, so Telegram will now take
  the button, and the button is not set or the binding is not current (a
  rebind that failed after an owner change). Never while the cabinet is off.
  """
  def button_moment?(%Instance{cabinet_off: false, owner_telegram_id: owner} = inst, %{
        "message" => %{"from" => %{"id" => owner}, "chat" => %{"type" => "private"}}
      })
      when is_integer(owner),
      do:
        not inst.cabinet_menu_set or inst.cabinet_binding != fingerprint(inst) or
          stale_url?(inst)

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
  the bot, owner or language changed (or it was never bound), then sets the
  owner's menu button when it is not set. Returns
  `{:ok, :unchanged | :bound | :button | :off}` or `{:error, reason}`:
  `:not_eligible` for a bot with no ruoc account, owner or token;
  `{:menu_button, :not_opened}` when Telegram refuses the button because the
  owner has not opened the bot yet (expected, retried later);
  `{:menu_button, reason}` for any other refusal.
  """
  def bind_now(%Instance{cabinet_off: true}), do: {:ok, :off}

  def bind_now(%Instance{} = inst) do
    case fingerprint(inst) do
      nil ->
        {:error, :not_eligible}

      binding ->
        cond do
          binding == inst.cabinet_binding and inst.cabinet_menu_set and
            is_binary(inst.cabinet_url) and not stale_url?(inst) ->
            {:ok, :unchanged}

          binding == inst.cabinet_binding and is_binary(inst.cabinet_url) ->
            # The binding is current; the button or its address is not. No ruoc
            # call: the button moves to the panel, and cabinet_url follows only
            # once Telegram took it.
            with :ok <- set_button(inst, button_url(inst, inst.cabinet_url)), do: {:ok, :button}

          true ->
            with {:ok, url} <- bind(inst, binding) do
              release_old_owner(inst)
              with :ok <- set_button(%{inst | cabinet_url: url}, url), do: {:ok, :bound}
            end
        end
    end
  end

  # The button opens druzhok's bot panel (bot panel spec) when druzhok has a
  # public host; without one (dev, test) it keeps ruoc's address.
  defp button_url(inst, fallback), do: Druzhok.Panel.url(inst) || fallback

  # A button still on another address than the panel's: moved on the next
  # start, wake, owner message or bind-cabinet.
  defp stale_url?(inst) do
    case Druzhok.Panel.url(inst) do
      nil -> false
      url -> inst.cabinet_url != url
    end
  end

  # "<bot_id>:<owner>:<language>": what the binding and the button were made
  # for. The language is in it so a ru→en change relabels the button.
  defp fingerprint(inst) do
    bot = Instance.telegram_bot_id(inst)

    if is_nil(inst.ruoc_account_id) or is_nil(inst.owner_telegram_id) or is_nil(bot),
      do: nil,
      else: "#{bot}:#{inst.owner_telegram_id}:#{inst.language}"
  end

  defp bind(inst, binding) do
    bot = Instance.telegram_bot_id(inst)

    case Ruoc.bind_telegram(inst.ruoc_account_id, bot, inst.owner_telegram_id) do
      {:ok, ruoc_url} ->
        # ruoc's reply proves the binding; the address is druzhok's panel
        # when there is one. Written before the button: a bound bot always
        # has its address, so the out-of-money notice can offer it while the
        # button is not set.
        url = button_url(inst, ruoc_url)
        set(inst.id, cabinet_binding: binding, cabinet_url: url, cabinet_menu_set: false)
        Logger.info("[cabinet] #{inst.name}: bound bot #{bot}")
        {:ok, url}

      {:error, reason} ->
        # The old binding stays as it was, so the next trigger tries again.
        Logger.warning("[cabinet] #{inst.name}: ruoc did not bind: #{reason}")
        {:error, reason}
    end
  end

  # A new owner takes the button over: the previous owner's chat goes back to
  # the default, best effort, so only the owner holds a «Кабинет».
  defp release_old_owner(inst) do
    with binding when is_binary(binding) <- inst.cabinet_binding,
         [_bot, old | _] <- String.split(binding, ":"),
         {old, ""} <- Integer.parse(old),
         true <- old != inst.owner_telegram_id do
      case API.set_chat_menu_button(inst.telegram_token, old, %{type: "default"}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.info("[cabinet] #{inst.name}: old owner's button kept (#{short(reason)})")
      end
    end
  end

  defp set_button(inst, url) do
    button = %{type: "web_app", text: text(@button, inst), web_app: %{url: url}}

    case API.set_chat_menu_button(inst.telegram_token, inst.owner_telegram_id, button) do
      {:ok, _} ->
        # The address is written with the button, in one update, only once
        # Telegram took it: a refused button leaves the old address, so the
        # next trigger tries again.
        set(inst.id, cabinet_url: url, cabinet_menu_set: true)
        :ok

      {:error, reason} ->
        if not_opened?(reason) do
          Logger.info(
            "[cabinet] #{inst.name}: owner has not opened the bot yet; button retried later"
          )

          {:error, {:menu_button, :not_opened}}
        else
          Logger.warning("[cabinet] #{inst.name}: menu button not set (#{short(reason)})")
          {:error, {:menu_button, short(reason)}}
        end
    end
  end

  # Telegram's answer for a chat the bot has never had: the owner has not
  # pressed Start yet.
  defp not_opened?(reason), do: short(reason) =~ ~r/chat not found/i

  @doc """
  Turns the cabinet off for one bot: the owner's menu button back to
  Telegram's default, and `cabinet_off` set so no start, wake or message puts
  it back. A plain `bind-cabinet` (`resume_now/1`) turns it on again.
  """
  def unset_now(%Instance{} = inst) do
    reply =
      if inst.telegram_token && inst.owner_telegram_id,
        do:
          API.set_chat_menu_button(inst.telegram_token, inst.owner_telegram_id, %{type: "default"}),
        else: {:ok, :no_chat}

    case reply do
      {:ok, _} ->
        off(inst)

      {:error, reason} ->
        # A chat that never existed has no button to take back.
        if not_opened?(reason), do: off(inst), else: {:error, short(reason)}
    end
  end

  defp off(inst) do
    set(inst.id,
      cabinet_off: true,
      cabinet_binding: nil,
      cabinet_url: nil,
      cabinet_menu_set: false
    )

    {:ok, :unset}
  end

  @doc "Turns the cabinet back on for a bot `unset_now/1` turned off, and binds it."
  def resume_now(%Instance{cabinet_off: true} = inst) do
    set(inst.id, cabinet_off: false)
    bind_now(%{inst | cabinet_off: false})
  end

  def resume_now(%Instance{} = inst), do: bind_now(inst)

  defp notify(id) do
    with %Instance{cabinet_url: url, cabinet_off: false} = inst when is_binary(url) <-
           Repo.get(Instance, id) do
      {line, label} = text(@notice, inst)
      url = Druzhok.Panel.url(inst, tab: "billing") || url
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

      # The owner has just been written to, so the button may take now; and
      # a binding left stale by a failed rebind gets another try.
      bind_now(inst)
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
