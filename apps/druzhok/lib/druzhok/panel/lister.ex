defmodule Druzhok.Panel.Lister do
  @moduledoc """
  Lists a directory below a bot's tenant dir **as the bot's own user** (bot
  panel spec, "Listing a directory").

  An in-process walk resolves the whole path again at every step, and the
  bot, which owns these directories, can swap a parent for a symlink between
  two steps; with druzhok's CAP_DAC_READ_SEARCH that would list another
  tenant's tree. Run as the bot's uid, a race reaches only what the bot could
  read itself. Prod goes through `druzhok-ctl exec` (a transient unit with the
  bot's uid; it does not start or wake the bot). Dev and test run the same
  command directly, since `Host.Process.exec/2` needs the bot running.

  GNU find is required (`-printf`): config `:find_bin`.
  """

  require Logger

  # $0 is find, $1 the root, $2 the depth: never interpolated into the script.
  @script ~S{exec "$0" -P "$1" -mindepth 1 -maxdepth "$2" \( -name ".*" -o -name "_*" \) -prune -o -printf "%y %s %P\0" 2>/dev/null}

  @doc """
  `root` is relative to the bot's `workspace/` (the unit's cwd): `"sites"` or
  `"../skills"`. Returns up to `max` entries `%{type: :file | :dir, size: n,
  path: "rel/path"}`; symlinks and anything else are dropped. Never raises.
  """
  def list(instance_name, tenant_dir, root, depth, max) do
    out =
      case Application.get_env(:druzhok, :panel_lister) do
        {m, f} -> apply(m, f, [instance_name, tenant_dir, root, depth])
        nil -> run(instance_name, tenant_dir, root, depth)
      end

    parse(out, max)
  rescue
    e ->
      Logger.warning("[panel] listing #{instance_name}/#{root} failed: #{Exception.message(e)}")
      []
  end

  defp run(name, tenant_dir, root, depth) do
    args = ["-c", @script, find_bin(), root, Integer.to_string(depth)]

    {out, _code} =
      if Application.get_env(:druzhok, :host) == Druzhok.Host.Systemd do
        Druzhok.Host.exec(name, ["/bin/sh" | args])
      else
        System.cmd("/bin/sh", args, cd: Path.join(tenant_dir, "workspace"))
      end

    out
  end

  defp find_bin, do: Application.get_env(:druzhok, :find_bin, "/usr/bin/find")

  @doc "Parses find's `%y %s %P\\0` records. An unparsable record ends the list."
  def parse(out, max) when is_binary(out) do
    out
    |> String.split("\0")
    |> Enum.reduce_while([], fn rec, acc ->
      cond do
        length(acc) >= max ->
          {:halt, acc}

        rec == "" ->
          {:cont, acc}

        true ->
          case String.split(rec, " ", parts: 3) do
            [type, size, path] when type in ["f", "d"] and path != "" ->
              case Integer.parse(size) do
                {n, ""} ->
                  {:cont,
                   [%{type: if(type == "f", do: :file, else: :dir), size: n, path: path} | acc]}

                _ ->
                  {:halt, acc}
              end

            [_other, _size, _path] ->
              {:cont, acc}

            _ ->
              {:halt, acc}
          end
      end
    end)
    |> Enum.reverse()
  end

  def parse(_out, _max), do: []
end
