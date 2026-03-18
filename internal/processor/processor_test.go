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

func TestStripInternalTags(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "no tags",
			input: "Hello, world!",
			want:  "Hello, world!",
		},
		{
			name:  "strip single internal block",
			input: "Here's the result: <internal>writing code...</internal> Done!",
			want:  "Here's the result:  Done!",
		},
		{
			name:  "strip multiple internal blocks",
			input: "<internal>thinking...</internal>Answer is 42.<internal>checking...</internal> Confirmed.",
			want:  "Answer is 42. Confirmed.",
		},
		{
			name:  "multiline internal block",
			input: "Summary:\n<internal>\nfull code here\nmore code\n</internal>\nFile saved.",
			want:  "Summary:\n\nFile saved.",
		},
		{
			name:  "all internal returns empty",
			input: "<internal>only internal stuff</internal>",
			want:  "",
		},
		{
			name:  "empty string",
			input: "",
			want:  "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := StripInternalTags(tc.input)
			if got != tc.want {
				t.Errorf("StripInternalTags(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}
