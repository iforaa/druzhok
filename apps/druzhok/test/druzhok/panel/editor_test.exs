defmodule Druzhok.Panel.EditorTest do
  # async: false — DRUZHOK_DATA_ROOT and app env.
  use ExUnit.Case, async: false

  import Druzhok.BotFixtures
  import ExUnit.CaptureLog
  alias Druzhok.Panel
  alias Druzhok.Panel.Editor

  # The real script against a real hermes: HERMES_PYTHON, or a hermes-agent
  # clone with its venv at the repo root.
  @python System.get_env("HERMES_PYTHON") ||
            Path.expand("../../../../../hermes-agent/.venv/bin/python", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "editor-#{System.unique_integer([:positive])}")
    prev = System.get_env("DRUZHOK_DATA_ROOT")
    System.put_env("DRUZHOK_DATA_ROOT", root)
    prev_bin = Application.get_env(:druzhok, :hermes_bin)
    Application.put_env(:druzhok, :panel_lister, {Druzhok.FakeFind, :list})

    on_exit(fn ->
      if prev,
        do: System.put_env("DRUZHOK_DATA_ROOT", prev),
        else: System.delete_env("DRUZHOK_DATA_ROOT")

      Application.delete_env(:druzhok, :panel_lister)
      Application.put_env(:druzhok, :hermes_bin, prev_bin)
      File.rm_rf!(root)
    end)

    inst = relay_instance(%{active: false})
    dir = Path.join(root, inst.name)
    File.mkdir_p!(dir)
    %{inst: inst, dir: dir, root: root}
  end

  test "sweep removes left-over hand-over files and nothing else", %{root: root, dir: dir} do
    File.write!(Path.join(root, ".panel-save-abc"), "{}")
    File.write!(Path.join(root, "other"), "x")
    assert :ok = Editor.sweep()
    refute File.exists?(Path.join(root, ".panel-save-abc"))
    assert File.exists?(Path.join(root, "other"))
    assert File.dir?(dir)
  end

  test "check_script: quiet when it matches or none is configured, an error when it differs", %{
    root: root
  } do
    on_exit(fn -> Application.delete_env(:druzhok, :panel_save_script) end)
    assert Editor.check_script() == :ok

    copy = Path.join(root, "panel-save.py")
    File.cp!(Application.app_dir(:druzhok, "priv/panel-save/save.py"), copy)
    Application.put_env(:druzhok, :panel_save_script, copy)
    assert Editor.check_script() == :ok

    File.write!(copy, "old")
    assert capture_log(fn -> assert Editor.check_script() == :stale end) =~ "differs"
    File.rm!(copy)
    assert capture_log(fn -> assert Editor.check_script() == :stale end) =~ "missing"
  end

  test "sweep without a data root does nothing" do
    System.put_env("DRUZHOK_DATA_ROOT", "/nonexistent/editor-test")
    assert :ok = Editor.sweep()
  end

  describe "with the real script" do
    unless File.exists?(@python), do: @describetag(skip: "no hermes python at #{@python}")

    setup do
      Application.put_env(:druzhok, :hermes_bin, Path.join(Path.dirname(@python), "hermes"))
    end

    test "the limits are hermes's own", %{inst: inst, root: root, dir: dir} do
      code = """
      from tools.skill_manager_tool import MAX_SKILL_CONTENT_CHARS as skill
      from agent.prompt_builder import CONTEXT_FILE_MAX_CHARS as soul
      print(skill, soul)
      """

      {out, 0} =
        System.cmd(@python, ["-I", "-c", code], env: [{"HERMES_HOME", Path.join(root, "h")}])

      [skill, soul] = out |> String.split() |> Enum.take(-2) |> Enum.map(&String.to_integer/1)

      File.write!(Path.join(dir, "SOUL.md"), "x")
      assert {:ok, %{limit: ^soul}} = Panel.file(inst, "soul")
      File.mkdir_p!(Path.join(dir, "skills/n"))
      File.write!(Path.join(dir, "skills/n/SKILL.md"), "---\nname: n\n---\nx")
      assert {:ok, %{limit: ^skill}} = Panel.skill(inst, ["n"])
    end

    defp hash(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

    test "a page read, saved and read again", %{inst: inst, dir: dir} do
      assert {:ok, %{sha256: nil, editable: true}} = Panel.file(inst, "memory")

      assert {:ok, %{sha256: sha, modified_at: %DateTime{}}} =
               Editor.save(inst, {:file, "memory"}, "первая запись", nil)

      assert sha == hash("первая запись")
      assert File.read!(Path.join(dir, "memories/MEMORY.md")) == "первая запись"
      assert {:ok, %{text: "первая запись", sha256: ^sha}} = Panel.file(inst, "memory")

      assert {:ok, _} = Editor.save(inst, {:file, "memory"}, "вторая", sha)
      assert File.read!(Path.join(dir, "memories/MEMORY.md.panel-bak")) == "первая запись"

      assert {:error, 409, "file_changed", _, _} =
               Editor.save(inst, {:file, "memory"}, "третья", sha)

      assert File.read!(Path.join(dir, "memories/MEMORY.md")) == "вторая"

      assert File.ls!(Path.dirname(dir)) |> Enum.filter(&String.starts_with?(&1, ".panel-save-")) ==
               []
    end

    test "the limit comes from Runtime.Hermes", %{inst: inst} do
      limit = Druzhok.Runtime.Hermes.memory_limits().user

      assert {:error, 422, "too_long", _, %{limit: ^limit}} =
               Editor.save(inst, {:file, "user"}, String.duplicate("я", limit + 1), nil)

      assert {:ok, _} = Editor.save(inst, {:file, "user"}, String.duplicate("я", limit), nil)
    end

    test "a check's refusal comes through", %{inst: inst, dir: dir} do
      assert {:error, 422, "blocked_entry", _, %{entry: "a" <> _}} =
               Editor.save(inst, {:file, "memory"}, "a‍b", nil)

      File.write!(Path.join(dir, "SOUL.md"), "x")

      assert {:error, 422, "empty_soul", _, _} =
               Editor.save(inst, {:file, "soul"}, "  ", hash("x"))
    end

    test "an own skill saves through the script, with its name kept", %{inst: inst, dir: dir} do
      text = "---\nname: notes\ndescription: x\n---\nтело\n"
      File.mkdir_p!(Path.join(dir, "skills/notes"))
      File.write!(Path.join(dir, "skills/notes/SKILL.md"), text)

      new = String.replace(text, "тело", "новое")
      assert {:ok, _} = Editor.save(inst, {:skill, ["notes"]}, new, hash(text))

      assert {:error, 422, "invalid_skill", _, _} =
               Editor.save(
                 inst,
                 {:skill, ["notes"]},
                 String.replace(new, "name: notes", "name: y"),
                 hash(new)
               )
    end

    test "SOUL.md left by the owner stays through sync_soul", %{inst: inst, dir: dir} do
      alias Druzhok.Runtime.Hermes.Voice
      written = Voice.sync_soul(%{display_name: "Вася"}, dir)
      text = File.read!(Path.join(dir, "SOUL.md"))
      assert {:ok, _} = Editor.save(inst, {:file, "soul"}, "моё", hash(text))
      assert Voice.sync_soul(Map.put(written, :display_name, "Петя"), dir) == %{}
      assert File.read!(Path.join(dir, "SOUL.md")) == "моё"
    end
  end
end
