defmodule Druzhok.SiteLister do
  @moduledoc """
  Enumerate the static sites a bot has published under its workspace.

  Sites live at `<workspace>/sites/<site-name>/` — each subdirectory is
  one site. Returns a list of `%{name, url, size, mtime}` maps suitable
  for rendering in the dashboard.
  """

  @doc """
  Returns a list of sites for the given instance. Empty list when the
  `sites/` directory does not exist or the workspace is not set.
  """
  def list(%{name: _, workspace: nil}), do: []
  def list(%{name: bot_name, workspace: workspace}) do
    sites_dir = Path.join(workspace, "sites")

    do_list(sites_dir, bot_name)
  end

  @doc """
  Absolute host path to a bot's published-sites directory:
  `<data_root_base>/<bot_name>/workspace/sites`. Single source of truth shared
  with the web layer that serves the sites.
  """
  def sites_dir(bot_name) when is_binary(bot_name) do
    Path.join([Druzhok.BotManager.data_root_base(), bot_name, "workspace", "sites"])
  end

  defp do_list(sites_dir, bot_name) do

    case File.ls(sites_dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(sites_dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&to_site_entry(&1, bot_name))

      {:error, _} ->
        []
    end
  end

  defp to_site_entry(site_path, bot_name) do
    name = Path.basename(site_path)

    %{
      name: name,
      url: "https://#{bot_name}.oldey.dev/#{name}/",
      size: directory_size(site_path),
      mtime: directory_mtime(site_path)
    }
  end

  defp directory_size(path) do
    path
    |> walk_files()
    |> Enum.reduce(0, fn file, acc ->
      case File.stat(file) do
        {:ok, %File.Stat{size: s}} -> acc + s
        _ -> acc
      end
    end)
  end

  defp directory_mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: posix}} -> DateTime.from_unix!(posix)
      _ -> DateTime.utc_now()
    end
  end

  defp walk_files(path) do
    cond do
      File.regular?(path) ->
        [path]

      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.flat_map(fn entry -> walk_files(Path.join(path, entry)) end)

      true ->
        []
    end
  end
end
