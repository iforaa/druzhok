defmodule Druzhok.BotConfig do
  @moduledoc """
  Builds environment variable maps for bot containers.
  Each runtime (zeroclaw, picoclaw) has different env var conventions.
  """

  def build(instance) do
    proxy_host = System.get_env("LLM_PROXY_HOST") || "host.docker.internal"
    proxy_port = System.get_env("LLM_PROXY_PORT") || "4000"

    base = %{
      "OPENAI_BASE_URL" => "http://#{proxy_host}:#{proxy_port}/v1",
      "OPENAI_API_KEY" => get_field(instance, :tenant_key, ""),
      "TZ" => get_field(instance, :timezone, "UTC"),
    }

    runtime_env = case to_string(get_field(instance, :bot_runtime, "zeroclaw")) do
      "picoclaw" -> picoclaw_env(instance)
      "zeroclaw" -> zeroclaw_env(instance)
      _ -> generic_env(instance)
    end

    Map.merge(base, runtime_env)
  end

  def docker_image(instance) do
    case to_string(get_field(instance, :bot_runtime, "zeroclaw")) do
      "picoclaw" -> System.get_env("PICOCLAW_IMAGE") || "picoclaw:latest"
      "zeroclaw" -> System.get_env("ZEROCLAW_IMAGE") || "zeroclaw:latest"
      custom -> custom
    end
  end

  defp picoclaw_env(instance) do
    env = %{
      "PICOCLAW_AGENTS_DEFAULTS_MODEL_NAME" => get_field(instance, :model, "default"),
    }
    token = get_field(instance, :telegram_token, nil)
    if token do
      Map.merge(env, %{
        "PICOCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "PICOCLAW_CHANNELS_TELEGRAM_TOKEN" => token,
      })
    else
      env
    end
  end

  defp zeroclaw_env(instance) do
    env = %{
      "ZEROCLAW_AGENT_MODEL" => get_field(instance, :model, "default"),
      "ZEROCLAW_PROVIDER_TYPE" => "compatible",
    }
    token = get_field(instance, :telegram_token, nil)
    if token do
      Map.merge(env, %{
        "ZEROCLAW_CHANNELS_TELEGRAM_ENABLED" => "true",
        "ZEROCLAW_CHANNELS_TELEGRAM_TOKEN" => token,
      })
    else
      env
    end
  end

  defp generic_env(instance) do
    %{
      "BOT_MODEL" => get_field(instance, :model, "default"),
      "TELEGRAM_TOKEN" => get_field(instance, :telegram_token, ""),
    }
  end

  # Handle both maps and structs
  defp get_field(instance, key, default) when is_map(instance) do
    Map.get(instance, key) || Map.get(instance, to_string(key)) || default
  end
end
