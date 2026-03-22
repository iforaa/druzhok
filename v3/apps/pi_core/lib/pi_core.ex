defmodule PiCore do
  @moduledoc """
  PiCore - Agent loop library.
  """

  defdelegate start_session(opts), to: PiCore.Session, as: :start_link
  defdelegate prompt(pid, text), to: PiCore.Session
  defdelegate abort(pid), to: PiCore.Session
  defdelegate reset(pid), to: PiCore.Session
end
