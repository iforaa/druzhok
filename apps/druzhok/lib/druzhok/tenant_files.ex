defmodule Druzhok.TenantFiles do
  @moduledoc """
  Druzhok's file work inside a bot's tenant dir: reading for the panel and the
  lifecycle checks, writing druzhok's own files there (config.yaml, SOUL.md,
  the seeds).

  The bot owns everything below its tenant dir, 0700, and druzhok has no file
  capabilities, so none of this is done in this process. Every call goes to
  the `tenant-fs` helper (`priv/tenant-fs/tenant_fs.py`, installed root-owned
  and run through sudo in prod, kept open by `TenantFiles.Server`), which becomes the bot's own user before it
  touches the dir and never follows a symlink below it. A bot that plants a
  link, or swaps a directory mid-call, reaches nothing it could not reach
  itself; another tenant's files and the host's are out of reach by uid.

  Dev and test run the same script as the caller, on the dir itself.

  A call that could not ask the helper at all (sudo refused, the script is
  missing, it died) raises `Druzhok.TenantFiles.Error`: "the file is not
  there" must never be confused with "nobody looked", because a start seeds
  what is missing. Directory *listings* for the panel are `Druzhok.Panel.Lister`.
  """

  require Logger

  defmodule Error do
    defexception [:message]
  end

  @prod_cmd ["sudo", "-n", "/usr/local/lib/druzhok/tenant-fs"]

  @doc """
  Reads at most `limit` bytes of the regular file at `segments`:
  `{:ok, %{bytes: binary, size: n, modified_at: DateTime, truncated: bool}}`
  or `:not_found` (nothing there, not a regular file, a link on the way).
  `index: true` serves a directory as its `index.html`; `missing: true` tells
  nothing at that name, `:missing`, from a file that cannot be read.
  """
  def read(tenant_dir, segments, limit, opts \\ []) do
    [result] = read_many(tenant_dir, [{segments, limit}], opts)
    result
  end

  @doc "`read/4` for several `{segments, limit}` of one bot in one helper call."
  def read_many(tenant_dir, files, opts \\ []) do
    [results] = read_all([{tenant_dir, files}], opts)
    results
  end

  @doc """
  `read_many/3` across bots, one helper call for all of them:
  `[{tenant_dir, [{segments, limit}]}]` in, a list of result lists out.
  """
  def read_all(jobs, opts \\ []) do
    index? = Keyword.get(opts, :index, false)
    # No tenant dir is nothing there, as it is for a path below one.
    absent = if Keyword.get(opts, :missing, false), do: :missing, else: :not_found

    jobs
    |> Enum.map(fn {dir, files} ->
      {dir,
       for(
         {segments, limit} <- files,
         do: %{op: "read", path: segments, limit: limit, index: index?}
       )}
    end)
    |> run_jobs()
    |> Enum.zip(jobs)
    |> Enum.map(fn
      {{:ok, results}, _job} -> Enum.map(results, &read_result(&1, absent))
      {{:error, :no_tenant_dir}, {_dir, files}} -> Enum.map(files, fn _ -> absent end)
    end)
  end

  defp read_result(%{"ok" => true, "data" => data, "size" => size, "mtime" => mtime} = r, _absent)
       when is_binary(data) and is_integer(size) and is_integer(mtime) do
    with {:ok, bytes} <- Base.decode64(data),
         {:ok, modified_at} <- DateTime.from_unix(mtime) do
      {:ok,
       %{bytes: bytes, size: size, modified_at: modified_at, truncated: r["truncated"] == true}}
    else
      _ -> :not_found
    end
  end

  defp read_result(%{"ok" => false, "error" => "enoent"}, absent), do: absent
  defp read_result(_, _absent), do: :not_found

  @doc """
  `read/3` for text: a cut is trimmed back to a whole UTF-8 character, then
  the text must be valid UTF-8. `{:ok, %{text: …, sha256: …, …}}`, `:not_found`
  or `:not_text`. `sha256` is the hex hash of the whole file, nil after a cut.
  """
  def read_text(tenant_dir, segments, limit, opts \\ []),
    do: tenant_dir |> read(segments, limit, opts) |> as_text()

  @doc "`read_text/4` for several `{segments, limit}` of one bot in one helper call."
  def read_texts(tenant_dir, files), do: tenant_dir |> read_many(files) |> Enum.map(&as_text/1)

  defp as_text({:ok, %{bytes: bytes, truncated: truncated} = r}) do
    text = if truncated, do: trim_utf8(bytes), else: bytes

    if String.valid?(text),
      do: {:ok, r |> Map.delete(:bytes) |> Map.merge(%{text: text, sha256: sha256(r)})},
      else: :not_text
  end

  defp as_text(other), do: other

  defp sha256(%{truncated: true}), do: nil
  defp sha256(%{bytes: bytes}), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

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
  What is at `segments`, a link never followed: `{:ok, %{type: :regular |
  :directory | :symlink | :other, size: n, mtime: unix}}` or `{:error, reason}`
  (`:enoent` when nothing is there, `:not_a_directory` for a link or a file on
  the way).
  """
  def lstat(tenant_dir, segments) do
    case op(tenant_dir, %{op: "stat", path: segments}) do
      {:ok, %{"type" => type, "size" => size, "mtime" => mtime}}
      when type in ~w(regular directory symlink other) and is_integer(size) and is_integer(mtime) ->
        {:ok, %{type: String.to_atom(type), size: size, mtime: mtime}}

      {:ok, _} ->
        {:error, :bad_answer}

      # No tenant dir is nothing there, as it is for a path below one.
      {:error, :no_tenant_dir} ->
        {:error, :enoent}

      {:error, _} = error ->
        error
    end
  end

  @doc "The names in the real directory at `segments`: `{:ok, [name]}` or `{:error, reason}`."
  def ls(tenant_dir, segments) do
    case op(tenant_dir, %{op: "ls", path: segments}) do
      {:ok, %{"names" => names}} when is_list(names) -> {:ok, Enum.filter(names, &is_binary/1)}
      {:ok, _} -> {:error, :bad_answer}
      {:error, _} = error -> error
    end
  end

  @doc """
  Writes `content` to `segments` below `tenant_dir` without following a
  symlink. Missing directories are created; any existing component that is
  not a real directory, or a target that is not a regular file, is refused.
  The file is the bot's and keeps an existing file's mode (`mode:` for a new
  one, default 0644).

  `create: true` writes only when nothing is there yet. Returns `:ok`,
  `{:ok, :exists}` (create, a regular file is already there) or
  `{:error, reason}`.
  """
  def write(tenant_dir, segments, content, opts \\ []) do
    request = %{
      op: "write",
      path: segments,
      data: Base.encode64(IO.iodata_to_binary(content)),
      create: Keyword.get(opts, :create, false),
      mode: Keyword.get(opts, :mode)
    }

    case op(tenant_dir, request) do
      {:ok, %{"exists" => true}} -> {:ok, :exists}
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Makes sure `segments` below `tenant_dir` are real directories, creating
  missing ones as the bot. `{:ok, path}` or `{:error, reason}`.
  """
  def ensure_dir(tenant_dir, segments) do
    with {:ok, _} <- op(tenant_dir, %{op: "mkdir", path: segments}),
         do: {:ok, Path.join([tenant_dir | segments])}
  end

  @doc """
  Removes the regular file at `segments`. A link is never followed: one at the
  target is refused, one on the way too. `:ok`, `:not_found` (nothing there) or
  `{:error, reason}`.
  """
  def delete(tenant_dir, segments) do
    case op(tenant_dir, %{op: "delete", path: segments}) do
      {:ok, _} -> :ok
      {:error, :enoent} -> :not_found
      {:error, _} = error -> error
    end
  end

  @doc "Removes the tree at `segments` (missing is fine); links are unlinked, never followed."
  def rm_tree(tenant_dir, segments) do
    case op(tenant_dir, %{op: "rmtree", path: segments}) do
      {:ok, _} -> :ok
      {:error, :no_tenant_dir} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc "Whether every component of `segments` below `tenant_dir` is a real directory."
  def real_dir?(tenant_dir, segments),
    do: match?({:ok, _}, op(tenant_dir, %{op: "is_dir", path: segments}))

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

  @doc """
  At boot: says so loudly when the installed helper is not this release's
  (`Druzhok.Panel.Editor.check_script/0` does the same for the save script).
  """
  def check_script do
    with ["sudo", "-n", installed] <- command(),
         ours = Application.app_dir(:druzhok, "priv/tenant-fs/tenant_fs.py"),
         false <- File.read(installed) == File.read(ours) do
      Logger.error(
        "[tenant-fs] #{installed} is missing or differs from #{ours}: install it (CLAUDE.md, deploy recipe)"
      )

      :stale
    else
      _ -> :ok
    end
  end

  # --- the helper -------------------------------------------------------------

  defp op(tenant_dir, request) do
    case run(tenant_dir, [request]) do
      {:ok, [%{"ok" => true} = answer]} -> {:ok, answer}
      {:ok, [%{"error" => reason}]} -> {:error, reason(reason)}
      {:error, _} = error -> error
    end
  end

  defp run(tenant_dir, ops) do
    [result] = run_jobs([{tenant_dir, ops}])
    result
  end

  # `[{tenant_dir, ops}]` -> `[{:ok, results} | {:error, reason}]`, in order.
  defp run_jobs([]), do: []

  defp run_jobs(jobs) do
    prod? = Application.get_env(:druzhok, :host) == Druzhok.Host.Systemd

    request = %{
      jobs:
        for {dir, ops} <- jobs do
          # The helper takes the name and finds the dir itself, as root; a dir
          # that is not a bot's tenant dir gets a name no bot can have.
          if prod?, do: %{name: bot_name(dir), ops: ops}, else: %{dir: Path.expand(dir), ops: ops}
        end
    }

    with {:ok, out} <- ask(Jason.encode!(request)),
         {:ok, %{"jobs" => answers}} when length(answers) == length(jobs) <- Jason.decode(out) do
      for {answer, {_dir, ops}} <- Enum.zip(answers, jobs), do: job_result(answer, length(ops))
    else
      other ->
        raise Error, "tenant-fs did not answer: #{inspect(other, limit: 5, printable_limit: 200)}"
    end
  end

  # The helper kept open answers first (`TenantFiles.Server`); when it cannot,
  # one is run for this request alone.
  defp ask(request) do
    [bin | args] = cmd = command()

    case Druzhok.TenantFiles.Server.request(cmd, request) do
      {:ok, out} ->
        {:ok, out}

      :error ->
        case Druzhok.Cmd.run(bin, args, request) do
          {out, 0} -> {:ok, out}
          other -> other
        end
    end
  end

  defp job_result(%{"ok" => true, "results" => results}, n)
       when is_list(results) and length(results) == n do
    if Enum.all?(results, &is_map/1),
      do: {:ok, results},
      else: raise(Error, "tenant-fs answered something unexpected")
  end

  defp job_result(%{"ok" => false, "error" => error}, _n)
       when error in ["no_tenant_dir", "no_bot"],
       do: {:error, :no_tenant_dir}

  defp job_result(other, _n),
    do:
      raise(Error, "tenant-fs refused the job: #{inspect(other, limit: 5, printable_limit: 200)}")

  defp bot_name(dir) do
    name = Path.basename(dir)

    if Path.dirname(Path.expand(dir)) == Druzhok.BotManager.data_root_base() and
         Druzhok.Host.valid_name?(name),
       do: name,
       else: ""
  end

  defp command do
    case Application.get_env(:druzhok, :tenant_fs) do
      [_ | _] = cmd ->
        cmd

      nil ->
        if Application.get_env(:druzhok, :host) == Druzhok.Host.Systemd do
          @prod_cmd
        else
          [python(), "-I", Application.app_dir(:druzhok, "priv/tenant-fs/tenant_fs.py")]
        end
    end
  end

  defp python, do: System.find_executable("python3") || "/usr/bin/python3"

  @reasons ~w(not_a_directory not_regular no_tenant_dir enoent eacces eperm enospc edquot
              eexist enotempty eisdir enametoolong erofs eio bad_path bad_data bad_mode
              bad_limit bad_op not_found)

  # The helper's word for a refusal, as an atom when it is one we know.
  defp reason(reason) when reason in @reasons, do: String.to_atom(reason)
  defp reason(_), do: :failed
end
