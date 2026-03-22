defmodule PiCore.LLM.SSEParserTest do
  use ExUnit.Case

  alias PiCore.LLM.SSEParser

  test "parses single data line" do
    {events, rest} = SSEParser.parse("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n", "")
    assert length(events) == 1
    assert hd(events)["choices"] |> hd() |> get_in(["delta", "content"]) == "hi"
  end

  test "parses multiple events" do
    input = "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n"
    {events, _rest} = SSEParser.parse(input, "")
    assert length(events) == 2
  end

  test "handles [DONE]" do
    {events, _rest} = SSEParser.parse("data: [DONE]\n\n", "")
    assert events == [:done]
  end

  test "handles partial data across chunks" do
    {events1, rest} = SSEParser.parse("data: {\"ch", "")
    assert events1 == []
    {events2, _rest} = SSEParser.parse("oices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", rest)
    assert length(events2) == 1
  end

  test "ignores non-data lines" do
    {events, _rest} = SSEParser.parse("event: message\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", "")
    assert length(events) == 1
  end

  test "handles reasoning_content" do
    input = "data: {\"choices\":[{\"delta\":{\"content\":\"\",\"reasoning_content\":\"thinking...\"}}]}\n\n"
    {events, _rest} = SSEParser.parse(input, "")
    assert length(events) == 1
    delta = hd(events)["choices"] |> hd() |> Map.get("delta")
    assert delta["reasoning_content"] == "thinking..."
  end
end
