defmodule PiCore.Tools.GenerateImageTest do
  use ExUnit.Case

  alias PiCore.Tools.GenerateImage

  test "new/1 creates a tool with correct name and parameters" do
    tool = GenerateImage.new()
    assert tool.name == "generate_image"
    assert Map.has_key?(tool.parameters, :prompt)
  end

  test "execute calls LLM and sends photo on success" do
    # Fake 1x1 white PNG (valid PNG header + minimal data)
    fake_b64 = Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)

    mock_llm = fn _opts ->
      {:ok, %{
        "choices" => [%{
          "message" => %{
            "content" => "Here is your image",
            "images" => [%{
              "type" => "image_url",
              "image_url" => %{"url" => "data:image/png;base64,#{fake_b64}"}
            }]
          }
        }]
      }}
    end

    sent = :ets.new(:test_sent, [:set, :public])
    mock_send_photo = fn bytes, caption ->
      :ets.insert(sent, {:called, bytes, caption})
      :ok
    end

    tool = GenerateImage.new(llm_fn: mock_llm)
    context = %{send_photo_fn: mock_send_photo, workspace: System.tmp_dir!(), chat_id: 123}
    {:ok, result} = tool.execute.(%{"prompt" => "a cat in space"}, context)
    assert result =~ "sent"

    [{:called, bytes, _caption}] = :ets.lookup(sent, :called)
    assert is_binary(bytes)
    :ets.delete(sent)
  end

  test "execute returns error when no send_photo_fn" do
    tool = GenerateImage.new()
    context = %{workspace: System.tmp_dir!()}
    {:error, msg} = tool.execute.(%{"prompt" => "test"}, context)
    assert msg =~ "not available"
  end

  test "execute returns error when LLM fails" do
    mock_llm = fn _opts -> {:error, "API error"} end

    tool = GenerateImage.new(llm_fn: mock_llm)
    context = %{send_photo_fn: fn _, _ -> :ok end, workspace: System.tmp_dir!(), chat_id: 123}
    {:error, msg} = tool.execute.(%{"prompt" => "test"}, context)
    assert msg =~ "failed" or msg =~ "error"
  end

  test "execute returns error when no images in response" do
    mock_llm = fn _opts ->
      {:ok, %{
        "choices" => [%{
          "message" => %{"content" => "I can't generate images", "images" => []}
        }]
      }}
    end

    tool = GenerateImage.new(llm_fn: mock_llm)
    context = %{send_photo_fn: fn _, _ -> :ok end, workspace: System.tmp_dir!(), chat_id: 123}
    {:error, msg} = tool.execute.(%{"prompt" => "test"}, context)
    assert msg =~ "No image"
  end
end
