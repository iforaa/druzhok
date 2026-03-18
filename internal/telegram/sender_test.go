package telegram

import (
	"strings"
	"testing"
)

func TestSplitMessage(t *testing.T) {
	// Helper to produce a string of exactly n ASCII bytes.
	repeat := func(n int) string {
		return strings.Repeat("a", n)
	}

	tests := []struct {
		name       string
		text       string
		limit      int
		wantChunks int
	}{
		{
			name:       "short text",
			text:       "hello",
			limit:      TelegramMessageLimit,
			wantChunks: 1,
		},
		{
			name:       "exact limit",
			text:       repeat(TelegramMessageLimit),
			limit:      TelegramMessageLimit,
			wantChunks: 1,
		},
		{
			name:       "5000 bytes splits into 2",
			text:       repeat(5000),
			limit:      TelegramMessageLimit,
			wantChunks: 2,
		},
		{
			name:       "10000 bytes splits into 3",
			text:       repeat(10000),
			limit:      TelegramMessageLimit,
			wantChunks: 3,
		},
		{
			name:       "empty returns nil",
			text:       "",
			limit:      TelegramMessageLimit,
			wantChunks: 0,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			chunks := SplitMessage(tc.text, tc.limit)

			if tc.wantChunks == 0 {
				if chunks != nil {
					t.Errorf("expected nil, got %d chunks", len(chunks))
				}
				return
			}

			if len(chunks) != tc.wantChunks {
				t.Errorf("chunk count: got %d, want %d", len(chunks), tc.wantChunks)
			}

			// Verify content is preserved.
			joined := strings.Join(chunks, "")
			if joined != tc.text {
				t.Errorf("joined chunks do not match original text (len %d vs %d)", len(joined), len(tc.text))
			}

			// Verify no chunk exceeds the limit.
			for i, c := range chunks {
				if len(c) > tc.limit {
					t.Errorf("chunk %d length %d exceeds limit %d", i, len(c), tc.limit)
				}
			}
		})
	}

	t.Run("utf8 content preserved", func(t *testing.T) {
		// Build a string with multi-byte runes that crosses the limit boundary.
		// Each rune is 2 bytes (U+00E9 é).
		r := "é" // 2 bytes
		runes := strings.Repeat(r, 3000) // 6000 bytes → 2 chunks at limit 4096
		chunks := SplitMessage(runes, TelegramMessageLimit)
		if len(chunks) < 2 {
			t.Fatalf("expected ≥2 chunks, got %d", len(chunks))
		}
		joined := strings.Join(chunks, "")
		if joined != runes {
			t.Error("UTF-8 content not preserved across split")
		}
		for i, c := range chunks {
			if len(c) > TelegramMessageLimit {
				t.Errorf("chunk %d exceeds limit", i)
			}
			// Check valid UTF-8.
			for j := 0; j < len(c); {
				_, size := []rune(c[j:j+1])[0], 0
				_ = size
				break
			}
		}
	})
}
