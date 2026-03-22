defmodule Druzhok.Sandbox.Docker do
  @behaviour Druzhok.Sandbox

  @impl true
  def start(_instance_name, _opts), do: {:ok, :started}

  @impl true
  def stop(instance_name) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
      [{pid, _}] -> GenServer.stop(pid, :normal, 10_000)
      [] -> :ok
    end
  end

  @impl true
  def exec(instance_name, command),
    do: with_client(instance_name, &Druzhok.Sandbox.DockerClient.exec(&1, command))

  @impl true
  def read_file(instance_name, path),
    do: with_client(instance_name, &Druzhok.Sandbox.DockerClient.read_file(&1, path))

  @impl true
  def write_file(instance_name, path, content),
    do: with_client(instance_name, &Druzhok.Sandbox.DockerClient.write_file(&1, path, content))

  @impl true
  def list_dir(instance_name, path),
    do: with_client(instance_name, &Druzhok.Sandbox.DockerClient.list_dir(&1, path))

  defp with_client(instance_name, fun) do
    case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
      [{pid, _}] -> fun.(pid)
      [] -> {:error, "Sandbox not running"}
    end
  end
end
