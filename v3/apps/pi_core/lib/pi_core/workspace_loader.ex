defmodule PiCore.WorkspaceLoader do
  @callback load(workspace :: String.t(), opts :: map()) :: String.t()
end

defmodule PiCore.WorkspaceLoader.Default do
  @behaviour PiCore.WorkspaceLoader

  @files ["AGENTS.md", "SOUL.md", "IDENTITY.md", "USER.md", "BOOTSTRAP.md"]

  def load(workspace, _opts) do
    @files
    |> Enum.map(fn file ->
      path = Path.join(workspace, file)
      case File.read(path) do
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
