defmodule PiCore.Tools.GenerateImage do
  alias PiCore.Tools.Tool

  @default_model "google/gemini-2.5-flash-image"

  def new(opts \\ []) do
    %Tool{
      name: "generate_image",
      description: "Generate an image from a text description. The image will be sent to the user in the chat.",
      parameters: %{
        prompt: %{type: :string, description: "Description of the image to generate"}
      },
      execute: fn args, context -> execute(args, context, opts) end
    }
  end

  def execute(%{"prompt" => prompt}, context, opts) do
    send_photo_fn = context[:send_photo_fn]

    unless send_photo_fn do
      {:error, "Image sending not available"}
    else
      llm_fn = Keyword.get(opts, :llm_fn) || build_default_llm_fn(opts)

      request = %{
        model: Keyword.get(opts, :model) || @default_model,
        provider: :openrouter,
        api_url: Keyword.get(opts, :api_url) || "https://openrouter.ai/api/v1",
        api_key: Keyword.get(opts, :api_key) || System.get_env("OPENROUTER_API_KEY") || "",
        system_prompt: "You are an image generator. Generate the requested image.",
        messages: [%{role: "user", content: prompt}],
        tools: [],
        max_tokens: 4096,
        stream: false,
        on_delta: nil,
        on_event: nil
      }

      case llm_fn.(request) do
        {:ok, response} ->
          extract_and_send_image(response, send_photo_fn)

        {:error, reason} ->
          {:error, "Image generation failed: #{inspect(reason)}"}
      end
    end
  end

  def execute(_, _, _), do: {:error, "Missing required parameter: prompt"}

  defp extract_and_send_image(response, send_photo_fn) do
    images = get_in(response, ["choices", Access.at(0), "message", "images"]) || []

    case images do
      [%{"image_url" => %{"url" => data_url}} | _] ->
        case PiCore.Multimodal.parse_data_url(data_url) do
          {:ok, _media_type, base64_data} ->
            case Base.decode64(base64_data) do
              {:ok, bytes} ->
                case send_photo_fn.(bytes, nil) do
                  :ok -> {:ok, "Image generated and sent"}
                  {:ok, _} -> {:ok, "Image generated and sent"}
                  {:error, reason} -> {:error, "Failed to send image: #{inspect(reason)}"}
                end
              :error -> {:error, "Invalid base64 in image data"}
            end

          {:error, reason} ->
            {:error, "Failed to decode image: #{reason}"}
        end

      _ ->
        {:error, "No image in response"}
    end
  end

  defp build_default_llm_fn(_opts) do
    fn request ->
      # Use sync (non-streaming) completion and return raw response
      url = "#{String.trim_trailing(request.api_url, "/")}/chat/completions"
      headers = [
        {"content-type", "application/json"},
        {"authorization", "Bearer #{request.api_key}"},
        {"HTTP-Referer", "https://druzhok.app"},
        {"X-Title", "Druzhok"}
      ]
      body = Jason.encode!(%{
        model: request.model,
        messages: [
          %{role: "system", content: request.system_prompt}
          | request.messages
        ],
        max_tokens: request.max_tokens
      })

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PiCore.Finch, receive_timeout: 60_000) do
        {:ok, %{status: status, body: resp}} when status in 200..299 ->
          {:ok, Jason.decode!(resp)}
        {:ok, %{status: status, body: resp}} ->
          {:error, "HTTP #{status}: #{String.slice(resp, 0, 200)}"}
        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
