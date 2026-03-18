package telegram

import (
	"testing"
)

func TestClassifyMessage(t *testing.T) {
	known := map[string]bool{
		"start":  true,
		"prompt": true,
		"model":  true,
		"reset":  true,
		"stop":   true,
	}

	tests := []struct {
		name        string
		text        string
		wantKind    MessageKind
		wantCmd     string
		wantArgs    string
	}{
		{
			name:     "/start",
			text:     "/start",
			wantKind: KindCommand,
			wantCmd:  "start",
			wantArgs: "",
		},
		{
			name:     "/prompt with args",
			text:     "/prompt You are a pirate",
			wantKind: KindCommand,
			wantCmd:  "prompt",
			wantArgs: "You are a pirate",
		},
		{
			name:     "/model with args",
			text:     "/model openai/gpt-4o",
			wantKind: KindCommand,
			wantCmd:  "model",
			wantArgs: "openai/gpt-4o",
		},
		{
			name:     "/reset",
			text:     "/reset",
			wantKind: KindCommand,
			wantCmd:  "reset",
			wantArgs: "",
		},
		{
			name:     "/stop",
			text:     "/stop",
			wantKind: KindCommand,
			wantCmd:  "stop",
			wantArgs: "",
		},
		{
			name:     "regular message",
			text:     "hello there",
			wantKind: KindRegular,
			wantCmd:  "",
			wantArgs: "",
		},
		{
			name:     "unknown command treated as regular",
			text:     "/unknown_cmd",
			wantKind: KindRegular,
			wantCmd:  "",
			wantArgs: "",
		},
		{
			name:     "/start@mybot strips botname suffix",
			text:     "/start@mybot",
			wantKind: KindCommand,
			wantCmd:  "start",
			wantArgs: "",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			gotKind, gotCmd, gotArgs := ClassifyMessage(tc.text, known)
			if gotKind != tc.wantKind {
				t.Errorf("kind: got %v, want %v", gotKind, tc.wantKind)
			}
			if gotCmd != tc.wantCmd {
				t.Errorf("cmd: got %q, want %q", gotCmd, tc.wantCmd)
			}
			if gotArgs != tc.wantArgs {
				t.Errorf("args: got %q, want %q", gotArgs, tc.wantArgs)
			}
		})
	}
}
