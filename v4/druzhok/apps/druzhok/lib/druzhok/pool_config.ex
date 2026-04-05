defmodule Druzhok.PoolConfig do
  @moduledoc "Generates OpenClaw multi-agent JSON config for a pool of instances."

  @default_port 18800

  @doc """
  Builds a multi-agent OpenClaw JSON config map for the given list of instances.

  Each instance must have: name, model, on_demand_model, tenant_key, telegram_token, workspace.

  Options:
    - `:port` — gateway port (default #{@default_port})

  Returns a map suitable for `Jason.encode!/1`.
  """
  def build(instances, opts \\ []) do
    port = Keyword.get(opts, :port, @default_port)
    proxy_host = Druzhok.Runtime.proxy_host()

    config = %{
      "gateway" => %{
        "bind" => "loopback",
        "port" => port,
        "reload" => %{"mode" => "hybrid"},
        "auth" => %{"mode" => "none"}
      },
      "session" => %{
        "dmScope" => "per-channel-peer"
      },
      "plugins" => %{
        "entries" => %{
          "openai" => %{"enabled" => true}
        }
      },
      "models" => %{
        "providers" => build_providers(instances, proxy_host)
      },
      "agents" => %{
        "defaults" => %{
          "sandbox" => %{"mode" => "all"},
          "memorySearch" => %{
            "enabled" => true,
            "provider" => "openai",
            "model" => "openai/text-embedding-3-small",
            "remote" => %{
              "baseUrl" => "http://#{proxy_host}:4000/v1",
              "apiKey" => List.first(instances).tenant_key
            }
          }
        },
        "list" => build_agent_list(instances)
      },
      "channels" => %{
        "telegram" => %{
          "accounts" => build_telegram_accounts(instances)
        }
      },
      "bindings" => build_bindings(instances)
    }

    # Add mention patterns for group chat trigger names
    config = case build_mention_patterns(instances) do
      [] -> config
      patterns -> put_in(config, ["messages"], %{"groupChat" => %{"mentionPatterns" => patterns}})
    end

    # Audio transcription routed through our proxy → OpenAI Whisper
    first_key = List.first(instances).tenant_key
    config
    |> put_in(["tools"], %{
      "media" => %{
        "audio" => %{
          "models" => [%{
            "provider" => "openai",
            "model" => "whisper-1",
            "baseUrl" => "http://#{proxy_host}:4000/v1"
          }],
          "baseUrl" => "http://#{proxy_host}:4000/v1",
          "request" => %{
            "auth" => %{"mode" => "authorization-bearer", "token" => first_key}
          }
        }
      }
    })
  end

  defp build_providers(instances, proxy_host) do
    Map.new(instances, fn instance ->
      name = instance.name
      provider_id = "tenant-#{name}"

      provider = %{
        "baseUrl" => "http://#{proxy_host}:4000/v1",
        "apiKey" => instance.tenant_key,
        "api" => "openai-completions",
        "models" => build_model_list(instance.model, instance.on_demand_model)
      }

      {provider_id, provider}
    end)
  end

  defp build_model_list(model, nil) do
    [%{"id" => model, "name" => "default"}]
  end

  defp build_model_list(model, on_demand_model) do
    [
      %{"id" => model, "name" => "default"},
      %{"id" => on_demand_model, "name" => "smart"}
    ]
  end

  defp build_agent_list(instances) do
    Enum.map(instances, fn instance ->
      name = instance.name
      %{
        "id" => name,
        "model" => "tenant-#{name}/#{instance.model}",
        "workspace" => "/data/workspaces/#{name}"
      }
    end)
  end

  defp build_telegram_accounts(instances) do
    Map.new(instances, fn instance ->
      allowed = build_allow_from(instance)
      groups = build_group_config(instance)

      account = %{
        "botToken" => instance.telegram_token,
        "dmPolicy" => "pairing",
        "allowFrom" => allowed,
        "groupPolicy" => "open"
      }

      account = if map_size(groups) > 0 do
        Map.put(account, "groups", groups)
      else
        account
      end

      {instance.name, account}
    end)
  end

  defp build_allow_from(instance) do
    owner = case Map.get(instance, :owner_telegram_id) do
      nil -> []
      id -> [to_string(id)]
    end

    db_ids = Druzhok.Instance.get_allowed_ids(instance)

    (owner ++ db_ids) |> Enum.uniq()
  end

  defp build_group_config(instance) do
    mention_only = Map.get(instance, :mention_only, false)

    case Map.get(instance, :name) do
      nil -> %{}
      name ->
        Druzhok.AllowedChat.groups_for_instance(name)
        |> Enum.filter(&(&1.status == "approved"))
        |> Map.new(fn chat ->
          {to_string(chat.chat_id), %{
            "enabled" => true,
            "groupPolicy" => "open",
            "requireMention" => mention_only
          }}
        end)
    end
  end

  defp build_bindings(instances) do
    Enum.map(instances, fn instance ->
      %{
        "agentId" => instance.name,
        "match" => %{
          "channel" => "telegram",
          "accountId" => instance.name
        }
      }
    end)
  end

  defp build_mention_patterns(instances) do
    instances
    |> Enum.map(&Map.get(&1, :trigger_name))
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn name -> "(?i)\\b#{Regex.escape(name)}\\b" end)
  end

end
