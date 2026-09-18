defmodule DruzhokWebWeb.LiveAuth do
  @moduledoc """
  `on_mount` guards for the protected LiveViews.

  The router's `:auth` / `:admin` plugs only run on the initial HTTP request.
  Live navigation re-mounts over the open websocket with the session of that
  first request and skips every plug, so each `live_session` in the router
  carries one of these hooks. They also assign `:current_user`.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  def on_mount(:require_user, _params, session, socket) do
    case current_user(session) do
      nil -> {:halt, redirect(socket, to: "/login")}
      user -> {:cont, assign(socket, :current_user, user)}
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    case current_user(session) do
      nil -> {:halt, redirect(socket, to: "/login")}
      %{role: "admin"} = user -> {:cont, assign(socket, :current_user, user)}
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  defp current_user(%{"user_id" => id}) when not is_nil(id), do: Druzhok.Repo.get(Druzhok.User, id)
  defp current_user(_session), do: nil
end
