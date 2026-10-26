defmodule Druzhok.Panel.SettingsTest do
  @moduledoc "What the panel may change (panel controls spec, «Writable fields»)."
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  alias Druzhok.{BotSettings, Instance, Repo, RuocStub}
  alias Druzhok.Panel.Settings

  setup do
    %{stub: RuocStub.start()}
  end

  defp reload(inst), do: Repo.get!(Instance, inst.id)

  defp refused(inst, changes, type) do
    assert {:error, _status, ^type, _message} = Settings.validate(reload(inst), changes)
  end

  test "each field's accepted values" do
    inst = relay_instance(%{active: true})

    assert {:ok, %{language: "en"}} = Settings.validate(inst, %{"language" => "en"})

    assert {:ok, %{timezone: "Asia/Almaty"}} =
             Settings.validate(inst, %{"timezone" => " Asia/Almaty "})

    assert {:ok, %{timezone: "America/Argentina/Buenos_Aires"}} =
             Settings.validate(inst, %{"timezone" => "America/Argentina/Buenos_Aires"})

    assert {:ok, %{mention_only: true, website_hosting_enabled: true}} =
             Settings.validate(inst, %{"mention_only" => true, "website_hosting_enabled" => true})

    assert {:ok, %{image_gen_enabled: true, image_gen_model: "ruoc-flux-pro"}} =
             Settings.validate(inst, %{
               "image_gen_enabled" => true,
               "image_gen_model" => "ruoc-flux-pro"
             })
  end

  test "refused values" do
    inst = relay_instance()

    refused(inst, %{"language" => "de"}, "invalid_setting")
    refused(inst, %{"timezone" => "Mars/Base"}, "invalid_setting")
    refused(inst, %{"timezone" => "../etc"}, "invalid_setting")
    refused(inst, %{"timezone" => 3}, "invalid_setting")
    refused(inst, %{"mention_only" => "true"}, "invalid_setting")

    refused(
      inst,
      %{"image_gen_enabled" => true, "image_gen_model" => "no-such"},
      "invalid_setting"
    )
  end

  test "every other BotSettings field is refused" do
    inst = relay_instance()

    for field <- BotSettings.fields(), to_string(field) not in Settings.fields() do
      refused(inst, %{to_string(field) => "x"}, "unknown_setting")
    end

    for field <-
          ~w(image_model model telegram_token owner_telegram_id tenant_key delete_requested) do
      refused(inst, %{field => "x"}, "unknown_setting")
    end
  end

  test "a picture model only while pictures are on after this request" do
    off = relay_instance(%{image_gen_enabled: false})
    refused(off, %{"image_gen_model" => "ruoc-flux-pro"}, "images_off")
    refused(off, %{"image_gen_enabled" => false, "image_gen_model" => nil}, "images_off")

    on = relay_instance(%{image_gen_enabled: true, image_gen_model: "ruoc-flux-pro"})
    assert {:ok, %{image_gen_model: nil}} = Settings.validate(on, %{"image_gen_model" => nil})

    refused(
      on,
      %{"image_gen_enabled" => false, "image_gen_model" => "ruoc-flux-pro"},
      "images_off"
    )
  end

  test "an unreachable catalogue refuses a model with 502", %{stub: stub} do
    inst = relay_instance(%{image_gen_enabled: true})
    Bypass.down(stub.bypass)

    assert {:error, 502, "catalogue_unavailable", _} =
             Settings.validate(inst, %{"image_gen_model" => "ruoc-flux-pro"})
  end

  test "unchanged values are dropped; nothing is written for them" do
    inst = relay_instance(%{language: "ru", mention_only: false})
    assert {:ok, %{}} = Settings.validate(inst, %{"language" => "ru", "mention_only" => false})

    assert {:ok, _} = Settings.save(inst, %{"language" => "ru"})
    assert reload(inst).settings_seq == 0
  end

  test "one bad field refuses the whole request" do
    inst = relay_instance(%{language: "ru"})

    assert {:error, 400, "invalid_setting", _} =
             Settings.save(inst, %{"language" => "en", "timezone" => "Nowhere"})

    assert reload(inst).language == "ru"
  end

  test "save writes the fields and leaves the restart to the controller" do
    inst = relay_instance(%{active: true, language: "ru", image_gen_enabled: true})
    assert {:ok, row} = Settings.save(inst, %{"language" => "en"})
    assert row.language == "en"
    assert row.settings_seq == 1
    assert row.start_seq == inst.start_seq
    assert Settings.apply_state(row) == "waiting"

    # A live field alone (the proxy reads the picture model per request).
    assert {:ok, row} = Settings.save(row, %{"image_gen_model" => "ruoc-flux-pro"})
    assert row.settings_seq == 1
  end

  test "apply_state" do
    base = %Instance{settings_seq: 2, settings_applied_seq: 2, active: true, sleeping: false}
    assert Settings.apply_state(base) == "applied"

    pending = %{
      base
      | settings_applied_seq: 1,
        settings_saved_at: ~U[2026-10-26 10:00:00.000000Z]
    }

    assert Settings.apply_state(pending) == "waiting"
    assert Settings.apply_state(%{pending | sleeping: true}) == "on_wake"
    assert Settings.apply_state(%{pending | active: false}) == "on_start"

    assert Settings.apply_state(%{pending | start_failed_at: ~U[2026-10-26 09:00:00.000000Z]}) ==
             "waiting"

    assert Settings.apply_state(%{pending | start_failed_at: ~U[2026-10-26 11:00:00.000000Z]}) ==
             "failed"
  end
end
