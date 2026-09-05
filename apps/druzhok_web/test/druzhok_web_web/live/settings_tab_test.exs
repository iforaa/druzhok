defmodule DruzhokWebWeb.SettingsTabTest do
  use DruzhokWebWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import DruzhokWebWeb.ProxyCase, only: [create_instance: 1]

  alias Druzhok.{Instance, Repo}

  setup %{conn: conn} do
    %{conn: conn} = log_in_user(conn)
    stub = Druzhok.RuocStub.start()
    %{conn: conn, stub: stub}
  end

  # The view keeps a refresh timer and reacts to :settings_updated; stop it
  # before the test ends so it cannot hold the shared sandbox connection
  # while the next test's setup runs.
  defp stop(view), do: GenServer.stop(view.pid, :normal, 5_000)

  test "a migrated bot shows its ruoc balance, console link and priced catalog", %{conn: conn} do
    inst = create_instance(%{active: false, ruoc_account_id: "acct-77", ruoc_api_key: "ruoc_bot77", model: "ruoc-flash"})

    {:ok, view, _} = live(conn, "/instances/#{inst.name}")
    html = render(view)

    assert html =~ "Balance (ruoc)"
    assert html =~ "12.50 ₽"
    assert html =~ "https://admin.test/#/requests/acct-77"
    assert html =~ "GLM 5.3 Flash (12/38 ₽/M)"
    assert html =~ "GLM 5.3 (210/660 ₽/M)"
    refute html =~ "Migrate to ruoc"
    refute html =~ "Daily budget"
    stop(view)
  end

  test "an unmigrated bot is flagged and can be migrated from the tab", %{conn: conn, stub: stub} do
    inst = create_instance(%{active: false, ruoc_api_key: nil, model: "z-ai/glm-5.3-flash"})

    {:ok, view, _} = live(conn, "/instances/#{inst.name}")
    html = render(view)
    assert html =~ "Not migrated"
    assert html =~ "Migrate to ruoc"
    assert html =~ "z-ai/glm-5.3-flash (legacy)"

    view |> element("button", "Migrate to ruoc") |> render_click()

    row = Repo.get_by!(Instance, name: inst.name)
    assert row.ruoc_account_id =~ "acct-"
    assert row.model == "ruoc-flash"
    assert [%{params: %{"label" => label}}] = Druzhok.RuocStub.calls(stub, "POST /admin/accounts")
    assert label == "druzhok:#{inst.name}"
    assert render(view) =~ "Balance (ruoc)"
    stop(view)
  end

  test "changing the language saves without touching anything else", %{conn: conn} do
    inst = create_instance(%{active: false, ruoc_api_key: "ruoc_x"})
    {:ok, view, _} = live(conn, "/instances/#{inst.name}")

    view |> element("form[phx-change=settings_changed]") |> render_change(%{"language" => "en"})
    assert Repo.get_by!(Instance, name: inst.name).language == "en"
    stop(view)
  end
end
