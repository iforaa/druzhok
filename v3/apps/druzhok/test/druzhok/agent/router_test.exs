defmodule Druzhok.Agent.RouterTest do
  use ExUnit.Case, async: true

  alias Druzhok.Agent.Router

  # --- classify/1 ---

  test "classifies private chat as :dm" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "private", "id" => 100},
        "from" => %{"id" => 123, "first_name" => "Alice"}
      }
    }

    assert {:dm, msg} = Router.classify(update)
    assert msg["from"]["id"] == 123
  end

  test "classifies group chat" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "group", "id" => -100, "title" => "Test Group"},
        "from" => %{"id" => 456, "first_name" => "Bob"}
      }
    }

    assert {:group, _msg, "Test Group"} = Router.classify(update)
  end

  test "classifies supergroup chat" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "supergroup", "id" => -200, "title" => "Super"},
        "from" => %{"id" => 789, "first_name" => "Carol"}
      }
    }

    assert {:group, _, "Super"} = Router.classify(update)
  end

  test "ignores bot messages" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "private", "id" => 100},
        "from" => %{"id" => 999, "is_bot" => true, "first_name" => "BotUser"}
      }
    }

    assert Router.classify(update) == :ignore
  end

  test "ignores updates without message" do
    assert Router.classify(%{"callback_query" => %{}}) == :ignore
    assert Router.classify(%{}) == :ignore
  end

  # --- extract_text/1 ---

  test "extracts text from message" do
    assert Router.extract_text(%{"text" => "hello"}) == "hello"
  end

  test "extracts caption as text" do
    assert Router.extract_text(%{"caption" => "photo caption"}) == "photo caption"
  end

  test "returns empty string when no text or caption" do
    assert Router.extract_text(%{}) == ""
  end

  test "prefers text over caption" do
    assert Router.extract_text(%{"text" => "txt", "caption" => "cap"}) == "txt"
  end

  # --- extract_file/1 ---

  test "extracts document file" do
    msg = %{"document" => %{"file_id" => "abc", "file_name" => "doc.pdf"}}
    assert Router.extract_file(msg) == %{file_id: "abc", name: "doc.pdf"}
  end

  test "extracts photo file (last element)" do
    msg = %{"photo" => [%{"file_id" => "sm"}, %{"file_id" => "lg"}]}
    assert Router.extract_file(msg) == %{file_id: "lg", name: "photo.jpg"}
  end

  test "extracts voice file" do
    msg = %{"voice" => %{"file_id" => "v1"}}
    assert Router.extract_file(msg) == %{file_id: "v1", name: "voice.ogg"}
  end

  test "extracts audio file" do
    msg = %{"audio" => %{"file_id" => "a1", "file_name" => "song.mp3"}}
    assert Router.extract_file(msg) == %{file_id: "a1", name: "song.mp3"}
  end

  test "extracts sticker file" do
    msg = %{"sticker" => %{"file_id" => "s1"}}
    assert Router.extract_file(msg) == %{file_id: "s1", name: "sticker.webp"}
  end

  test "returns nil for plain text message" do
    assert Router.extract_file(%{"text" => "hello"}) == nil
  end

  # --- extract_message/1 ---

  test "extract_message returns structured tuple" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "private", "id" => 42},
        "from" => %{"id" => 7, "first_name" => "Alice", "last_name" => "Smith"},
        "text" => "hi"
      }
    }

    assert {42, "private", "hi", 7, "Alice Smith", nil, nil} = Router.extract_message(update)
  end

  test "extract_message returns nil for bot messages" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "private", "id" => 42},
        "from" => %{"id" => 7, "is_bot" => true, "first_name" => "Bot"},
        "text" => "hi"
      }
    }

    assert Router.extract_message(update) == nil
  end

  test "extract_message includes file info" do
    update = %{
      "message" => %{
        "chat" => %{"type" => "private", "id" => 42},
        "from" => %{"id" => 7, "first_name" => "Alice"},
        "document" => %{"file_id" => "f1", "file_name" => "test.txt"}
      }
    }

    {42, "private", "", 7, "Alice", %{file_id: "f1", name: "test.txt"}, nil} =
      Router.extract_message(update)
  end

  # --- triggered?/3 ---

  test "detects bot mention trigger" do
    assert Router.triggered?("@mybot hello", "mybot", nil)
  end

  test "detects bot mention case-insensitive" do
    assert Router.triggered?("Hey @MyBot!", "mybot", nil)
  end

  test "detects name regex trigger" do
    regex = ~r/друг/iu
    assert Router.triggered?("привет друг", nil, regex)
  end

  test "returns false when not triggered" do
    refute Router.triggered?("random message", "mybot", nil)
  end

  test "returns false with nil username and nil regex" do
    refute Router.triggered?("anything", nil, nil)
  end

  # --- reply_to_bot?/2 ---

  test "detects reply to bot" do
    update = %{
      "message" => %{
        "reply_to_message" => %{"from" => %{"id" => 42}}
      }
    }

    assert Router.reply_to_bot?(update, 42)
  end

  test "returns false for reply to someone else" do
    update = %{
      "message" => %{
        "reply_to_message" => %{"from" => %{"id" => 99}}
      }
    }

    refute Router.reply_to_bot?(update, 42)
  end

  test "returns false when no reply" do
    refute Router.reply_to_bot?(%{"message" => %{}}, 42)
  end

  # --- parse_command/1 ---

  test "parses /start command" do
    assert Router.parse_command("/start") == {:command, "start"}
    assert Router.parse_command("/start@mybot") == {:command, "start"}
  end

  test "parses /reset command" do
    assert Router.parse_command("/reset") == {:command, "reset"}
  end

  test "parses /abort command" do
    assert Router.parse_command("/abort") == {:command, "abort"}
  end

  test "unknown command returns :text" do
    assert Router.parse_command("/unknown") == :text
  end

  test "regular text returns :text" do
    assert Router.parse_command("hello world") == :text
  end
end
