defmodule PiCore.Transcription do
  alias PiCore.LLM.Client.Result

  @default_model "google/gemini-2.0-flash-lite-001"
  @system_prompt "You are a transcription assistant. Transcribe the audio to text exactly as spoken. Return only the transcription, nothing else. If the audio is in Russian, transcribe in Russian. If in English, transcribe in English."

  def transcribe(audio_bytes, opts \\ []) do
    format = Keyword.get(opts, :format, "ogg")
    request = build_request(audio_bytes, format)

    llm_fn = Keyword.get(opts, :llm_fn) || build_default_llm_fn(opts)

    case llm_fn.(request) do
      {:ok, %Result{content: content}} when is_binary(content) and content != "" ->
        {:ok, String.trim(content)}

      {:ok, %Result{}} ->
        {:error, "Empty transcription"}

      {:error, reason} ->
        {:error, "Transcription failed: #{inspect(reason)}"}
    end
  end

  def build_request(audio_bytes, format) do
    base64_audio = Base.encode64(audio_bytes)

    %{
      system_prompt: @system_prompt,
      messages: [
        %{
          role: "user",
          content: [
            %{"type" => "input_audio", "input_audio" => %{"data" => base64_audio, "format" => format}},
            %{"type" => "text", "text" => "Transcribe this audio."}
          ]
        }
      ],
      tools: [],
      max_tokens: 4096,
      stream: false,
      on_delta: nil,
      on_event: nil
    }
  end

  defp build_default_llm_fn(opts) do
    model = Keyword.get(opts, :model, @default_model)
    api_url = Keyword.get(opts, :api_url)
    api_key = Keyword.get(opts, :api_key)

    fn request ->
      PiCore.LLM.OpenAI.completion(Map.merge(request, %{
        model: model,
        provider: :openrouter,
        api_url: api_url,
        api_key: api_key
      }))
    end
  end
end
