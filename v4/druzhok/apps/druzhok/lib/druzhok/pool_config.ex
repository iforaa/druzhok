defmodule Druzhok.PoolConfig do
  @moduledoc "Generates OpenClaw multi-agent JSON config for a pool of instances."

  @default_port 18800

  @default_image_model Druzhok.ModelCatalog.default_image_model()
  @default_audio_model Druzhok.ModelCatalog.default_audio_model()
  @default_embedding_model Druzhok.ModelCatalog.default_embedding_model()

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
    proxy_url = "http://#{proxy_host}:4000/v1"
    first = List.first(instances)
    first_tenant_key = first.tenant_key
    image_model = first.image_model || @default_image_model
    audio_model = first.audio_model || @default_audio_model
    embedding_model = first.embedding_model || @default_embedding_model

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
        "entries" => build_plugin_entries(instances)
      },
      "models" => %{
        "providers" => build_providers(instances, proxy_host)
      },
      "agents" => %{
        "defaults" => %{
          "sandbox" => %{
            "mode" => "all",
            "workspaceAccess" => "rw",
            "docker" => %{"network" => "bridge"}
          },
          "memorySearch" => %{
            "enabled" => true,
            "provider" => "openai",
            "model" => embedding_model,
            "remote" => %{
              "baseUrl" => proxy_url,
              "apiKey" => first_tenant_key
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

    # Audio transcription routed through our proxy (no API keys in container)
    # OpenClaw calls localhost:4000 with native fetch (no proxy agent = clean FormData)
    config
    |> put_in(["tools"], %{
      "sandbox" => %{
        "tools" => %{
          "allow" => [
            "group:fs", "group:runtime", "group:sessions", "group:memory",
            "group:web", "group:media", "group:messaging", "group:automation"
          ]
        }
      },
      "media" => %{
        "audio" => %{
          "enabled" => true,
          "echoTranscript" => true,
          "models" => [%{
            "provider" => "openai",
            "model" => audio_model,
            "baseUrl" => proxy_url
          }],
          "request" => %{
            "auth" => %{"mode" => "authorization-bearer", "token" => first_tenant_key}
          }
        },
        "image" => %{
          "enabled" => true,
          "models" => [%{
            "provider" => "openrouter",
            "model" => image_model,
            "baseUrl" => proxy_url
          }],
          "request" => %{
            "auth" => %{"mode" => "authorization-bearer", "token" => first_tenant_key}
          }
        }
      }
    })
  end

  defp build_plugin_entries(instances) do
    proxy_host = Druzhok.Runtime.proxy_host()

    entries = %{
      "openai" => %{"enabled" => true},
      "duckduckgo" => %{"enabled" => true}
    }

    # Perplexity web search via OpenRouter proxy
    entries = Map.put(entries, "perplexity", %{
      "enabled" => true,
      "config" => %{
        "webSearch" => %{
          "baseUrl" => "http://#{proxy_host}:4000/v1",
          "apiKey" => List.first(instances).tenant_key
        }
      }
    })

    if Enum.any?(instances, & &1.dreaming) do
      Map.put(entries, "memory-core", %{
        "enabled" => true,
        "config" => %{
          "dreaming" => %{"enabled" => true}
        }
      })
    else
      entries
    end
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
      # workspace uses the HOST path — mounted at the same path inside the pool container.
      # This way Docker-in-Docker sandbox mounts resolve correctly.
      agent = %{
        "id" => name,
        "model" => "tenant-#{name}/#{instance.model}",
        "workspace" => instance.workspace,
        "sandbox" => %{
          "workspaceRoot" => instance.workspace
        }
      }

      heartbeat = %{}
      heartbeat = if instance.heartbeat_interval && instance.heartbeat_interval > 0,
        do: Map.put(heartbeat, "every", "#{instance.heartbeat_interval}m"),
        else: heartbeat
      heartbeat = if instance.heartbeat_target,
        do: Map.put(heartbeat, "target", instance.heartbeat_target),
        else: heartbeat
      heartbeat = if instance.heartbeat_active_start && instance.heartbeat_active_end,
        do: Map.put(heartbeat, "activeHours", %{"start" => instance.heartbeat_active_start, "end" => instance.heartbeat_active_end}),
        else: heartbeat

      agent = if map_size(heartbeat) > 0,
        do: Map.put(agent, "heartbeat", heartbeat),
        else: agent

      agent = case instance.fallback_models do
        nil -> agent
        "" -> agent
        json ->
          case Jason.decode(json) do
            {:ok, models} when is_list(models) and models != [] ->
              put_in(agent, ["model"], %{
                "default" => "tenant-#{name}/#{instance.model}",
                "fallbacks" => Enum.map(models, &"tenant-#{name}/#{&1}")
              })
            _ -> agent
          end
      end

      agent
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
        "groupPolicy" => "open",
        "streaming" => "partial"
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
          config = %{
            "enabled" => true,
            "groupPolicy" => "open",
            "requireMention" => mention_only
          }
          config = if chat.system_prompt, do: Map.put(config, "systemPrompt", chat.system_prompt), else: config
          {to_string(chat.chat_id), config}
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
    |> Enum.map(fn name -> Regex.escape(name) end)
  end

end
