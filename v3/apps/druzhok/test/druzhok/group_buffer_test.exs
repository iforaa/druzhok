defmodule Druzhok.GroupBufferTest do
  use ExUnit.Case

  alias Druzhok.GroupBuffer

  setup do
    if :ets.whereis(:druzhok_group_buffer) == :undefined do
      :ets.new(:druzhok_group_buffer, [:set, :public, :named_table])
    end
    GroupBuffer.clear("test_bot", 12345)
    GroupBuffer.clear("test_bot", 99999)
    :ok
  end

  test "push and flush returns messages in order" do
    GroupBuffer.push("test_bot", 12345, %{sender: "Alice", text: "hello", timestamp: 1000, file: nil}, 50)
    GroupBuffer.push("test_bot", 12345, %{sender: "Bob", text: "hi there", timestamp: 2000, file: nil}, 50)
    messages = GroupBuffer.flush("test_bot", 12345)
    assert length(messages) == 2
    assert Enum.at(messages, 0).sender == "Alice"
    assert Enum.at(messages, 1).sender == "Bob"
  end

  test "flush clears the buffer" do
    GroupBuffer.push("test_bot", 12345, %{sender: "Alice", text: "hello", timestamp: 1000, file: nil}, 50)
    _messages = GroupBuffer.flush("test_bot", 12345)
    assert GroupBuffer.flush("test_bot", 12345) == []
    assert GroupBuffer.size("test_bot", 12345) == 0
  end

  test "push trims oldest when over max_size" do
    for i <- 1..10 do
      GroupBuffer.push("test_bot", 12345, %{sender: "User", text: "msg #{i}", timestamp: i, file: nil}, 5)
    end
    assert GroupBuffer.size("test_bot", 12345) == 5
    messages = GroupBuffer.flush("test_bot", 12345)
    assert Enum.at(messages, 0).text == "msg 6"
    assert Enum.at(messages, 4).text == "msg 10"
  end

  test "clear removes all messages" do
    GroupBuffer.push("test_bot", 12345, %{sender: "Alice", text: "hello", timestamp: 1000, file: nil}, 50)
    GroupBuffer.clear("test_bot", 12345)
    assert GroupBuffer.size("test_bot", 12345) == 0
  end

  test "size returns 0 for empty buffer" do
    assert GroupBuffer.size("test_bot", 99999) == 0
  end

  test "different instance_names are isolated" do
    GroupBuffer.push("bot_a", 12345, %{sender: "Alice", text: "from A", timestamp: 1000, file: nil}, 50)
    GroupBuffer.push("bot_b", 12345, %{sender: "Bob", text: "from B", timestamp: 1000, file: nil}, 50)
    a_msgs = GroupBuffer.flush("bot_a", 12345)
    b_msgs = GroupBuffer.flush("bot_b", 12345)
    assert length(a_msgs) == 1
    assert length(b_msgs) == 1
    assert Enum.at(a_msgs, 0).text == "from A"
    assert Enum.at(b_msgs, 0).text == "from B"
  end

  test "format_context builds readable chat log" do
    messages = [
      %{sender: "Иван", text: "привет всем", timestamp: 1000, file: nil},
      %{sender: "Мария", text: "кто идёт?", timestamp: 2000, file: nil},
    ]
    current = "[Мария]: @bot что думаешь?\n[обращение к тебе — ответ обязателен]"
    result = GroupBuffer.format_context(messages, current)
    assert result =~ "Сообщения в чате"
    assert result =~ "[Иван]: привет всем"
    assert result =~ "[Мария]: кто идёт?"
    assert result =~ "Текущее сообщение"
    assert result =~ "@bot что думаешь?"
  end

  test "format_context with empty buffer returns just the current message" do
    result = GroupBuffer.format_context([], "hello")
    assert result == "hello"
  end
end
