defmodule Druzhok.Cmd do
  @moduledoc """
  `System.cmd/3` with something on the command's stdin.

  System.cmd has no stdin, and argv is visible in `ps`, so secrets and file
  contents (a bot's env file, a config.yaml) go over in a file only druzhok
  can read, which a shell opens as the command's stdin and which is removed
  when the command ends. The name is random and the file is created
  exclusively, in druzhok's own tmp dir.
  """

  @doc "Runs `bin args` with `input` as its stdin. `{output, exit_status}`, as System.cmd."
  def run(bin, args, input, opts \\ []) do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "druzhok-in-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    {:ok, fd} = :file.open(tmp, [:write, :exclusive, :binary, :raw])

    try do
      :ok = :file.change_mode(tmp, 0o600)
      :ok = :file.write(fd, input)
      :ok = :file.close(fd)
      # $1 is the file, the rest the command: nothing is interpolated.
      System.cmd(
        "/bin/sh",
        ["-c", ~S(f=$1; shift; exec "$@" < "$f"), "sh", tmp, bin | args],
        opts
      )
    after
      _ = :file.close(fd)
      File.rm(tmp)
    end
  end
end
