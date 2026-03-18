package telegram

import (
	"strings"
)

// MessageKind classifies an incoming message.
type MessageKind int

const (
	// KindRegular is a normal text message (or an unrecognised command).
	KindRegular MessageKind = iota
	// KindCommand is a recognised bot command (e.g. /start).
	KindCommand
)

// ClassifyMessage inspects text and decides whether it is a known command or a
// regular message.
//
// Rules:
//   - If text does not start with '/' → KindRegular, "", "".
//   - If text starts with '/' but the extracted command name is not present in
//     knownCommands → KindRegular, "", "".
//   - Otherwise → KindCommand, commandName, args.
//
// commandName is lowercased and has any trailing @botname suffix stripped.
// args is everything after the command token, leading/trailing whitespace trimmed.
func ClassifyMessage(text string, knownCommands map[string]bool) (MessageKind, string, string) {
	if !strings.HasPrefix(text, "/") {
		return KindRegular, "", ""
	}

	// Split into at most 2 parts: command token and the rest.
	parts := strings.SplitN(text[1:], " ", 2)
	rawCmd := parts[0]

	// Strip optional @botname suffix.
	if at := strings.Index(rawCmd, "@"); at >= 0 {
		rawCmd = rawCmd[:at]
	}
	cmdName := strings.ToLower(rawCmd)

	if !knownCommands[cmdName] {
		return KindRegular, "", ""
	}

	args := ""
	if len(parts) == 2 {
		args = strings.TrimSpace(parts[1])
	}

	return KindCommand, cmdName, args
}
