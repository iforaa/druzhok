package skills

import (
	"fmt"
	"log/slog"
	"os"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// Skill represents a loaded skill with its metadata and body content.
type Skill struct {
	Name        string           `yaml:"name"`
	Description string           `yaml:"description"`
	Triggers    []string         `yaml:"triggers"`
	Body        string           `yaml:"-"`
	compiled    []*regexp.Regexp // pre-compiled trigger regexes
}

// LoadSkill parses a markdown file with YAML frontmatter between --- delimiters.
func LoadSkill(path string) (*Skill, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read skill file %s: %w", path, err)
	}

	content := string(data)

	// Expect file to start with ---
	if !strings.HasPrefix(content, "---") {
		return nil, fmt.Errorf("skill file %s: missing frontmatter (must start with ---)", path)
	}

	// Find the closing --- delimiter
	rest := content[3:] // skip opening ---
	// Trim a leading newline after ---
	if strings.HasPrefix(rest, "\n") {
		rest = rest[1:]
	} else if strings.HasPrefix(rest, "\r\n") {
		rest = rest[2:]
	}

	closeIdx := strings.Index(rest, "\n---")
	if closeIdx == -1 {
		return nil, fmt.Errorf("skill file %s: malformed frontmatter (no closing ---)", path)
	}

	frontmatter := rest[:closeIdx]
	body := rest[closeIdx+4:] // skip \n---
	// Trim leading newline after closing ---
	if strings.HasPrefix(body, "\n") {
		body = body[1:]
	} else if strings.HasPrefix(body, "\r\n") {
		body = body[2:]
	}

	var skill Skill
	if err := yaml.Unmarshal([]byte(frontmatter), &skill); err != nil {
		return nil, fmt.Errorf("skill file %s: parse frontmatter: %w", path, err)
	}

	if skill.Name == "" {
		return nil, fmt.Errorf("skill file %s: missing required field 'name'", path)
	}

	skill.Body = strings.TrimRight(body, "\n")

	// Pre-compile trigger regexes at load time.
	for _, trigger := range skill.Triggers {
		re, err := regexp.Compile(trigger)
		if err != nil {
			slog.Warn("invalid trigger regex, skipping", "skill", skill.Name, "trigger", trigger, "error", err)
			continue
		}
		skill.compiled = append(skill.compiled, re)
	}

	return &skill, nil
}

// BuildPrompt combines the skill body with the user's input.
// If userInput is empty, only the body is returned.
// Otherwise, the body is combined with "User request: {userInput}".
func (s *Skill) BuildPrompt(userInput string) string {
	if userInput == "" {
		return s.Body
	}
	return s.Body + "\n\nUser request: " + userInput
}
