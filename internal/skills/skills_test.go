package skills_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/igorkuznetsov/druzhok/internal/skills"
)

const validSkillContent = `---
name: setup
description: First-time setup
triggers:
  - "^/setup$"
  - "help me set up"
---
# Setup Instructions
Do the setup thing.
`

func TestLoadSkill(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "SKILL.md")
	if err := os.WriteFile(path, []byte(validSkillContent), 0644); err != nil {
		t.Fatal(err)
	}

	skill, err := skills.LoadSkill(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if skill.Name != "setup" {
		t.Errorf("expected name 'setup', got %q", skill.Name)
	}
	if skill.Description != "First-time setup" {
		t.Errorf("expected description 'First-time setup', got %q", skill.Description)
	}
	if len(skill.Triggers) != 2 {
		t.Errorf("expected 2 triggers, got %d", len(skill.Triggers))
	}
	if !strings.Contains(skill.Body, "Setup Instructions") {
		t.Errorf("expected body to contain 'Setup Instructions', got %q", skill.Body)
	}
}

func TestLoadSkillMalformed(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "SKILL.md")
	// No frontmatter delimiters
	if err := os.WriteFile(path, []byte("# Just a plain markdown file\nNo frontmatter here."), 0644); err != nil {
		t.Fatal(err)
	}

	_, err := skills.LoadSkill(path)
	if err == nil {
		t.Fatal("expected error for malformed skill, got nil")
	}
}

func TestRegistryDiscover(t *testing.T) {
	dir := t.TempDir()

	skill1 := `---
name: alpha
description: Alpha skill
triggers:
  - "^/alpha$"
---
Alpha body.
`
	skill2 := `---
name: beta
description: Beta skill
triggers:
  - "^/beta$"
---
Beta body.
`

	sub1 := filepath.Join(dir, "alpha")
	sub2 := filepath.Join(dir, "beta")
	if err := os.MkdirAll(sub1, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(sub2, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub1, "SKILL.md"), []byte(skill1), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub2, "SKILL.md"), []byte(skill2), 0644); err != nil {
		t.Fatal(err)
	}

	reg, err := skills.NewRegistry(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if reg.Get("alpha") == nil {
		t.Error("expected 'alpha' skill to be registered")
	}
	if reg.Get("beta") == nil {
		t.Error("expected 'beta' skill to be registered")
	}
}

func TestRegistryMatch(t *testing.T) {
	dir := t.TempDir()

	skillContent := `---
name: setup
description: Setup skill
triggers:
  - "^/setup$"
  - "help me set up"
---
Setup body.
`
	sub := filepath.Join(dir, "setup")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "SKILL.md"), []byte(skillContent), 0644); err != nil {
		t.Fatal(err)
	}

	reg, err := skills.NewRegistry(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	tests := []struct {
		input   string
		wantHit bool
	}{
		{"/setup", true},
		{"/setup extra", false},
		{"hello", false},
		{"help me set up", true},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			match := reg.Match(tt.input)
			if tt.wantHit && match == nil {
				t.Errorf("input %q: expected a match, got nil", tt.input)
			}
			if !tt.wantHit && match != nil {
				t.Errorf("input %q: expected no match, got skill %q", tt.input, match.Name)
			}
		})
	}
}

func TestRegistryMatchNoMatch(t *testing.T) {
	dir := t.TempDir()

	skillContent := `---
name: setup
description: Setup skill
triggers:
  - "^/setup$"
---
Setup body.
`
	sub := filepath.Join(dir, "setup")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "SKILL.md"), []byte(skillContent), 0644); err != nil {
		t.Fatal(err)
	}

	reg, err := skills.NewRegistry(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if match := reg.Match("something completely unrelated"); match != nil {
		t.Errorf("expected nil, got skill %q", match.Name)
	}
}

func TestBuildSkillPrompt(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "SKILL.md")
	if err := os.WriteFile(path, []byte(validSkillContent), 0644); err != nil {
		t.Fatal(err)
	}

	skill, err := skills.LoadSkill(path)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Without user input
	prompt := skill.BuildPrompt("")
	if prompt != skill.Body {
		t.Errorf("expected body only, got %q", prompt)
	}

	// With user input
	prompt = skill.BuildPrompt("please help me")
	expected := skill.Body + "\n\nUser request: please help me"
	if prompt != expected {
		t.Errorf("expected %q, got %q", expected, prompt)
	}
}

func TestRegistryGet(t *testing.T) {
	dir := t.TempDir()

	skillContent := `---
name: myskill
description: My skill
triggers:
  - "^/myskill$"
---
My skill body.
`
	sub := filepath.Join(dir, "myskill")
	if err := os.MkdirAll(sub, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sub, "SKILL.md"), []byte(skillContent), 0644); err != nil {
		t.Fatal(err)
	}

	reg, err := skills.NewRegistry(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if got := reg.Get("myskill"); got == nil {
		t.Error("expected skill 'myskill', got nil")
	} else if got.Name != "myskill" {
		t.Errorf("expected name 'myskill', got %q", got.Name)
	}

	if got := reg.Get("nonexistent"); got != nil {
		t.Errorf("expected nil for unknown skill, got %q", got.Name)
	}
}
