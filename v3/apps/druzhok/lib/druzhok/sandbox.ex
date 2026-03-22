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
      "docker" -> Druzhok.Sandbox.Docker
      _ -> Druzhok.Sandbox.Local
    end
  end
end
