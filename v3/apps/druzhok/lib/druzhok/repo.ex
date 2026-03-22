defmodule Druzhok.Repo do
  use Ecto.Repo,
    otp_app: :druzhok,
    adapter: Ecto.Adapters.SQLite3
end
