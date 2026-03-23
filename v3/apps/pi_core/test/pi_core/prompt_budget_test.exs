defmodule PiCore.PromptBudgetTest do
  use ExUnit.Case

  alias PiCore.PromptBudget

  @workspace System.tmp_dir!() |> Path.join("prompt_budget_test_#{:rand.uniform(99999)}")

  setup do
    File.mkdir_p!(@workspace)

    File.write!(Path.join(@workspace, "IDENTITY.md"), "I am TestBot.")
    File.write!(Path.join(@workspace, "SOUL.md"), "Be helpful and kind.")
    File.write!(Path.join(@workspace, "AGENTS.md"), "Follow these rules:\n1. Be concise\n2. Use tools")
    File.write!(Path.join(@workspace, "USER.md"), "User prefers English.")

    on_exit(fn -> File.rm_rf!(@workspace) end)
    :ok
  end

  test "builds prompt from workspace files" do
    {prompt, tokens} = PromptBudget.build(@workspace, %{budget_tokens: 5_000})
    assert prompt =~ "TestBot"
    assert prompt =~ "helpful and kind"
    assert prompt =~ "Follow these rules"
    assert tokens > 0
  end

  test "excludes USER.md in group mode" do
    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 5_000, group: true})
    refute prompt =~ "prefers English"
  end

  test "truncates large files with head+tail" do
    big_content = String.duplicate("Important rule number one.\n", 500)
    File.write!(Path.join(@workspace, "AGENTS.md"), big_content)

    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 200})
    assert prompt =~ "[truncated"
  end

  test "formats skills catalog with tiered fallback" do
    skills = [
      {"greeting", "Greet the user warmly", "./skills/greeting/SKILL.md"},
      {"coding", "Help with coding tasks", "./skills/coding/SKILL.md"},
    ]

    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 5_000, skills: skills})
    assert prompt =~ "greeting"
    assert prompt =~ "coding"
  end

  test "compresses skills to compact format when budget is tight" do
    skills = for i <- 1..50 do
      {"skill_#{i}", String.duplicate("description ", 20), "./skills/skill_#{i}/SKILL.md"}
    end

    {prompt, _} = PromptBudget.build(@workspace, %{budget_tokens: 500, skills: skills})
    assert prompt =~ "skill_1"
  end
end
