defmodule PiCore.Skills.LoaderTest do
  use ExUnit.Case
  alias PiCore.Skills.Loader

  @workspace System.tmp_dir!() |> Path.join("skills_loader_test_#{:rand.uniform(99999)}")

  setup do
    File.rm_rf!(@workspace)
    File.mkdir_p!(Path.join(@workspace, "skills"))
    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  defp create_skill(name, frontmatter, body \\ "# Skill content") do
    dir = Path.join([@workspace, "skills", name])
    File.mkdir_p!(dir)
    content = "---\n#{frontmatter}\n---\n\n#{body}"
    File.write!(Path.join(dir, "SKILL.md"), content)
  end

  test "loads skills from workspace/skills/" do
    create_skill("weather", "name: weather\ndescription: Check weather")
    create_skill("translate", "name: translate\ndescription: Translate text")
    skills = Loader.load(@workspace)
    assert length(skills) == 2
    assert {"translate", "Translate text", "skills/translate/SKILL.md"} in skills
    assert {"weather", "Check weather", "skills/weather/SKILL.md"} in skills
  end

  test "returns empty list when skills/ does not exist" do
    workspace = Path.join(System.tmp_dir!(), "no_skills_#{:rand.uniform(99999)}")
    assert Loader.load(workspace) == []
  end

  test "skips skills without name" do
    create_skill("bad", "description: No name field")
    assert Loader.load(@workspace) == []
  end

  test "skips disabled skills" do
    create_skill("off", "name: off\ndescription: Disabled\nenabled: false")
    assert Loader.load(@workspace) == []
  end

  test "skips pending approval skills" do
    create_skill("pending", "name: pending\ndescription: Waiting\npending_approval: true")
    assert Loader.load(@workspace) == []
  end

  test "includes enabled skills by default" do
    create_skill("active", "name: active\ndescription: Active skill")
    skills = Loader.load(@workspace)
    assert length(skills) == 1
  end

  test "skips invalid directory names" do
    create_skill("UPPERCASE", "name: upper\ndescription: Upper")
    assert Loader.load(@workspace) == []
  end

  test "accepts valid directory names" do
    create_skill("my-skill", "name: my-skill\ndescription: Dashed")
    create_skill("skill_2", "name: skill_2\ndescription: Underscored")
    assert length(Loader.load(@workspace)) == 2
  end

  test "skips files over 256KB" do
    create_skill("huge", "name: huge\ndescription: Too big", String.duplicate("x", 300_000))
    assert Loader.load(@workspace) == []
  end

  test "returns sorted by name" do
    create_skill("zebra", "name: zebra\ndescription: Z")
    create_skill("alpha", "name: alpha\ndescription: A")
    assert [{"alpha", _, _}, {"zebra", _, _}] = Loader.load(@workspace)
  end

  test "parse_frontmatter extracts fields" do
    content = "---\nname: test\ndescription: A test\nenabled: true\npending_approval: false\n---\n\n# Body"
    assert {:ok, "test", "A test", true, false} = Loader.parse_frontmatter(content)
  end

  test "parse_frontmatter defaults enabled to true" do
    content = "---\nname: test\ndescription: Desc\n---\n\nBody"
    assert {:ok, "test", "Desc", true, false} = Loader.parse_frontmatter(content)
  end

  test "parse_frontmatter returns error without frontmatter" do
    assert :error = Loader.parse_frontmatter("No frontmatter here")
  end
end
