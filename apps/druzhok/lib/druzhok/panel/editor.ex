defmodule Druzhok.Panel.Editor do
  @moduledoc """
  Saves a text page from the bot panel (spec
  `docs/superpowers/specs/2026-10-31-panel-editable-pages-design.md`).

  The save itself is `priv/panel-save/save.py`, run **as the bot's own user**.
  `TenantFiles.write/4` must not be used here: it checks directories by path
  and renames by path with druzhok's CAP_DAC_OVERRIDE, so a bot swapping
  `memories` for a symlink between the two could make a save land in another
  tenant. As the bot's uid a swap reaches only what the bot could write itself,
  and the save can hold hermes's locks and use hermes's own checks.

  System.cmd cannot close stdin and argv is visible in `ps`, so the input goes
  over in a file only the bot can read (`TenantFiles.hand_over/3`). `exec`
  neither starts nor wakes the bot, and a save does not touch `settings_seq`.
  Prod goes through `druzhok-ctl exec`; dev and test run the same command
  directly, or the stub in config `:panel_saver`.
  """

  require Logger

  alias Druzhok.{BotManager, Instance, Panel, TenantFiles}

  @max_body 512 * 1024
  @prefix ".panel-save-"
  @python "/opt/hermes/.venv/bin/python"
  @timeout_ms 60_000
  # :global.trans sleeps a random time up to 8 s a try, about 84 s in all on
  # average: long enough to wait out a run at its limit.
  @lock_retries 25

  @plain_checks ~w(invalid_text empty_soul invalid_skill)

  @doc """
  `target` is `{:file, kind}` or `{:skill, segments}`. `{:ok, %{sha256:,
  modified_at:}}` or `{:error, status, type, message, extra}`.
  """
  def save(%Instance{} = inst, target, text, base) do
    with :ok <- check_body(text, base),
         {:ok, edit} <- edit_target(inst, target),
         :ok <- check_size(text, edit) do
      id = {{__MODULE__, inst.name, edit.target}, self()}

      case :global.trans(id, fn -> run(inst, edit, text, base) end, [node()], @lock_retries) do
        :aborted -> failed("another save of this file is running")
        result -> result
      end
    end
  end

  @doc """
  At boot: removes hand-over files a crash left behind, and says so loudly when
  the installed script is not this release's, which only `ops/smoke.sh` and
  this would otherwise notice.
  """
  def boot do
    sweep()
    check_script()
  end

  @doc false
  def check_script do
    with installed when is_binary(installed) <- Application.get_env(:druzhok, :panel_save_script),
         ours = Application.app_dir(:druzhok, "priv/panel-save/save.py"),
         false <- File.read(installed) == File.read(ours) do
      Logger.error(
        "[panel] #{installed} is missing or differs from #{ours}: install it (CLAUDE.md, deploy recipe)"
      )

      :stale
    else
      _ -> :ok
    end
  end

  @doc "Removes hand-over files a crash left behind."
  def sweep do
    root = BotManager.data_root_base()

    case File.ls(root) do
      {:ok, names} ->
        for name <- names, String.starts_with?(name, @prefix), do: File.rm(Path.join(root, name))
        :ok

      _ ->
        :ok
    end
  end

  defp check_body(text, base) do
    cond do
      not is_binary(text) or not String.valid?(text) ->
        refused("invalid_text", "the text is not valid")

      not valid_base?(base) ->
        refused("invalid_text", "base_sha256 is not valid")

      true ->
        :ok
    end
  end

  defp valid_base?(nil), do: true
  defp valid_base?(base), do: is_binary(base) and Regex.match?(~r/^[0-9a-f]{64}$/, base)

  defp edit_target(inst, target) do
    case Panel.edit_target(inst, target) do
      {:ok, edit} -> {:ok, edit}
      :not_found -> {:error, 404, "not_found", "no such file", %{}}
    end
  end

  defp check_size(text, edit) do
    if byte_size(text) > @max_body,
      do: refused("too_long", "the text is too long", %{limit: edit.limit}),
      else: :ok
  end

  defp run(inst, edit, text, base) do
    dir = BotManager.tenant_dir(inst.name)

    job =
      Jason.encode!(%{
        target: edit.target,
        kind: edit.kind,
        base_sha256: base,
        text: text,
        limit: edit.limit
      })

    case TenantFiles.hand_over(dir, job, @prefix) do
      {:ok, path} ->
        try do
          inst.name |> command(dir, path) |> answer(inst.name)
        after
          File.rm(path)
        end

      {:error, reason} ->
        Logger.warning("[panel] no hand-over file for #{inst.name}: #{inspect(reason)}")
        failed("could not prepare the save")
    end
  end

  # A timed-out run may still finish; the page's next save then gets
  # file_changed, which is safe.
  defp command(name, dir, path) do
    task = Task.async(fn -> exec(name, dir, path) end)
    timeout = Application.get_env(:druzhok, :panel_save_timeout_ms, @timeout_ms)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {out, code}
      _ -> :timeout
    end
  end

  defp exec(name, dir, path) do
    case Application.get_env(:druzhok, :panel_saver) do
      {m, f} ->
        apply(m, f, [name, dir, path])

      nil ->
        if Application.get_env(:druzhok, :host) == Druzhok.Host.Systemd do
          Druzhok.Host.exec(name, [@python, "-I", script(), path])
        else
          File.mkdir_p(Path.join(dir, "workspace"))

          System.cmd(dev_python(), ["-I", script(), path],
            env: [{"HERMES_HOME", dir}],
            cd: Path.join(dir, "workspace"),
            stderr_to_stdout: true
          )
        end
    end
  end

  defp script do
    Application.get_env(:druzhok, :panel_save_script) ||
      Application.app_dir(:druzhok, "priv/panel-save/save.py")
  end

  defp dev_python do
    case Druzhok.Runtime.Hermes.bin() do
      "/" <> _ = bin -> Path.join(Path.dirname(bin), "python")
      _ -> "python3"
    end
  end

  # The bot's uid ran this, so nothing in its output is trusted: only the
  # expected shape on one line, and only a type this module knows, is an answer.
  defp answer(:timeout, name) do
    Logger.warning("[panel] the save for #{name} timed out")
    failed("the save timed out")
  end

  defp answer({out, 0}, name) when is_binary(out) do
    case parse(out) do
      {:ok, saved} -> {:ok, saved}
      {:error, _, _, _, _} = refusal -> refusal
      {:save_failed, reason} -> script_failed(name, reason)
      :garbage -> garbage(name)
    end
  end

  defp answer({_out, code}, name) do
    Logger.warning("[panel] the save for #{name} exited #{code}")
    failed("the save failed")
  end

  defp parse(out) do
    with [line] <- String.split(String.trim_trailing(out, "\n"), "\n"),
         {:ok, %{} = reply} <- Jason.decode(line) do
      reply(reply)
    else
      _ -> :garbage
    end
  end

  defp reply(%{"sha256" => sha, "modified_at" => at}) when is_binary(sha) and is_binary(at) do
    with true <- Regex.match?(~r/^[0-9a-f]{64}$/, sha),
         {:ok, modified_at, 0} <- DateTime.from_iso8601(at) do
      {:ok, %{sha256: sha, modified_at: modified_at}}
    else
      _ -> :garbage
    end
  end

  defp reply(%{"error" => "file_changed"}),
    do: {:error, 409, "file_changed", "the file changed since it was read", %{}}

  defp reply(%{"error" => "save_failed"} = reply), do: {:save_failed, reply["reason"]}

  defp reply(%{"error" => "too_long", "limit" => limit}) when is_integer(limit),
    do: refused("too_long", "the text is too long", %{limit: limit})

  defp reply(%{"error" => "blocked_entry", "entry" => entry}) when is_binary(entry),
    do:
      refused("blocked_entry", "hermes would not load this entry", %{
        entry: String.slice(entry, 0, 60)
      })

  defp reply(%{"error" => type}) when type in @plain_checks,
    do: refused(type, "the text was refused")

  defp reply(_), do: :garbage

  # The reason is the bot's uid's output too: logged only as a plain word.
  defp script_failed(name, reason) do
    shown = if is_binary(reason) and reason =~ ~r/^[A-Za-z]{1,64}$/, do: reason, else: "unknown"
    Logger.warning("[panel] the save for #{name} failed: #{shown}")
    failed("the save failed")
  end

  defp garbage(name) do
    Logger.warning("[panel] the save for #{name} answered something unexpected")
    failed("the save failed")
  end

  defp refused(type, message, extra \\ %{}), do: {:error, 422, type, message, extra}

  defp failed(message), do: {:error, 500, "save_failed", message, %{}}
end
