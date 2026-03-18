package processor

import (
	"strings"
	"testing"
)

func TestBuildPrompt(t *testing.T) {
	tests := []struct {
		name         string
		systemPrompt string
		userMessage  string
		wantContains []string
		wantAbsent   []string
	}{
		{
			name:         "no system prompt returns user message as-is",
			systemPrompt: "",
			userMessage:  "Hello, world!",
			wantContains: []string{"Hello, world!"},
			wantAbsent:   []string{"<system-context>"},
		},
		{
			name:         "with system prompt wraps in tags and includes user message",
			systemPrompt: "You are a helpful assistant.",
			userMessage:  "What is Go?",
			wantContains: []string{
				"<system-context>",
				"You are a helpful assistant.",
				"</system-context>",
				"What is Go?",
			},
			wantAbsent: []string{},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := BuildPrompt(tc.systemPrompt, tc.userMessage)

			for _, want := range tc.wantContains {
				if !strings.Contains(got, want) {
					t.Errorf("BuildPrompt() = %q, want it to contain %q", got, want)
				}
			}

			for _, absent := range tc.wantAbsent {
				if strings.Contains(got, absent) {
					t.Errorf("BuildPrompt() = %q, want it NOT to contain %q", got, absent)
				}
			}
		})
	}
}
