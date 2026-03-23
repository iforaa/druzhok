defmodule Druzhok.Sandbox do
  @callback start(instance_name :: String.t(), opts :: map()) :: {:ok, pid()} | {:error, term()}
  @callback stop(instance_name :: String.t()) :: :ok
  @callback exec(instance_name :: String.t(), command :: String.t()) ::
              {:ok, %{stdout: String.t(), stderr: String.t(), exit_code: integer()}}
              | {:error, term()}
  @callback read_file(instance_name :: String.t(), path :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback write_file(instance_name :: String.t(), path :: String.t(), content :: String.t()) ::
              :ok | {:error, term()}
  @callback list_dir(instance_name :: String.t(), path :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  def impl(sandbox_type) do
    case sandbox_type do
      "firecracker" -> Druzhok.Sandbox.Firecracker
      "docker" -> Druzhok.Sandbox.Docker
      _ -> Druzhok.Sandbox.Local
    end
  end

  defmacro __using__(opts) do
    client_module = opts[:client]

    quote do
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
        do: with_client(instance_name, &unquote(client_module).exec(&1, command))

      @impl true
      def read_file(instance_name, path),
        do: with_client(instance_name, &unquote(client_module).read_file(&1, path))

      @impl true
      def write_file(instance_name, path, content),
        do: with_client(instance_name, &unquote(client_module).write_file(&1, path, content))

      @impl true
      def list_dir(instance_name, path),
        do: with_client(instance_name, &unquote(client_module).list_dir(&1, path))

      defp with_client(instance_name, fun) do
        case Registry.lookup(Druzhok.Registry, {instance_name, :sandbox}) do
          [{pid, _}] -> fun.(pid)
          [] -> {:error, "Sandbox not running"}
        end
      end
    end
  end
end
