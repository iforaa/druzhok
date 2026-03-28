defmodule Druzhok.Sandbox.Local do
  @behaviour Druzhok.Sandbox

  @impl true
  def start(_instance_name, _opts), do: {:ok, self()}

  @impl true
  def stop(_instance_name), do: :ok

  @impl true
  def exec(_instance_name, command) do
    {output, code} =
      System.cmd("bash", ["-c", command], stderr_to_stdout: true, cd: System.tmp_dir!())

    {:ok, %{stdout: output, stderr: "", exit_code: code}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def read_file(_instance_name, path), do: File.read(path)

  @impl true
  def write_file(_instance_name, path, content) do
    File.mkdir_p!(Path.dirname(path))

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_dir(_instance_name, path) do
    case File.ls(path) do
      {:ok, entries} ->
        items =
          Enum.map(entries, fn name ->
            full = Path.join(path, name)
            stat = File.stat!(full)
            %{name: name, is_dir: stat.type == :directory, size: stat.size}
          end)

        {:ok, items}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
