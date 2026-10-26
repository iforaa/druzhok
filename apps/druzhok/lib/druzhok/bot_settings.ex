defmodule Druzhok.BotSettings do
  @moduledoc """
  A bot's operator settings, and which of them need a restart to reach hermes
  (dashboard removal spec, step 2). `Druzhok.CLI` goes through here.

  A field that `Runtime.Hermes` reads at start (env, `config.yaml`) restarts
  the bot when it changes, but only a running bot: a restart is a start
  request, and a stopped bot stays stopped. Fields read per request or by
  druzhok itself apply at once.
  """

  alias Druzhok.{BotManager, I18n, Instance, Repo, Telegram}
  alias Druzhok.Runtime.Hermes

  @restart ~w(model image_model language telegram_token mention_only group_shared_memory
              website_hosting_enabled image_gen_enabled memory_provider trigger_name
              allowed_telegram_chats owner_telegram_id timezone)a

  # Read per request (image_gen_model by the proxy), by the lifecycle
  # controller (sleep_enabled) or by druzhok (welcome_message).
  @live ~w(sleep_enabled image_gen_model welcome_message)a

  @secret ~w(telegram_token tenant_key ruoc_api_key telegram_webhook_secret)a

  @doc "The fields `update/2` takes."
  def fields, do: @restart ++ @live

  @doc """
  The bot's settings and state as `[{field, value}]`, secrets masked.
  `{:error, :not_found}` for an unknown bot.
  """
  def show(name) do
    with {:ok, inst} <- fetch(name) do
      state = [
        active: inst.active,
        sleeping: inst.sleeping,
        status: Druzhok.Lifecycle.shown_status(inst, BotManager.status(name)),
        telegram_mode: inst.telegram_mode,
        ruoc_account_id: inst.ruoc_account_id,
        started_at: inst.started_at,
        start_error: inst.start_error
      ]

      settings =
        for f <- fields(),
            do: {f, if(f in @secret, do: mask(Map.get(inst, f)), else: Map.get(inst, f))}

      {:ok, state ++ settings}
    end
  end

  @doc """
  Change settings. `attrs` maps fields (atoms or strings) to typed values or
  to strings parsed by the field's type (`"true"`, `"42"`, `""` for nil).
  Returns `{:ok, instance, restarted?}`; the restart itself is carried out by
  the lifecycle controller.

  `restart: :when_quiet` (the bot panel) never asks for a restart and never
  wakes a sleeping bot: a changed restart field bumps `settings_seq` in the
  same write, and the controller applies it at the next start or the next
  quiet moment (panel controls spec, «Applying a change»). `restarted?` is
  then whether a restart is pending.
  """
  def update(name, attrs, opts \\ []) do
    with {:ok, inst} <- fetch(name),
         {:ok, changes} <- cast(attrs),
         :ok <- validate(changes) do
      restart_field? =
        Enum.any?(changes, fn {k, v} -> k in @restart and Map.get(inst, k) != v end)

      case opts[:restart] do
        :when_quiet -> update_when_quiet(inst, changes, restart_field?)
        _ -> update_now(inst, changes, inst.active and restart_field?)
      end
    end
  end

  defp update_now(inst, changes, restart?) do
    with {:ok, updated} <- inst |> Instance.changeset(changes) |> Repo.update() do
      if restart?, do: BotManager.restart(inst.name)
      {:ok, updated, restart?}
    end
  end

  defp update_when_quiet(inst, changes, restart_field?) do
    changeset = Instance.changeset(inst, changes)

    changeset =
      if restart_field?,
        do:
          Ecto.Changeset.change(changeset,
            settings_seq: (inst.settings_seq || 0) + 1,
            settings_saved_at: DateTime.utc_now()
          ),
        else: changeset

    with {:ok, updated} <- Repo.update(changeset), do: {:ok, updated, restart_field?}
  end

  defp cast(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
      with {:ok, field} <- field(k),
           {:ok, value} <- parse(field, v) do
        {:cont, {:ok, Map.put(acc, field, value)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp field(k) when is_atom(k),
    do: if(k in fields(), do: {:ok, k}, else: {:error, {:unknown_field, k}})

  defp field(k) when is_binary(k) do
    case Enum.find(fields(), &(Atom.to_string(&1) == k)) do
      nil -> {:error, {:unknown_field, k}}
      f -> {:ok, f}
    end
  end

  defp parse(field, v) when is_binary(v) do
    case {Instance.__schema__(:type, field), String.trim(v)} do
      {_, ""} -> {:ok, nil}
      {:boolean, b} when b in ~w(true on yes 1) -> {:ok, true}
      {:boolean, b} when b in ~w(false off no 0) -> {:ok, false}
      {:boolean, _} -> {:error, {:not_boolean, field, v}}
      {:integer, s} -> parse_integer(field, s)
      {_, s} -> {:ok, s}
    end
  end

  defp parse(_field, v), do: {:ok, v}

  defp parse_integer(field, s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:not_integer, field, s}}
    end
  end

  defp validate(%{memory_provider: p}) when is_binary(p) do
    if p in Instance.memory_providers(), do: :ok, else: {:error, {:unknown_memory_provider, p}}
  end

  defp validate(_), do: :ok

  # --- users -----------------------------------------------------------------

  @doc "Telegram ids allowed to DM the bot: the DB allowlist plus hermes's pairing file."
  def allowed_users(name) do
    with {:ok, inst} <- fetch(name) do
      file =
        Hermes.read_allowed_users(Hermes.data_root(inst)) |> Enum.reject(&(&1 == "__closed__"))

      {:ok, (Instance.get_allowed_ids(inst) ++ file) |> Enum.uniq() |> Enum.sort()}
    end
  end

  @doc "Allow a Telegram id to DM the bot; restarts a running bot."
  def allow_user(name, input), do: mutate_allowlist(name, String.trim(input), :add)

  def remove_user(name, user_id), do: mutate_allowlist(name, to_string(user_id), :remove)

  defp mutate_allowlist(_name, "", _op), do: {:error, :no_user_id}

  defp mutate_allowlist(name, user_id, op) do
    with {:ok, inst} <- fetch(name) do
      case op do
        :add -> Instance.add_allowed_id(inst, user_id)
        :remove -> Instance.remove_allowed_id(inst, user_id)
      end

      if inst.active, do: BotManager.restart(name)
      :ok
    end
  end

  @doc "Allow a Telegram id (as `allow_user/2`) and send it the bot's welcome message."
  def allow_and_welcome(name, user_id) do
    user_id = to_string(user_id)

    with :ok <- allow_user(name, user_id),
         {:ok, inst} <- fetch(name) do
      welcome = inst.welcome_message || I18n.t(:welcome_default, inst.language || "ru")
      if inst.telegram_token, do: Telegram.API.send_message(inst.telegram_token, user_id, welcome)
      :ok
    end
  end

  @doc """
  Approve a hermes pairing code (`hermes pairing approve telegram <code>`).
  `{:ok, output}` or `{:error, output}`: hermes exits 0 even when the code is
  unknown, so the text is read.
  """
  def approve_code(name, code) do
    {output, exit_code} =
      BotManager.exec(name, [Hermes.bin(), "pairing", "approve", "telegram", code])

    output = String.trim(output)

    failed =
      output
      |> String.downcase()
      |> String.contains?(["not found", "expired", "invalid", "error", "failed"])

    if exit_code == 0 and not failed, do: {:ok, output}, else: {:error, output}
  end

  @doc "Drop the bot's chat sessions (memory stays) and restart it."
  def clear_history(name) do
    with {:ok, inst} <- fetch(name) do
      Hermes.clear_sessions(Hermes.data_root(inst))
      if inst.active, do: BotManager.restart(name)
      :ok
    end
  end

  defp fetch(name) do
    case Repo.get_by(Instance, name: name) do
      nil -> {:error, :not_found}
      inst -> {:ok, inst}
    end
  end

  @doc "`****` plus the last 4 characters, or nil."
  def mask(nil), do: nil
  def mask(""), do: nil
  def mask(v) when is_binary(v) and byte_size(v) <= 8, do: "****"
  def mask(v) when is_binary(v), do: "****" <> String.slice(v, -4, 4)
end
