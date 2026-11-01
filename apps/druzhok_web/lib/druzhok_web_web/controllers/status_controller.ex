defmodule DruzhokWebWeb.StatusController do
  @moduledoc """
  `GET /internal/status`: this machine and its bots, for the operator's CleoHub
  console in ruoc-gateway (`Druzhok.Status`).
  """

  use DruzhokWebWeb, :controller

  def show(conn, _params) do
    case Druzhok.Status.get() do
      {:ok, status} -> json(conn, status)
      {:error, _} -> conn |> put_status(503) |> json(%{error: "status_unavailable"})
    end
  end
end
