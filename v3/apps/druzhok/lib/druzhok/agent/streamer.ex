defmodule Druzhok.Agent.Streamer do
  @moduledoc """
  Pure state machine for streaming response accumulation and throttling.
  Tracks accumulated text, sent message ID, and edit timing — no I/O.
  """

  defstruct text: "",
            message_id: nil,
            last_edit_at: nil,
            min_chars: 30,
            edit_interval_ms: 1_000

  @type t :: %__MODULE__{
          text: String.t(),
          message_id: integer() | nil,
          last_edit_at: integer() | nil,
          min_chars: non_neg_integer(),
          edit_interval_ms: non_neg_integer()
        }

  @doc """
  Create a new streamer state.

  Options:
    - `:min_chars` — minimum characters before first send (default 30)
    - `:edit_interval_ms` — minimum ms between edits (default 1000)
  """
  def new(opts \\ []) do
    %__MODULE__{
      min_chars: Keyword.get(opts, :min_chars, 30),
      edit_interval_ms: Keyword.get(opts, :edit_interval_ms, 1_000)
    }
  end

  @doc "Append a text delta to the accumulated buffer."
  def append(%__MODULE__{} = state, delta) when is_binary(delta) do
    %{state | text: state.text <> delta}
  end

  @doc "Get the current accumulated text."
  def text(%__MODULE__{text: text}), do: text

  @doc """
  Check if we have enough characters to send the first message.
  Only meaningful when no message has been sent yet (`message_id` is nil).
  """
  def should_send?(%__MODULE__{message_id: nil, text: text, min_chars: min}) do
    String.length(text) >= min
  end

  def should_send?(%__MODULE__{}), do: false

  @doc """
  Check if enough time has passed since the last edit to send another one.
  Returns `true` if no message has been sent yet (shouldn't normally be called then)
  or if the throttle interval has elapsed.
  """
  def should_edit?(%__MODULE__{last_edit_at: nil}, _now), do: true

  def should_edit?(%__MODULE__{last_edit_at: last, edit_interval_ms: interval}, now) do
    now - last >= interval
  end

  @doc """
  Record that the first message was sent or an edit was made.
  Sets the message_id (if provided) and updates the last_edit_at timestamp.
  """
  def mark_sent(%__MODULE__{} = state, now, message_id \\ nil) do
    state = %{state | last_edit_at: now}

    if message_id do
      %{state | message_id: message_id}
    else
      state
    end
  end

  @doc "Reset the streamer for the next response cycle."
  def reset(%__MODULE__{} = state) do
    %{state | text: "", message_id: nil, last_edit_at: nil}
  end
end
