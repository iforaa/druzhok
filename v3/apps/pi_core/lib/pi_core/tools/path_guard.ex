defmodule PiCore.Tools.PathGuard do
  @doc """
  Resolve a workspace-relative path and verify it doesn't escape the workspace.
  Returns {:ok, absolute_path} or {:error, reason}.
  """
  def resolve(workspace, relative_path) do
    full_path = Path.join(workspace, relative_path) |> Path.expand()
    workspace_abs = Path.expand(workspace)

    if String.starts_with?(full_path, workspace_abs <> "/") or full_path == workspace_abs do
      {:ok, full_path}
    else
      {:error, "Access denied: path outside workspace"}
    end
  end

  def sandbox_path("/" <> _ = path), do: path
  def sandbox_path(path), do: "/workspace/#{path}"
end
