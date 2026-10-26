defmodule Druzhok.Runtime.Hermes.Locale do
  @moduledoc """
  Druzhok's wording for the replies hermes builds itself (no model involved):
  the command menu, /new, /help, denied commands, failures, timeouts
  (spec 2026-10-26-tenant-chat-surface-design.md).

  Hermes merges `<HERMES_HOME>/locales/<lang>.yaml` over its bundled catalog,
  key by key, once per process (agent/i18n_layers.py). Druzhok writes that
  overlay for ru and en on every start and wake; the files are druzhok-owned
  and rewritten whole. Sources: `priv/hermes_locale/<lang>.json`, flat
  `{"dotted.key": "text"}`; `priv/hermes_locale/reviewed.txt` lists every other
  key under the audited roots, with the reason it is left alone.

  A broken overlay is logged and ignored by hermes, so every value is written
  as a JSON string (a valid YAML double-quoted scalar) and nothing is spliced
  in raw. `%{bot_name}` is the only substitution; braces in the name become
  parentheses, because hermes runs `str.format` on some of these texts.
  """

  require Logger
  alias Druzhok.TenantFiles

  @langs ~w(ru en)
  @marker "# druzhok-owned: rewritten on every start (Druzhok.Runtime.Hermes.Locale)"
  @limit 262_144

  @sources Map.new(@langs, fn lang ->
             path = Path.join([:code.priv_dir(:druzhok), "hermes_locale", lang <> ".json"])
             @external_resource path
             {lang, path |> File.read!() |> Jason.decode!()}
           end)

  @doc "The overrides for `lang` as `%{key => text}`, before the name is put in."
  def overrides(lang) when lang in @langs, do: Map.fetch!(@sources, lang)

  def languages, do: @langs

  @doc "The overlay file for `lang` and the bot's display name."
  def render(lang, name) do
    name = safe_name(name)

    body =
      lang
      |> overrides()
      |> Enum.sort()
      |> Enum.map(fn {key, text} ->
        Jason.encode!(key) <> ": " <> Jason.encode!(String.replace(text, "%{bot_name}", name))
      end)

    Enum.join([@marker | body], "\n") <> "\n"
  end

  @doc """
  Writes the ru and en overlays when their content changed. Never raises: a
  file that cannot be written (a symlink, a foreign owner) is logged and the
  bot keeps hermes's own texts for that language.
  """
  def sync(instance, data_root) do
    name = Map.get(instance, :display_name)

    for lang <- @langs do
      content = render(lang, name)
      segments = ["locales", lang <> ".yaml"]

      case TenantFiles.read_text(data_root, segments, @limit) do
        {:ok, %{text: ^content}} ->
          :ok

        _ ->
          case TenantFiles.write(data_root, segments, content) do
            :ok ->
              :ok

            other ->
              Logger.warning("[locale] #{data_root}: #{lang}.yaml not written: #{inspect(other)}")
          end
      end
    end

    :ok
  end

  @doc """
  Removes the overlays druzhok wrote (first line is the marker); anything else
  under `locales/` is left alone. For a rollback.
  """
  def remove(data_root) do
    for lang <- @langs do
      segments = ["locales", lang <> ".yaml"]

      with {:ok, %{text: text}} <- TenantFiles.read_text(data_root, segments, @limit),
           true <- String.starts_with?(text, @marker <> "\n") do
        TenantFiles.delete(data_root, segments)
      else
        _ -> :kept
      end
    end

    :ok
  end

  defp safe_name(name) when is_binary(name) do
    case String.trim(name) do
      "" ->
        "Дружок"

      trimmed ->
        String.replace(trimmed, ["{", "}"], fn
          "{" -> "("
          "}" -> ")"
        end)
    end
  end

  defp safe_name(_), do: "Дружок"
end
