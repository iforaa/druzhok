defmodule Druzhok.Docs.Runner do
  @moduledoc """
  Runs one conversion: `job/in/input.<ext>` → `job/out/input.<to>`.
  `Runner.Systemd` in prod (the sandboxed wrapper), `Runner.Local` in dev
  (plain `soffice`), a fake in tests. Selected by `config :druzhok, :docs, runner:`.
  """

  @callback run(job :: Path.t(), to :: String.t(), filter :: String.t() | nil) ::
              {:ok, Path.t()} | {:error, :timeout | :failed | :unavailable}

  @doc "Stop a job still converting (its request is gone). Waits until it has stopped."
  @callback cancel(job :: Path.t()) :: :ok
  @optional_callbacks cancel: 1

  @doc false
  # A command with a deadline: {output, status}, :timeout (the OS process is
  # then left to its own limit: the unit's RuntimeMaxSec, or soffice's exit) or
  # {:error, exception} when it could not start.
  def cmd(bin, args, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          System.cmd(bin, args, stderr_to_stdout: true)
        rescue
          e -> {:error, e}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> :timeout
    end
  end
end

defmodule Druzhok.Docs.Runner.Systemd do
  @moduledoc """
  `sudo -n /usr/local/lib/druzhok/docs-convert <job> <to> [filter]`
  (`ops/docs-convert`): the wrapper prints the output path and exits 0, or
  exits 3 (conversion failed), 4 (soffice timed out) or anything else (the
  converter is not installed, or the wrapper refused or is missing).
  `docs-convert --stop <job>` stops the job's unit.
  """

  @behaviour Druzhok.Docs.Runner
  require Logger

  @wrapper "/usr/local/lib/druzhok/docs-convert"
  # The unit's own limit is 90 s; this only guards against a hung sudo.
  @timeout_ms 150_000
  @stop_timeout_ms 30_000

  @impl true
  def run(job, to, filter) do
    args = ["-n", wrapper(), job, to] ++ List.wrap(filter)

    case Druzhok.Docs.Runner.cmd("sudo", args, @timeout_ms) do
      {out, 0} -> {:ok, out |> String.trim() |> String.split("\n") |> List.last()}
      {out, 3} ->
        Logger.warning("[docs] conversion failed: #{String.slice(out, 0, 300)}")
        {:error, :failed}

      {_, 4} -> {:error, :timeout}
      :timeout -> {:error, :timeout}
      {:error, e} ->
        Logger.error("[docs] cannot run sudo: #{inspect(e)}")
        {:error, :unavailable}

      {out, status} ->
        Logger.error("[docs] #{@wrapper} exited #{status}: #{String.slice(out, 0, 300)}")
        {:error, :unavailable}
    end
  end

  @impl true
  def cancel(job) do
    case Druzhok.Docs.Runner.cmd("sudo", ["-n", wrapper(), "--stop", job], @stop_timeout_ms) do
      {_, 0} -> :ok
      other -> Logger.error("[docs] could not stop #{Path.basename(job)}: #{inspect(other)}")
    end

    :ok
  end

  defp wrapper, do: Keyword.get(Application.get_env(:druzhok, :docs, []), :wrapper, @wrapper)
end

defmodule Druzhok.Docs.Runner.Local do
  @moduledoc """
  Dev only: the developer's own `soffice`, unsandboxed (`config :druzhok, :docs,
  soffice:`, else `soffice` on PATH, else the macOS app). No soffice → `:unavailable`.
  """

  @behaviour Druzhok.Docs.Runner

  @timeout_ms 90_000
  @mac_app "/Applications/LibreOffice.app/Contents/MacOS/soffice"

  @impl true
  def run(job, to, filter) do
    with bin when is_binary(bin) <- soffice(),
         {:ok, [input]} <- File.ls(Path.join(job, "in")) do
      target = if filter, do: to <> ":" <> filter, else: to

      args = [
        "--headless", "--norestore", "--nologo", "--nolockcheck", "--nodefault",
        "-env:UserInstallation=file://" <> URI.encode(Path.join(job, "profile")),
        "--convert-to", target, "--outdir", Path.join(job, "out"), Path.join([job, "in", input])
      ]

      out = Path.join([job, "out", "input." <> to])

      case Druzhok.Docs.Runner.cmd(bin, args, @timeout_ms) do
        :timeout -> {:error, :timeout}
        {:error, _} -> {:error, :unavailable}
        {_, 0} -> if File.regular?(out), do: {:ok, out}, else: {:error, :failed}
        _ -> {:error, :failed}
      end
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc "The soffice this runner would use, or nil."
  def soffice do
    Keyword.get(Application.get_env(:druzhok, :docs, []), :soffice) ||
      System.find_executable("soffice") ||
      if(File.exists?(@mac_app), do: @mac_app)
  end
end
