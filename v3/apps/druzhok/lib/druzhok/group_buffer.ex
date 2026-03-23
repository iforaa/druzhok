defmodule Druzhok.GroupBuffer do
  @moduledoc """
  ETS-backed buffer for non-triggered group chat messages.
  Messages are stored per {instance_name, chat_id} and flushed
  as context when the bot is triggered.
  """

  @table :druzhok_group_buffer

  def push(instance_name, chat_id, message, max_size) do
    key = {instance_name, chat_id}
    existing = case :ets.lookup(@table, key) do
      [{^key, msgs}] -> msgs
      [] -> []
    end

    updated = existing ++ [message]
    trimmed = if length(updated) > max_size do
      Enum.drop(updated, length(updated) - max_size)
    else
      updated
    end

    :ets.insert(@table, {key, trimmed})
    :ok
  end

  def flush(instance_name, chat_id) do
    key = {instance_name, chat_id}
    case :ets.lookup(@table, key) do
      [{^key, msgs}] ->
        :ets.delete(@table, key)
        msgs
      [] -> []
    end
  end

  def clear(instance_name, chat_id) do
    :ets.delete(@table, {instance_name, chat_id})
    :ok
  end

  def size(instance_name, chat_id) do
    case :ets.lookup(@table, {instance_name, chat_id}) do
      [{_, msgs}] -> length(msgs)
      [] -> 0
    end
  end

  def format_context([], current_message), do: current_message
  def format_context(buffered_messages, current_message) do
    history = Enum.map_join(buffered_messages, "\n", fn msg ->
      base = "[#{msg.sender}]: #{msg.text}"
      if msg.file, do: base <> "\n[attached: #{msg.file}]", else: base
    end)

    """
    [Сообщения в чате с момента твоего последнего ответа — для контекста]
    #{history}

    [Текущее сообщение — ответь на него]
    #{current_message}\
    """
  end
end
