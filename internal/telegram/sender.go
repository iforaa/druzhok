package telegram

import "unicode/utf8"

// TelegramMessageLimit is the maximum number of bytes Telegram accepts per
// message.
const TelegramMessageLimit = 4096

// SplitMessage splits text into chunks no larger than limit bytes, always
// cutting on rune boundaries so that UTF-8 sequences are never corrupted.
//
// Special cases:
//   - Empty text returns nil.
//   - Text whose byte length is within limit returns a single-element slice.
func SplitMessage(text string, limit int) []string {
	if len(text) == 0 {
		return nil
	}
	if len(text) <= limit {
		return []string{text}
	}

	var chunks []string
	for len(text) > 0 {
		if len(text) <= limit {
			chunks = append(chunks, text)
			break
		}

		// Find the last rune boundary at or before limit bytes.
		cut := limit
		for cut > 0 && !utf8.RuneStart(text[cut]) {
			cut--
		}
		// If cut reached 0 something is very wrong with the encoding, but
		// protect against an infinite loop by advancing at least one byte.
		if cut == 0 {
			cut = 1
		}

		chunks = append(chunks, text[:cut])
		text = text[cut:]
	}
	return chunks
}
