# On the OLD host:  mix run --no-start ops/export_instances.exs > instances.json
Application.ensure_all_started(:druzhok)

fields = Druzhok.Instance.__schema__(:fields) -- [:id, :inserted_at, :updated_at]

rows =
  Druzhok.InstanceManager.list()
  |> Enum.map(fn i -> i |> Map.from_struct() |> Map.take(fields) |> Map.put(:bot_runtime, "hermes") end)

IO.puts(Jason.encode!(rows, pretty: true))
