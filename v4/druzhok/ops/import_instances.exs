# On the NEW host:
#   DATABASE_PATH=/data/druzhok/druzhok.db MIX_ENV=prod mix run --no-start ops/import_instances.exs instances.json
Application.ensure_all_started(:druzhok)
[path] = System.argv()

for attrs <- path |> File.read!() |> Jason.decode!() do
  name = attrs["name"]

  attrs =
    attrs
    |> Map.put("workspace", Path.join([Druzhok.BotManager.data_root_base(), name, "workspace"]))
    |> Map.put("active", false)

  case Druzhok.Repo.get_by(Druzhok.Instance, name: name) do
    nil ->
      %Druzhok.Instance{} |> Druzhok.Instance.changeset(attrs) |> Druzhok.Repo.insert!()
      IO.puts("imported #{name}")

    _ ->
      IO.puts("skip existing #{name}")
  end
end
