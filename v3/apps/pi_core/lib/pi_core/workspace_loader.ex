defmodule PiCore.WorkspaceLoader do
  @callback load(workspace :: String.t(), opts :: map()) :: String.t()
end

defmodule PiCore.WorkspaceLoader.Default do
  @behaviour PiCore.WorkspaceLoader

  @files ["AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md"]

  def load(workspace, opts) do
    files = if opts[:group], do: @files -- ["USER.md"], else: @files
    read_fn = opts[:read_fn] || (&File.read/1)

    files
    |> Enum.map(fn file ->
      path = if read_fn == (&File.read/1), do: Path.join(workspace, file), else: "/workspace/#{file}"
      case read_fn.(path) do
        {:ok, content} -> content
        {:error, _} -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> case do
      "" -> "You are a helpful AI assistant."
      prompt -> prompt
    end
  end
end
