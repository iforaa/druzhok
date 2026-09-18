defmodule Druzhok.Admissions do
  @moduledoc """
  Who may create a bot. The superbot is invite-only: a person gets in with a
  code, ruoc-gateway redeems it when the bot's account is created, and this
  table remembers that they got in. Permanent on purpose — a person who
  deletes their bot and makes a new one is not asked for a second code.

  The operator is admitted by rule, not by row; `ManagerBot` checks that.
  """

  import Ecto.Query
  alias Druzhok.Repo

  @doc "True when `telegram_id` has been admitted before."
  def admitted?(nil), do: false

  def admitted?(telegram_id) when is_integer(telegram_id) do
    Repo.exists?(from(a in "admissions", where: a.telegram_id == ^telegram_id))
  end

  @doc """
  Record the admission. `hint` is the first characters of the code that let
  them in (or a word like "grandfathered"), for the operator's eyes only.
  Idempotent: a second call for the same person changes nothing.
  """
  def admit(telegram_id, hint) when is_integer(telegram_id) and is_binary(hint) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.insert_all(
      "admissions",
      [%{telegram_id: telegram_id, invite_hint: String.slice(hint, 0, 8), admitted_at: now}],
      on_conflict: :nothing,
      conflict_target: [:telegram_id]
    )

    :ok
  end
end
