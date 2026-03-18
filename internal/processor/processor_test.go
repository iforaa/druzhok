package processor

import (
	"strings"
	"testing"

	"github.com/igorkuznetsov/druzhok/internal/db"
)

func TestBuildPrompt(t *testing.T) {
	tests := []struct {
		name          string
		chatRules     string
		rulesFilePath string
		history       []db.Message
		userMessage   string
		wantContains  []string
		wantAbsent    []string
	}{
		{
			name:        "no rules no history",
			chatRules:   "",
			history:     nil,
			userMessage: "Hello, world!",
			wantContains: []string{"Hello, world!"},
			wantAbsent:   []string{"<system-context>", "<conversation-history>"},
		},
		{
			name:          "with rules and file path",
			chatRules:     "You are a helpful assistant.",
			rulesFilePath: "chats/123/rules.md",
			history:       nil,
			userMessage:   "What is Go?",
			wantContains: []string{
				"<system-context>",
				"You are a helpful assistant.",
				"<chat-rules-file>chats/123/rules.md</chat-rules-file>",
				"What is Go?",
			},
		},
		{
			name:      "with history",
			chatRules: "",
			history: []db.Message{
				{Role: "user", Text: "Hi there"},
				{Role: "assistant", Text: "Hello! How can I help?"},
			},
			userMessage: "What did we talk about?",
			wantContains: []string{
				"<conversation-history>",
				"Hi there",
				"Hello! How can I help?",
				"What did we talk about?",
			},
		},
		{
			name:      "history strips internal tags from assistant messages",
			chatRules: "",
			history: []db.Message{
				{Role: "user", Text: "Build a game"},
				{Role: "assistant", Text: "<internal>writing code...</internal>Done! Game is ready."},
			},
			userMessage:  "Thanks",
			wantContains: []string{"Done! Game is ready.", "Thanks"},
			wantAbsent:   []string{"writing code"},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := BuildPrompt(tc.chatRules, tc.rulesFilePath, tc.history, tc.userMessage)

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
