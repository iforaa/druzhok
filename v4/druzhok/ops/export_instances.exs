# On the OLD host:  mix run --no-start ops/export_instances.exs > instances.json
Application.ensure_all_started(:druzhok)

fields =
  ~w(name telegram_token model workspace active heartbeat_interval owner_telegram_id timezone api_key
     daily_token_limit dream_hour language tenant_key bot_runtime on_demand_model mention_only reject_message
     welcome_message allowed_telegram_ids allowed_telegram_chats allow_all_telegram_users trigger_name image_model
     audio_model embedding_model heartbeat_active_start heartbeat_active_end heartbeat_target fallback_models dreaming
     group_sessions_per_user group_shared_memory website_hosting_enabled daily_budget_cents image_gen_enabled image_gen_model)a

rows =
  Druzhok.InstanceManager.list()
  |> Enum.map(fn i -> i |> Map.from_struct() |> Map.take(fields) |> Map.put(:bot_runtime, "hermes") end)

IO.puts(Jason.encode!(rows, pretty: true))
