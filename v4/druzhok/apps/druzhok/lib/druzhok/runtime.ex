defmodule Druzhok.Runtime do
  @moduledoc """
  Behaviour for bot runtime adapters. Each supported runtime (ZeroClaw, PicoClaw, etc.)
  implements this behaviour. Adding a new runtime = one new module + one registry entry.
  """

  @type instance :: map()

  @callback env_vars(instance) :: %{String.t() => String.t()}
  @callback workspace_files(instance) :: [{path :: String.t(), content :: String.t()}]
  @callback docker_image() :: String.t()
  @callback gateway_command() :: String.t()
  @callback health_path() :: String.t()
  @callback health_port() :: integer()
  @callback supports_feature?(atom()) :: boolean()

  @runtimes %{
    "zeroclaw" => Druzhok.Runtime.ZeroClaw,
    "picoclaw" => Druzhok.Runtime.PicoClaw,
  }

  def get(name) do
    Map.fetch!(@runtimes, to_string(name))
  end

  def get(name, default) do
    Map.get(@runtimes, to_string(name), default)
  end

  def list, do: @runtimes
  def names, do: Map.keys(@runtimes)

  def base_env(instance) do
    proxy_host = System.get_env("LLM_PROXY_HOST") || "host.docker.internal"
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"

    %{
      "OPENAI_BASE_URL" => "http://#{proxy_host}:#{proxy_port}/v1",
      "OPENAI_API_KEY" => Map.get(instance, :tenant_key, "") || "",
      "TZ" => Map.get(instance, :timezone, "UTC") || "UTC",
    }
  end
end
