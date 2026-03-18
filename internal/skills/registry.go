package skills

import (
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
)

// Registry holds all discovered skills and provides matching capabilities.
type Registry struct {
	skills []*Skill
	log    *slog.Logger
}

// NewRegistry discovers all SKILL.md files in immediate subdirectories of dir,
// loads each as a Skill, and returns a Registry containing them all.
// Invalid skills produce warnings but do not abort discovery.
func NewRegistry(dir string) (*Registry, error) {
	logger := slog.Default()
	reg := &Registry{log: logger}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		skillPath := filepath.Join(dir, entry.Name(), "SKILL.md")
		if _, err := os.Stat(skillPath); os.IsNotExist(err) {
			continue
		}

		skill, err := LoadSkill(skillPath)
		if err != nil {
			logger.Warn("failed to load skill", "path", skillPath, "error", err)
			continue
		}

		reg.skills = append(reg.skills, skill)
	}

	return reg, nil
}

// Match iterates all skills and returns the first whose trigger regex matches input.
// Returns nil if no skill matches.
func (r *Registry) Match(input string) *Skill {
	for _, skill := range r.skills {
		for _, trigger := range skill.Triggers {
			re, err := regexp.Compile(trigger)
			if err != nil {
				r.log.Warn("invalid trigger regex", "skill", skill.Name, "trigger", trigger, "error", err)
				continue
			}
			if re.MatchString(input) {
				return skill
			}
		}
	}
	return nil
}

// Get returns the skill with the given name, or nil if not found.
func (r *Registry) Get(name string) *Skill {
	for _, skill := range r.skills {
		if skill.Name == name {
			return skill
		}
	}
	return nil
}
