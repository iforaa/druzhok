defmodule Druzhok.TenantFiles do
  @moduledoc """
  Reading a file a bot owns, safely, for `DruzhokWebWeb.Plugs.BotSite` and the
  bot panel.

  The bot owns everything below its tenant dir and druzhok reads with
  CAP_DAC_READ_SEARCH: a symlink followed here hands out any file on the host.
  So no component below the tenant dir may be a symlink, and the bytes come
  from a descriptor we verified rather than from a second lookup by name,
  which the bot could swap in between.

  The walk alone cannot stop a bot that swaps an *intermediate* directory for
  a symlink between druzhok's lookups (each lookup re-resolves the whole
  path), so the opened file must also belong to the tenant: its owner is the
  tenant dir's owner, the bot's own uid. Another tenant's files have another
  owner, host files belong to root, so a swap reaches nothing the bot could
  not read itself.

  Directory *listings* are not done here: an in-process walk re-resolves the
  path at every step, so `Druzhok.Panel.Lister` lists as the bot's own user.

  Writing (`write/4`, druzhok's own files in the tenant dir: config.yaml,
  AGENTS.md) has the same problem the other way round: druzhok writes with
  CAP_DAC_OVERRIDE, so a write that follows a symlink lands anywhere on the
  host. Writes never open, chmod or chown anything by name inside the bot's
  dir: the file is prepared in a staging dir next to the tenant dirs, which no
  bot can write, and then renamed over the target (rename(2) replaces a link
  instead of following it) or, for a seed, hard-linked into place.
  """

  @doc """
  Opens `segments` below `tenant_dir`. `index: true` serves a directory as its
  `index.html` (BotSite). `{:ok, fd, path, %File.Stat{}}` or `:not_found`; the
  caller closes `fd`. The stat is the open descriptor's. `uid:` overrides the
  owner the file must have (default: the tenant dir's owner).
  """
  def open(tenant_dir, segments, opts \\ []) do
    index? = Keyword.get(opts, :index, false)

    with {:ok, uid} <- owner(tenant_dir, opts),
         {:ok, file, _stat} <- walk(tenant_dir, segments, index?),
         {:ok, fd} <- :file.open(file, [:read, :binary, :raw]) do
      # Re-walk now that the file is open: the descriptor is only trusted if
      # the symlink-free path still leads to the very inode it refers to.
      with {:ok, info} <- :file.read_file_info(fd, time: :posix),
           opened = File.Stat.from_record(info),
           {:ok, ^file, %File.Stat{inode: inode, major_device: dev}} <-
             walk(tenant_dir, segments, index?),
           true <-
             opened.type == :regular and opened.inode == inode and opened.major_device == dev,
           true <- opened.uid == uid do
        {:ok, fd, file, opened}
      else
        _ ->
          :file.close(fd)
          :not_found
      end
    else
      _ -> :not_found
    end
  end

  defp owner(tenant_dir, opts) do
    case Keyword.fetch(opts, :uid) do
      {:ok, uid} ->
        {:ok, uid}

      :error ->
        case File.lstat(tenant_dir) do
          {:ok, %File.Stat{type: :directory, uid: uid}} -> {:ok, uid}
          _ -> :not_found
        end
    end
  end

  @doc """
  Reads at most `limit` bytes of a file through `open/3`:
  `{:ok, %{bytes: binary, size: n, modified_at: DateTime, truncated: bool}}`
  or `:not_found`. Reads `limit + 4` so a cut can be told from an exact fit.
  """
  def read(tenant_dir, segments, limit, opts \\ []) do
    with {:ok, fd, _file, stat} <- open(tenant_dir, segments, opts) do
      try do
        bytes =
          case :file.read(fd, limit + 4) do
            {:ok, data} -> data
            :eof -> ""
            {:error, _} -> nil
          end

        if is_nil(bytes) do
          :not_found
        else
          truncated = byte_size(bytes) > limit
          bytes = if truncated, do: binary_part(bytes, 0, limit), else: bytes

          {:ok,
           %{
             bytes: bytes,
             size: stat.size,
             modified_at: DateTime.from_unix!(stat.mtime),
             truncated: truncated
           }}
        end
      after
        :file.close(fd)
      end
    end
  end

  @doc """
  `read/3` for text: a cut is trimmed back to a whole UTF-8 character, then
  the text must be valid UTF-8. `{:ok, %{text: …, …}}`, `:not_found` or
  `:not_text`.
  """
  def read_text(tenant_dir, segments, limit, opts \\ []) do
    with {:ok, %{bytes: bytes, truncated: truncated} = r} <-
           read(tenant_dir, segments, limit, opts) do
      text = if truncated, do: trim_utf8(bytes), else: bytes

      if String.valid?(text),
        do: {:ok, r |> Map.delete(:bytes) |> Map.put(:text, text)},
        else: :not_text
    end
  end

  @doc """
  Drops an incomplete UTF-8 sequence at the end of `bin`: any trailing
  continuation bytes and the lead byte that begins them, at most 3 bytes.
  A complete trailing character is kept.
  """
  def trim_utf8(bin) do
    size = byte_size(bin)
    tail = for i <- 1..min(3, size)//1, do: :binary.at(bin, size - i)
    # Count trailing continuation bytes (10xxxxxx), then look at the byte before them.
    conts = Enum.take_while(tail, &(Bitwise.band(&1, 0xC0) == 0x80)) |> length()

    case Enum.at(tail, conts) do
      lead when is_integer(lead) ->
        need =
          cond do
            Bitwise.band(lead, 0xE0) == 0xC0 -> 1
            Bitwise.band(lead, 0xF0) == 0xE0 -> 2
            Bitwise.band(lead, 0xF8) == 0xF0 -> 3
            true -> 0
          end

        if need > conts, do: binary_part(bin, 0, size - conts - 1), else: bin

      nil ->
        bin
    end
  end

  @doc """
  Writes `content` to `segments` below `tenant_dir` without following a
  symlink. Missing directories are created; any existing component that is
  not a real directory, or a target that is not a regular file, is refused.
  The file is owned by the tenant dir's owner (`uid:` overrides) and keeps an
  existing file's mode (`mode:` for a new one, default 0644).

  `create: true` writes only when nothing is there yet (a hard link of the
  temp file, which fails rather than replace). Returns `:ok`, `{:ok, :exists}`
  (create, a regular file is already there) or `{:error, reason}`.
  """
  def write(tenant_dir, segments, content, opts \\ []) do
    {dirs, [name]} = Enum.split(segments, -1)
    create? = Keyword.get(opts, :create, false)

    with {:ok, uid} <- owner(tenant_dir, opts),
         {:ok, dir} <- ensure_dirs(tenant_dir, dirs, uid),
         target = Path.join(dir, name),
         {:ok, mode} <- target_mode(target) do
      if create? and mode != :new do
        {:ok, :exists}
      else
        mode = if mode == :new, do: Keyword.get(opts, :mode, 0o644), else: mode
        put_file(tenant_dir, dirs, target, content, uid, mode, create?)
      end
    else
      :not_found -> {:error, :no_tenant_dir}
      {:error, _} = error -> error
    end
  end

  defp ensure_dirs(tenant_dir, dirs, uid) do
    Enum.reduce_while(dirs, {:ok, tenant_dir}, fn seg, {:ok, dir} ->
      path = Path.join(dir, seg)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          {:cont, {:ok, path}}

        {:error, :enoent} ->
          case make_dir(tenant_dir, path, uid) do
            :ok -> {:cont, {:ok, path}}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:halt, {:error, :not_a_directory}}
      end
    end)
  end

  # A new directory is made and chowned in the staging dir, then renamed into
  # place: a chown by path inside the bot's dir would follow a link the bot
  # swapped in. rename(2) of a directory fails on an existing link or file.
  defp make_dir(tenant_dir, path, uid) do
    with {:ok, staging} <- staging(tenant_dir) do
      tmp = Path.join(staging, "d#{System.unique_integer([:positive])}")

      result =
        with :ok <- File.mkdir(tmp),
             :ok <- :file.change_mode(tmp, 0o700),
             :ok <- :file.change_owner(tmp, uid) do
          :file.rename(tmp, path)
        end

      _ = :file.del_dir(tmp)
      result
    end
  end

  defp target_mode(target) do
    case File.lstat(target) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> {:ok, Bitwise.band(mode, 0o7777)}
      {:ok, _} -> {:error, :not_regular}
      {:error, :enoent} -> {:ok, :new}
      {:error, reason} -> {:error, reason}
    end
  end

  # The temp file is written, chmodded and chowned in the staging dir, which
  # the bot cannot write: chmod(2)/chown(2) by path inside the bot's own dir
  # would follow a symlink the bot swapped in for the temp name and hand any
  # host file to it (druzhok has CAP_CHOWN/CAP_FOWNER). Only then is it moved
  # into the bot's dir, by rename(2) (replaces, never follows the target) or,
  # for a seed, link(2) (fails if anything is there).
  defp put_file(tenant_dir, dirs, target, content, uid, mode, create?) do
    with {:ok, staging} <- staging(tenant_dir) do
      tmp = Path.join(staging, "f#{System.unique_integer([:positive])}")

      result =
        with {:ok, fd} <- :file.open(tmp, [:write, :exclusive, :binary, :raw]),
             :ok <- write_close(fd, content),
             :ok <- :file.change_mode(tmp, mode),
             :ok <- :file.change_owner(tmp, uid),
             # The directories may have been swapped since ensure_dirs/3.
             true <- real_dir?(tenant_dir, dirs) || {:error, :not_a_directory} do
          if create? do
            case :file.make_link(tmp, target) do
              :ok -> :ok
              {:error, :eexist} -> {:ok, :exists}
              {:error, reason} -> {:error, reason}
            end
          else
            :file.rename(tmp, target)
          end
        end

      # After a rename the temp name is gone; after a link (or a failure) it is not.
      _ = :file.delete(tmp)
      result
    end
  end

  # `.druzhok-staging` next to the tenant dirs: the same filesystem (rename and
  # link need it) and a parent no bot can write (/data/tenants is root's), so
  # nothing in it can be swapped. Created on first use, kept at 0700.
  defp staging(tenant_dir) do
    dir = Path.join(Path.dirname(Path.expand(tenant_dir)), ".druzhok-staging")
    _ = File.mkdir(dir)

    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} -> with :ok <- File.chmod(dir, 0o700), do: {:ok, dir}
      _ -> {:error, :no_staging_dir}
    end
  end

  defp write_close(fd, content) do
    result = :file.write(fd, content)
    :ok = :file.close(fd)
    result
  end

  @doc "Whether every component of `segments` below `tenant_dir` is a real directory."
  def real_dir?(tenant_dir, segments) do
    Enum.reduce_while(segments, tenant_dir, fn seg, dir ->
      path = Path.join(dir, seg)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} -> {:cont, path}
        _ -> {:halt, false}
      end
    end) != false
  end

  @doc """
  Whether request-supplied path segments are acceptable: no empty, `.`, `..`,
  leading `.` or `_`, `/` or NUL. Fixed paths the code names itself do not go
  through this.
  """
  def valid_segments?(segments) do
    Enum.all?(segments, fn seg ->
      is_binary(seg) and seg not in ["", ".", ".."] and not String.starts_with?(seg, ".") and
        not String.starts_with?(seg, "_") and not String.contains?(seg, "/") and
        not String.contains?(seg, "\0")
    end)
  end

  # Descend from `dir` one component at a time with lstat. Every intermediate
  # must be a real directory and the target a real regular file; with
  # `index?`, a directory target resolves to its index.html.
  defp walk(dir, [], true), do: walk_leaf(Path.join(dir, "index.html"))
  defp walk(_dir, [], false), do: :not_found

  defp walk(dir, [last], index?) do
    path = Path.join(dir, last)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} when index? -> walk(path, [], true)
      _ -> walk_leaf(path)
    end
  end

  defp walk(dir, [next | rest], index?) do
    path = Path.join(dir, next)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> walk(path, rest, index?)
      _ -> :not_found
    end
  end

  defp walk_leaf(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} -> {:ok, path, stat}
      _ -> :not_found
    end
  end
end
