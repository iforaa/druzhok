defmodule Druzhok.Panel.Settings do
  @moduledoc """
  What a bot's owner may change from the panel (panel controls spec,
  «Writable fields»), and the one way it is saved. The names are those of
  `GET /app/api/bot`'s `settings`, which are the `Instance` fields; nothing
  outside the allowlist reaches `Druzhok.BotSettings`.

  A save never restarts or wakes the bot: `BotSettings.update/3` with
  `restart: :when_quiet` leaves that to the lifecycle controller.
  """

  alias Druzhok.{BotSettings, Instance, Repo}

  @fields ~w(language timezone mention_only image_gen_enabled image_gen_model website_hosting_enabled)
  @languages ~w(ru en)
  @booleans ~w(mention_only image_gen_enabled website_hosting_enabled)

  def fields, do: @fields

  @doc """
  Validates `changes` (string keys, JSON values) against `inst` and saves
  them. Writes for one bot are serialized. `{:ok, instance}` or
  `{:error, status, type, message}`; one bad field refuses the whole request.
  """
  def save(%Instance{} = inst, changes) when is_map(changes) do
    :global.trans({{__MODULE__, inst.id}, self()}, fn ->
      latest = Repo.get(Instance, inst.id)

      with %Instance{} <- latest,
           {:ok, accepted} <- validate(latest, changes) do
        write(latest, accepted)
      else
        nil -> {:error, 404, "not_found", "this bot has no panel"}
        error -> error
      end
    end)
  end

  def save(_inst, _changes), do: invalid("changes must be an object")

  defp write(inst, accepted) when map_size(accepted) == 0, do: {:ok, inst}

  defp write(inst, accepted) do
    case BotSettings.update(inst.name, accepted, restart: :when_quiet) do
      {:ok, updated, _pending} -> {:ok, updated}
      {:error, _} -> {:error, 500, "save_failed", "could not save the settings"}
    end
  end

  @doc """
  The accepted changes as `%{atom => value}`, values already equal to the
  row's dropped, or `{:error, status, type, message}`.
  """
  def validate(%Instance{} = inst, changes) when is_map(changes) do
    with :ok <- known(changes),
         {:ok, typed} <- typed(changes),
         :ok <- images_on(inst, typed),
         :ok <- image_model(typed) do
      {:ok, typed |> Enum.reject(fn {k, v} -> Map.get(inst, k) == v end) |> Map.new()}
    end
  end

  def validate(_inst, _changes), do: invalid("changes must be an object")

  defp known(changes) do
    case Enum.find(Map.keys(changes), &(&1 not in @fields)) do
      nil -> :ok
      key -> {:error, 400, "unknown_setting", "#{inspect(key)} cannot be changed here"}
    end
  end

  defp typed(changes) do
    Enum.reduce_while(changes, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case value(key, value) do
        {:ok, v} -> {:cont, {:ok, Map.put(acc, String.to_existing_atom(key), v)}}
        :error -> {:halt, invalid("#{key}: #{inspect(value)} is not allowed")}
      end
    end)
  end

  defp value("language", v) when v in @languages, do: {:ok, v}
  defp value("timezone", v) when is_binary(v), do: timezone(String.trim(v))
  defp value(key, v) when key in @booleans and is_boolean(v), do: {:ok, v}
  defp value("image_gen_model", nil), do: {:ok, nil}

  defp value("image_gen_model", v) when is_binary(v) and byte_size(v) in 1..200,
    do: {:ok, String.trim(v)}

  defp value(_key, _v), do: :error

  # Any IANA name the time zone database knows; hermes reads it from TZ.
  defp timezone("UTC"), do: {:ok, "UTC"}

  defp timezone(tz) when byte_size(tz) in 1..64 do
    if Regex.match?(~r"^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+){0,2}$", tz) and
         match?({:ok, _}, DateTime.now(tz)),
       do: {:ok, tz},
       else: :error
  end

  defp timezone(_), do: :error

  # A picture model is accepted only while pictures are on after this
  # request's own changes.
  defp images_on(inst, %{image_gen_model: _} = typed) do
    if Map.get(typed, :image_gen_enabled, inst.image_gen_enabled) == true,
      do: :ok,
      else: {:error, 400, "images_off", "turn pictures on before choosing a model"}
  end

  defp images_on(_inst, _typed), do: :ok

  defp image_model(%{image_gen_model: id}) when is_binary(id) do
    case Druzhok.Ruoc.image_models() do
      {:ok, models} ->
        if Enum.any?(models, &(&1.id == id)), do: :ok, else: invalid("unknown picture model")

      {:error, _} ->
        {:error, 502, "catalogue_unavailable", "could not load the picture models"}
    end
  end

  defp image_model(_typed), do: :ok

  defp invalid(message), do: {:error, 400, "invalid_setting", message}

  @doc """
  What happens to saved settings next, for `GET /app/api/bot`: `applied`,
  `waiting` (awake, a quiet restart is due), `on_wake`, `on_start`, or
  `failed` (a start after the save failed; an older failure does not count).
  """
  def apply_state(%Instance{} = inst) do
    pending? = (inst.settings_seq || 0) > (inst.settings_applied_seq || 0)

    cond do
      not pending? -> "applied"
      failed_after_save?(inst) -> "failed"
      not inst.active -> "on_start"
      inst.sleeping -> "on_wake"
      true -> "waiting"
    end
  end

  defp failed_after_save?(%{
         start_failed_at: %DateTime{} = failed,
         settings_saved_at: %DateTime{} = saved
       }),
       do: DateTime.compare(failed, saved) == :gt

  defp failed_after_save?(_), do: false
end
