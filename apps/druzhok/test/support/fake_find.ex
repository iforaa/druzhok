defmodule Druzhok.FakeFind do
  @moduledoc """
  Stands in for GNU find in tests (`:panel_lister`), since macOS's find has
  no `-printf`: the same `%y %s %P\\0` records, symlinks reported as `l` and
  never followed, dot and `_` entries pruned.
  """

  def list(_name, tenant_dir, root, depth) do
    base = Path.expand(Path.join([tenant_dir, "workspace", root]))
    base |> walk("", depth) |> IO.iodata_to_binary()
  end

  defp walk(_dir, _rel, 0), do: []

  defp walk(dir, rel, depth) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- Enum.sort(names), not String.starts_with?(name, [".", "_"]) do
          path = Path.join(dir, name)
          relp = if rel == "", do: name, else: Path.join(rel, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :directory, size: s}} ->
              ["d #{s} #{relp}\0" | walk(path, relp, depth - 1)]

            {:ok, %File.Stat{type: :regular, size: s}} ->
              "f #{s} #{relp}\0"

            {:ok, %File.Stat{type: :symlink}} ->
              "l 1 #{relp}\0"

            _ ->
              []
          end
        end

      _ ->
        []
    end
  end
end
