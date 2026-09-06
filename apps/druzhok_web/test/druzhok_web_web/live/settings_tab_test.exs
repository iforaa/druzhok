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

  test "the memory card switches the provider; an inactive bot is not started", %{conn: conn} do
    inst = create_instance(%{active: false, ruoc_account_id: "acct-77", ruoc_api_key: "ruoc_bot77", model: "ruoc-flash", memory_provider: "builtin"})
    {:ok, view, _} = live(conn, "/instances/#{inst.name}")

    html = render(view)
    assert html =~ "Memory provider"
    assert html =~ ~s(<option value="builtin" selected)
    assert html =~ ~s(<option value="mnemosyne")

    view |> element("form[phx-change=set_memory_provider]") |> render_change(%{"memory_provider" => "mnemosyne"})
    assert Repo.get_by!(Instance, name: inst.name).memory_provider == "mnemosyne"
    Process.sleep(100)
    refute Repo.get_by!(Instance, name: inst.name).active

    view |> element("form[phx-change=set_memory_provider]") |> render_change(%{"memory_provider" => "builtin"})
    assert Repo.get_by!(Instance, name: inst.name).memory_provider == "builtin"
    stop(view)
  end

  test "a migrated bot shows its ruoc balance, console link and priced catalog", %{conn: conn} do
    inst = create_instance(%{active: false, ruoc_account_id: "acct-77", ruoc_api_key: "ruoc_bot77", model: "ruoc-flash"})

    {:ok, view, _} = live(conn, "/instances/#{inst.name}")
    html = render(view)

    assert html =~ "Balance (ruoc)"
    assert html =~ "12.50 ₽"
    assert html =~ "No plan"
    assert html =~ "https://admin.test/#/requests/acct-77"
    assert html =~ "GLM 5.3 Flash (12/38 ₽/M)"
    assert html =~ "GLM 5.3 (210/660 ₽/M)"
    refute html =~ "Migrate to ruoc"
    refute html =~ "Daily budget"
    stop(view)
  end

  test "a subscribed bot shows its plan and renewal date", %{conn: conn, stub: stub} do
    Bypass.stub(stub.bypass, "GET", "/v1/balance", fn conn ->
      Druzhok.RuocStub.reply(conn, 200, %{
        "balance_nanorub" => 42_000_000_000, "balance_rub" => "42 RUB",
        "subscription" => %{"plan_name" => "Старт", "credit_nanorub" => 50_000_000_000, "period_days" => 30,
                            "status" => "active", "current_period_end" => "2026-10-05T12:00:00+05:00"}
      })
    end)
    inst = create_instance(%{active: false, ruoc_account_id: "acct-78", ruoc_api_key: "ruoc_bot78", model: "ruoc-flash"})

    {:ok, view, _} = live(conn, "/instances/#{inst.name}")
    html = render(view)
    assert html =~ "Plan: Старт, 50.00 ₽ / 30 d"
    assert html =~ "renews"
    assert html =~ "2026-10-05"
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

  test "the image picker comes from ruoc and changing the model does not restart the bot", %{conn: conn, stub: stub} do
    inst = create_instance(%{active: false, ruoc_api_key: "ruoc_img", image_gen_enabled: true})
    {:ok, view, _} = live(conn, "/instances/#{inst.name}")
    html = render(view)

    assert html =~ "ruoc default"
    assert html =~ "FLUX 2 Klein · 2 ₽/image"
    assert html =~ "FLUX 2 Pro · 5 ₽/image"
    refute html =~ "flux.2-klein-4b"

    view |> element("form[phx-change=set_image_gen_model]") |> render_change(%{"image_gen_model" => "ruoc-flux-pro"})
    assert Repo.get_by!(Instance, name: inst.name).image_gen_model == "ruoc-flux-pro"
    # The bot was created inactive and stays that way: no restart was issued.
    Process.sleep(100)
    refute Repo.get_by!(Instance, name: inst.name).active

    view |> element("form[phx-change=set_image_gen_model]") |> render_change(%{"image_gen_model" => ""})
    assert Repo.get_by!(Instance, name: inst.name).image_gen_model == nil

    Bypass.down(stub.bypass)
    send(view.pid, :settings_updated)
    assert render(view) =~ "ruoc catalogue unavailable"
    stop(view)
  end
end
