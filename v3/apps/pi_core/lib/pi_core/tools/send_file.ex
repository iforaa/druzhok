defmodule PiCore.Tools.SendFile do
  alias PiCore.Tools.Tool

  def new(_opts \\ %{}) do
    %Tool{
      name: "send_file",
      description: "Send a file to the user via Telegram. The file must exist in the workspace. Use this after creating a file (PDF, image, document, archive, etc.) that the user requested.",
      parameters: %{
        path: %{type: :string, description: "Path to the file to send (relative to workspace or absolute)"},
        caption: %{type: :string, description: "Optional caption for the file", required: false}
      },
      execute: fn args, context -> execute(args, context) end
    }
  end

  def execute(%{"path" => path} = args, context) do
    workspace = context[:workspace]
    send_file_fn = context[:send_file_fn]

    unless send_file_fn do
      {:error, "File sending not available"}
    else
      # Resolve path relative to workspace
      full_path = if Path.type(path) == :absolute do
        path
      else
        Path.join(workspace, path)
      end
      |> Path.expand()

      # Security: must be within workspace
      workspace_abs = Path.expand(workspace)
      unless String.starts_with?(full_path, workspace_abs) do
        {:error, "Path must be within workspace"}
      else
        if File.exists?(full_path) do
          caption = args["caption"]
          case send_file_fn.(full_path, caption) do
            :ok -> {:ok, "File sent: #{Path.basename(full_path)}"}
            {:ok, _} -> {:ok, "File sent: #{Path.basename(full_path)}"}
            {:error, reason} -> {:error, "Failed to send file: #{inspect(reason)}"}
          end
        else
          {:error, "File not found: #{path}"}
        end
      end
    end
  end

  def execute(_, _), do: {:error, "Missing required parameter: path"}
end
