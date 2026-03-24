defmodule PiCore.TranscriptionTest do
  use ExUnit.Case

  test "transcribe returns text from LLM response" do
    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{content: "Hello world", tool_calls: [], reasoning: ""}}
    end

    audio_bytes = <<0, 1, 2, 3>>
    result = PiCore.Transcription.transcribe(audio_bytes, format: "ogg", llm_fn: mock_llm)
    assert {:ok, "Hello world"} = result
  end

  test "transcribe returns error when LLM fails" do
    mock_llm = fn _opts -> {:error, "API error"} end

    audio_bytes = <<0, 1, 2, 3>>
    result = PiCore.Transcription.transcribe(audio_bytes, format: "ogg", llm_fn: mock_llm)
    assert {:error, _} = result
  end

  test "transcribe returns error for empty transcription" do
    mock_llm = fn _opts ->
      {:ok, %PiCore.LLM.Client.Result{content: "", tool_calls: [], reasoning: ""}}
    end

    audio_bytes = <<0, 1, 2, 3>>
    result = PiCore.Transcription.transcribe(audio_bytes, format: "ogg", llm_fn: mock_llm)
    assert {:error, "Empty transcription"} = result
  end

  test "build_request creates correct message structure" do
    audio_bytes = <<0, 1, 2, 3>>
    request = PiCore.Transcription.build_request(audio_bytes, "ogg")

    assert length(request.messages) == 1
    [msg] = request.messages
    assert msg.role == "user"
    assert is_list(msg.content)

    audio_part = Enum.find(msg.content, & &1["type"] == "input_audio")
    assert audio_part != nil
    assert audio_part["input_audio"]["format"] == "ogg"
    assert audio_part["input_audio"]["data"] == Base.encode64(audio_bytes)

    text_part = Enum.find(msg.content, & &1["type"] == "text")
    assert text_part != nil
  end
end
