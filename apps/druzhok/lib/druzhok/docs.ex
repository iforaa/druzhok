defmodule Druzhok.Docs do
  @moduledoc """
  Shared LibreOffice conversion for bots (`POST /v2/docs/convert`, spec
  step 2 of the office documents work). One `soffice` per job, started on
  demand and gone after: nothing runs between jobs.

  A job is a directory `<jobs root>/<random>/` holding `in/input.<ext>` and an
  empty `out/`; the runner converts into `out/input.<to>`. In prod
  (`Docs.Runner.Systemd`) a root-owned wrapper hands the dir to the
  `cleo-docs` user and runs soffice in a transient systemd unit with no
  network and nothing else writable. The job dir is deleted on every path,
  and whatever a crash left is swept once per boot (`sweep/0`).

  Order of a job: the bot's place in `Docs.Queue` (one at a time, 4 waiting,
  one per bot), then `MemAvailable` ≥ Settings `docs_min_free_mb` (default 900;
  no reading passes, like `Lifecycle.StartGate`), then the runner.
  """

  require Logger

  # csv beyond the spec's seven: the xlsx skill runs `--convert-to csv` (first sheet).
  @targets ~w(pdf docx xlsx pptx odt ods odp csv)
  @inputs ~w(doc docx odt rtf txt html xls xlsx ods csv ppt pptx odp)

  # The export filters soffice --convert-to takes for each target. Anything
  # else is refused; ops/docs-convert holds the same list.
  @filters %{
    "pdf" => ["writer_pdf_Export", "calc_pdf_Export", "impress_pdf_Export", "writer_web_pdf_Export"],
    "docx" => ["MS Word 2007 XML", "Office Open XML Text"],
    "xlsx" => ["Calc MS Excel 2007 XML", "Calc Office Open XML"],
    "pptx" => ["Impress MS PowerPoint 2007 XML", "Impress Office Open XML"],
    "odt" => ["writer8"],
    "ods" => ["calc8"],
    "odp" => ["impress8"],
    "csv" => ["Text - txt - csv (StarCalc)"]
  }

  # The file's own limit; the request body may be this plus the multipart
  # framing around it.
  @max_input_bytes 20 * 1024 * 1024
  @body_overhead_bytes 64 * 1024
  # A result this big is not sent on (and a runaway job is cut long before by
  # the unit's LimitFSIZE).
  @max_output_bytes 100 * 1024 * 1024
  @max_waiting 4
  @default_min_free_mb 900

  def targets, do: @targets
  def inputs, do: @inputs
  def filters, do: @filters

  def max_input_bytes, do: opt(:max_input_bytes, @max_input_bytes)
  def max_body_bytes, do: max_input_bytes() + @body_overhead_bytes
  def max_waiting, do: opt(:max_waiting, @max_waiting)

  @doc "Whether `filter` (nil = none) may go with target `to`."
  def valid_filter?(_to, nil), do: true
  def valid_filter?(to, filter), do: filter in Map.get(@filters, to, [])

  @doc """
  Convert `source` (an input of extension `ext`, already checked) to `to` for
  `instance`, and call `on_result.(out_path)` with the result once the slot
  is given back, before the job dir goes.

  `{:ok, deliver_result}` or `{:error, :busy | :low_memory | :timeout | :failed | :unavailable}`.
  """
  def convert(instance, source, ext, to, filter, on_result) when to in @targets and ext in @inputs do
    started = System.monotonic_time(:millisecond)
    bytes_in = file_size(source)

    {result, bytes_out} =
      case Druzhok.Docs.Queue.enter(instance.id) do
        :ok ->
          # The slot is held for the conversion only, not while the result is sent.
          {result, job} =
            try do
              in_slot(source, ext, to, filter)
            after
              Druzhok.Docs.Queue.leave()
            end

          try do
            deliver(result, job, to, on_result)
          after
            if job, do: File.rm_rf(job)
          end

        {:error, :busy} ->
          {{:error, :busy}, 0}
      end

    Logger.info(
      "[docs] bot=#{instance.name} in=#{ext} to=#{to} bytes_in=#{bytes_in} bytes_out=#{bytes_out} " <>
        "ms=#{System.monotonic_time(:millisecond) - started} result=#{outcome(result)}"
    )

    result
  end

  # {runner result, job dir or nil}; a job dir made here is deleted here if
  # the runner raises.
  defp in_slot(source, ext, to, filter) do
    with :ok <- memory_ok(),
         {:ok, job} <- make_job(source, ext) do
      try do
        Druzhok.Docs.Queue.started(job)
        {runner().run(job, to, filter), job}
      rescue
        e ->
          File.rm_rf(job)
          reraise e, __STACKTRACE__
      end
    else
      error -> {error, nil}
    end
  end

  defp deliver({:ok, out}, job, to, on_result) do
    case check_output(job, out, to) do
      {:ok, size} -> {{:ok, on_result.(out)}, size}
      error -> {error, 0}
    end
  end

  defp deliver(error, _job, _to, _on_result), do: {error, 0}

  defp memory_ok do
    free = Druzhok.MemInfo.available_mb(opt(:meminfo_path, nil))
    if free && free < min_free_mb(), do: {:error, :low_memory}, else: :ok
  end

  @doc "The `MemAvailable` a job needs, in MB."
  def min_free_mb do
    case opt(:min_free_mb, nil) do
      mb when is_integer(mb) ->
        mb

      _ ->
        Druzhok.Settings.positive_int("docs_min_free_mb", @default_min_free_mb)
    end
  end

  defp make_job(source, ext) do
    job = Path.join(jobs_root(), random_id())

    with :ok <- File.mkdir(job),
         :ok <- File.chmod(job, 0o700),
         :ok <- File.mkdir(Path.join(job, "in")),
         :ok <- File.mkdir(Path.join(job, "out")),
         :ok <- File.cp(source, Path.join([job, "in", "input." <> ext])) do
      {:ok, job}
    else
      {:error, reason} ->
        Logger.error("[docs] cannot make a job dir under #{jobs_root()}: #{inspect(reason)}")
        File.rm_rf(job)
        {:error, :unavailable}
    end
  end

  # The converter ran as another user and wrote this dir; nothing of it runs
  # any more, so what lstat says now holds. Only a plain file at the one
  # expected path is read: never a link that would point druzhok, which may
  # read any file, somewhere else.
  defp check_output(job, out, to) do
    expected = Path.join([job, "out", "input." <> to])

    with true <- out == expected,
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(job, "out")),
         {:ok, %File.Stat{type: :regular, size: size}} when size > 0 <- File.lstat(expected),
         true <- size <= opt(:max_output_bytes, @max_output_bytes) do
      {:ok, size}
    else
      _ ->
        Logger.warning("[docs] unusable result in #{Path.basename(job)}")
        {:error, :failed}
    end
  end

  @doc """
  Stop a job whose request died while converting, and delete its dir. Called
  by `Docs.Queue`, which holds the next job back until this returns.
  """
  def cancel(job) do
    r = runner()
    if function_exported?(r, :cancel, 1), do: r.cancel(job)
    File.rm_rf(job)
    Logger.warning("[docs] request gone mid-conversion: stopped #{Path.basename(job)}")
    :ok
  end

  @doc "Delete every job dir left under the jobs root."
  def sweep do
    root = jobs_root()

    case File.ls(root) do
      {:ok, entries} ->
        # A unit started before druzhok stopped outlives it (it is not in
        # druzhok's cgroup): stop it first, or it runs beside the next job.
        r = runner()

        Enum.each(entries, fn entry ->
          job = Path.join(root, entry)
          if function_exported?(r, :cancel, 1), do: r.cancel(job)
          File.rm_rf(job)
        end)

        if entries != [], do: Logger.warning("[docs] swept #{length(entries)} job dir(s) left in #{root}")

      {:error, :enoent} ->
        if runner() != Druzhok.Docs.Runner.Systemd, do: File.mkdir_p(root)

      {:error, reason} ->
        Logger.error("[docs] cannot read #{root}: #{inspect(reason)}")
    end

    :ok
  end

  def jobs_root,
    do: opt(:jobs_root, nil) || Path.join(System.tmp_dir!(), "druzhok-docs-jobs")

  def runner, do: opt(:runner, Druzhok.Docs.Runner.Local)

  # 24 random bytes: 32 characters of [A-Za-z0-9_-], what the wrapper accepts.
  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp outcome({:ok, _}), do: "ok"
  defp outcome({:error, reason}), do: reason

  defp opt(key, default), do: Keyword.get(Application.get_env(:druzhok, :docs, []), key, default)
end
