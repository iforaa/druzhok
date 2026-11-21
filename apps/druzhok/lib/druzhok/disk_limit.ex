defmodule Druzhok.DiskLimit do
  @moduledoc """
  A bot's disk limit (spec `docs/superpowers/specs/2026-11-21-bot-disk-limit-design.md`):
  an ext4 user quota on the bot's Linux user, set through `Druzhok.Host.quota/3`.

  The limit is the row's `disk_mb`, else Settings `bot_disk_mb`; the file cap
  grows with it (`bot_disk_files × disk_mb / bot_disk_mb`). With
  `bot_disk_mb=off` every bot's limit is `:off`, an override included.

  Also the wording of usage, shared by the owner's messages, the cabinet,
  `ops/druzhok` and the disk check.
  """

  require Logger
  alias Druzhok.{Host, Instance, Repo, Settings}

  @type limit :: :off | {disk_mb :: pos_integer(), files :: pos_integer()}

  @doc "The limit `inst` should have now (a nil row is a bot with no override)."
  @spec limit(%Instance{} | nil) :: limit
  def limit(inst) do
    limit(Settings.bot_disk_mb(), Settings.bot_disk_files(), inst && inst.disk_mb)
  end

  @doc false
  # Pure, for tests: the global size and file cap, and the row's override.
  def limit(:off, _files, _override), do: :off
  def limit(mb, files, nil), do: {mb, files}

  def limit(mb, files, override) when is_integer(override) and override > 0,
    do: {override, max(div(files * override, mb), 1)}

  def limit(mb, files, _bad), do: {mb, files}

  @doc """
  Sets `inst`'s limit on the host now. `:ok`, `:unknown` on a host without
  quotas support in druzhok (`Host.Process`), or `{:error, reason}`.
  """
  def apply(%Instance{name: name} = inst), do: set(name, limit(inst))

  @doc """
  The limit of the bot called `name`, its row read here; a bot with no row
  yet gets the default. `Host.Systemd.prepare/3` sets it on every start and wake.
  """
  def limit_by_name(name), do: limit(Repo.get_by(Instance, name: name))

  defp set(name, :off), do: Host.quota(name, :off, 0)
  defp set(name, {mb, files}), do: Host.quota(name, mb, files)

  # --- readings --------------------------------------------------------------

  @doc """
  How full a reading is, in percent: the higher of size and file count, over
  the limits that are set. nil when neither is (limit 0), so nothing divides.
  """
  def pct(%{} = r), do: r |> pcts() |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> nil end)

  # `[{:size | :files, pct}]` for each limit that is set.
  defp pcts(r) do
    for {kind, used, limit} <- [
          {:size, r[:used_kb], r[:limit_kb]},
          {:files, r[:files], r[:file_limit]}
        ],
        is_integer(used) and is_integer(limit) and limit > 0,
        do: {kind, used * 100 / limit}
  end

  @doc "`:size` or `:files`: which of the two is fuller (size on a tie); nil without a limit."
  def fuller(%{} = r) do
    case Enum.sort_by(pcts(r), &elem(&1, 1), :desc) do
      [] -> nil
      [{kind, _} | _] -> kind
    end
  end

  @doc "The row's last reading as the map `pct/1` takes."
  def reading(%Instance{} = inst) do
    %{
      used_kb: inst.disk_used_kb,
      limit_kb: inst.disk_limit_kb,
      files: inst.disk_files,
      file_limit: inst.disk_file_limit
    }
  end

  @doc """
  One line for the owner, from the row: whichever of size and file count is
  fuller, «245 МБ из 1 ГБ» or «85 000 файлов из 100 000». nil before the
  first check and for a bot without a limit.
  """
  def usage_line(%Instance{disk_checked_at: nil}), do: nil

  def usage_line(%Instance{} = inst) do
    r = reading(inst)

    case fuller(r) do
      :size -> "#{size(r.used_kb)} из #{size(r.limit_kb)}"
      :files -> "#{count(r.files)} #{files_word(r.files)} из #{count(r.file_limit)}"
      nil -> nil
    end
  end

  @doc "KB as «245 МБ» below a gigabyte, else «1 ГБ», «1,5 ГБ»."
  def size(kb) when is_integer(kb) and kb < 1024 * 1024, do: "#{div(kb + 512, 1024)} МБ"

  def size(kb) when is_integer(kb) do
    gb = Float.round(kb / (1024 * 1024), 1)

    text =
      if gb == Float.round(gb),
        do: Integer.to_string(trunc(gb)),
        else: gb |> Float.to_string() |> String.replace(".", ",")

    "#{text} ГБ"
  end

  @doc "«85 000», with a no-break space."
  def count(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1\u00A0")
    |> String.reverse()
  end

  @doc "файл / файла / файлов for `n`."
  def files_word(n) do
    case {rem(n, 10), rem(n, 100)} do
      {_, t} when t in 11..14 -> "файлов"
      {1, _} -> "файл"
      {u, _} when u in 2..4 -> "файла"
      _ -> "файлов"
    end
  end

  @doc """
  The row's reading for `ops/druzhok list`: «245 МБ/1 ГБ», «без лимита» for a
  bot with limit 0 while quotas are on, «-» when unknown.
  """
  def short(%Instance{disk_checked_at: nil}), do: "-"

  def short(%Instance{} = inst) do
    case pct(reading(inst)) do
      nil ->
        if Settings.disk_quota() == "on", do: "без лимита", else: "-"

      pct ->
        "#{size(inst.disk_used_kb || 0)}/#{size(inst.disk_limit_kb || 0)} #{trunc(pct)}%"
    end
  end
end
