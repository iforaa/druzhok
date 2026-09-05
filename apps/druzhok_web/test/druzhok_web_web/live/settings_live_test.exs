defmodule DruzhokWebWeb.SettingsLiveTest do
  use DruzhokWebWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Druzhok.Settings

  setup %{conn: conn} do
    %{conn: conn, user: user} = log_in_user(conn)
    {:ok, admin} = user |> Ecto.Changeset.change(role: "admin") |> Druzhok.Repo.update()
    %{conn: conn, user: admin}
  end

  test "non-admins are sent back to the dashboard" do
    %{conn: conn} = log_in_user(Phoenix.ConnTest.build_conn(), %{email: "plain@example.com"})
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/settings")
  end

  test "renders the ruoc card with the stored values and masks secrets", %{conn: conn} do
    Settings.set("ruoc_admin_host", "admin.example")
    Settings.set("ruoc_admin_token", "supersecrettoken")

    {:ok, _view, html} = live(conn, "/settings")

    assert html =~ "ruoc-gateway (chat, search, voice)"
    assert html =~ "admin.example"
    assert html =~ "http://127.0.0.1:8787"
    refute html =~ "supersecrettoken"
  end

  test "save writes the ruoc settings and leaves a masked secret untouched", %{conn: conn} do
    Settings.set("ruoc_admin_token", "keepme")
    {:ok, view, _html} = live(conn, "/settings")

    masked = view |> element("input[name=ruoc_admin_token]") |> render() |> Floki.parse_fragment!() |> Floki.attribute("value") |> List.first()
    assert masked != "keepme"

    html =
      render_submit(view, "save", %{
        "ruoc_url" => "http://127.0.0.1:9999",
        "ruoc_admin_host" => "admin.test",
        "ruoc_admin_token" => masked,
        "ruoc_catalog_key" => "ruoc_catalogkey",
        "openrouter_api_key" => "",
        "openai_api_key" => "",
        "manager_bot_token" => ""
      })

    assert html =~ "Saved"
    assert Settings.get("ruoc_url") == "http://127.0.0.1:9999"
    assert Settings.get("ruoc_admin_host") == "admin.test"
    assert Settings.get("ruoc_admin_token") == "keepme"
    assert Settings.get("ruoc_catalog_key") == "ruoc_catalogkey"
    assert Settings.get("openrouter_api_key") == nil
    GenServer.stop(view.pid, :normal, 5_000)
  end
end
