defmodule Druzhok.BotSettingsTest do
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import ExUnit.CaptureIO
  alias Druzhok.{BotSettings, CLI, Instance, Repo, Settings}

  defp reload(inst), do: Repo.get!(Instance, inst.id)

  describe "update/2" do
    test "a restart field restarts a running bot" do
      inst = relay_instance(%{active: true, mention_only: false})
      assert {:ok, _, true} = BotSettings.update(inst.name, %{"mention_only" => "true"})
      row = reload(inst)
      assert row.mention_only
      assert row.start_seq == inst.start_seq + 1
    end

    test "a stopped bot is not started, an unchanged value and a live field restart nothing" do
      stopped = relay_instance(%{active: false})
      assert {:ok, _, false} = BotSettings.update(stopped.name, %{trigger_name: "Вася"})
      refute reload(stopped).active
      assert reload(stopped).start_seq == 0

      running = relay_instance(%{active: true, mention_only: true})

      assert {:ok, _, false} =
               BotSettings.update(running.name, %{mention_only: true, sleep_enabled: true})

      assert reload(running).sleep_enabled
      assert reload(running).start_seq == 0
    end

    test "strings are parsed by field type, blank is nil" do
      inst = relay_instance(%{trigger_name: "x", owner_telegram_id: 1})

      assert {:ok, _, _} =
               BotSettings.update(inst.name, %{
                 "trigger_name" => " ",
                 "owner_telegram_id" => "42",
                 "image_gen_enabled" => "on"
               })

      row = reload(inst)
      assert row.trigger_name == nil
      assert row.owner_telegram_id == 42
      assert row.image_gen_enabled
    end

    test "unknown fields, bad values and unknown bots are refused" do
      inst = relay_instance()

      assert {:error, {:unknown_field, "api_key"}} =
               BotSettings.update(inst.name, %{"api_key" => "x"})

      assert {:error, {:not_boolean, :mention_only, "maybe"}} =
               BotSettings.update(inst.name, %{"mention_only" => "maybe"})

      assert {:error, {:unknown_memory_provider, "x"}} =
               BotSettings.update(inst.name, %{"memory_provider" => "x"})

      assert {:error, :not_found} = BotSettings.update("nobody", %{mention_only: true})
    end
  end

  describe "CLI" do
    test "show masks the token" do
      inst = relay_instance(%{telegram_token: "123456:ABCDEFGHIJ"})
      out = capture_io(fn -> assert CLI.main(["show", inst.name]) == 0 end)
      assert out =~ ~r/telegram_token\s+\*\*\*\*GHIJ/
      refute out =~ "ABCDEF"
    end

    test "set saves, reads '-' from stdin and reports errors with status 1" do
      inst = relay_instance()

      assert capture_io("sekret-token\n", fn ->
               assert CLI.main(["set", inst.name, "telegram_token=-", "sleep_enabled=true"]) == 0
             end) =~ "saved"

      assert reload(inst).telegram_token == "sekret-token"
      assert reload(inst).sleep_enabled

      err = capture_io(:stderr, fn -> assert CLI.main(["set", inst.name, "nope=1"]) == 1 end)
      assert err =~ "unknown field nope"

      assert capture_io(:stderr, fn -> assert CLI.main(["set", inst.name, "novalue"]) == 1 end) =~
               "key=value"

      assert capture_io(:stderr, fn -> assert CLI.main(["show", "nobody"]) == 1 end) =~
               "no such bot"

      assert capture_io(:stderr, fn -> assert CLI.main(["frobnicate"]) == 1 end) =~
               "unknown command"
    end

    test "global settings: secrets masked, unknown keys refused" do
      on_exit(fn ->
        import Ecto.Query
        Repo.delete_all(from(s in Settings, where: s.key in ["fetch_secret", "sleep_idle_minutes"]))
      end)

      Settings.set("fetch_secret", "abcdefghijklmn")
      Settings.set("sleep_idle_minutes", "30")
      out = capture_io(fn -> assert CLI.main(["settings"]) == 0 end)
      assert out =~ ~r/fetch_secret\s+\*\*\*\*klmn/
      assert out =~ ~r/sleep_idle_minutes\s+30/

      assert capture_io(fn ->
               assert CLI.main(["settings", "set", "sleep_idle_minutes=45"]) == 0
             end) =~ "saved"

      assert Settings.get("sleep_idle_minutes") == "45"

      assert capture_io(:stderr, fn -> assert CLI.main(["settings", "set", "bogus=1"]) == 1 end) =~
               "unknown setting bogus"
    end

    test "help lists the commands" do
      assert capture_io(fn -> assert CLI.main(["help"]) == 0 end) =~ "set <bot> key=value"
    end
  end
end
