defmodule PiCore.Native.Readability do
  use Rustler, otp_app: :pi_core, crate: "readability"

  @doc "Extract readable content from HTML. Returns {:ok, %{title, text, excerpt}} or {:error, reason}."
  def extract(_html), do: :erlang.nif_error(:nif_not_loaded)

  @doc "Strip all HTML tags, returning plain text. Fallback when Readability fails."
  def strip_tags(_html), do: :erlang.nif_error(:nif_not_loaded)
end
