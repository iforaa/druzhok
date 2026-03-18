package processor

import (
	"context"
	"fmt"
	"log/slog"
	"regexp"
	"strings"

	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
)

var internalTagRe = regexp.MustCompile(`(?s)<internal>.*?</internal>`)

// Processor handles incoming user messages by sending them to OpenCode
// and persisting the responses. It limits concurrent in-flight requests
// via a semaphore channel.
type Processor struct {
	db     *db.DB
	client *opencode.Client
	sem    chan struct{}
	log    *slog.Logger
}

// New creates a Processor with the given concurrency limit.
func New(database *db.DB, client *opencode.Client, maxConcurrent int) *Processor {
	return &Processor{
		db:     database,
		client: client,
		sem:    make(chan struct{}, maxConcurrent),
		log:    slog.Default(),
	}
}

// BuildPrompt constructs the prompt string that will be sent to OpenCode.
// It includes system prompt, conversation history, and the new user message.
func BuildPrompt(systemPrompt string, history []db.Message, userMessage string) string {
	var parts []string

	if systemPrompt != "" {
		parts = append(parts, fmt.Sprintf("<system-context>\n%s\n</system-context>", systemPrompt))
	}

	if len(history) > 0 {
		parts = append(parts, FormatHistory(history))
	}

	parts = append(parts, userMessage)
	return strings.Join(parts, "\n\n")
}

// FormatHistory formats recent messages as XML context for the agent.
func FormatHistory(messages []db.Message) string {
	var lines []string
	for _, m := range messages {
		role := m.Role
		text := m.Text
		// Strip internal tags from assistant messages in history
		if role == "assistant" {
			text = StripInternalTags(text)
			if text == "" {
				continue
			}
		}
		lines = append(lines, fmt.Sprintf("<message role=\"%s\">%s</message>", role, text))
	}
	if len(lines) == 0 {
		return ""
	}
	return fmt.Sprintf("<conversation-history>\n%s\n</conversation-history>", strings.Join(lines, "\n"))
}

// maxHistoryMessages is the number of recent messages to include as context.
const maxHistoryMessages = 20

// StripInternalTags removes <internal>...</internal> blocks from agent output.
// Only the text outside these tags is shown to the user in Telegram.
func StripInternalTags(text string) string {
	return strings.TrimSpace(internalTagRe.ReplaceAllString(text, ""))
}

// Process handles a single user message end-to-end:
//  1. Acquires a semaphore slot (respects ctx cancellation).
//  2. Marks the message as "processing".
//  3. Ensures the chat has an OpenCode session, creating one if needed.
//  4. Builds the prompt and sends it to OpenCode.
//  5. Saves the assistant reply as a new message in the DB.
//  6. Marks the original user message as "completed".
//
// It returns the assistant response text.
func (p *Processor) Process(ctx context.Context, msg db.Message, chat *db.Chat) (string, error) {
	// 1. Acquire semaphore slot.
	select {
	case p.sem <- struct{}{}:
		defer func() { <-p.sem }()
	case <-ctx.Done():
		return "", ctx.Err()
	}

	log := p.log.With("msg_id", msg.ID, "chat_id", chat.ID)

	// 2. Mark message as processing.
	if err := p.db.UpdateMessageStatus(msg.ID, "processing"); err != nil {
		return "", fmt.Errorf("processor: update status processing: %w", err)
	}
	log.Debug("processor: message status set to processing")

	// 3. Ensure the chat has an OpenCode session.
	sessionID := chat.OcSessionID
	if sessionID == "" {
		var err error
		sessionID, err = p.client.CreateSession(ctx)
		if err != nil {
			return "", fmt.Errorf("processor: create session: %w", err)
		}
		if err := p.db.UpdateSessionID(chat.ID, sessionID); err != nil {
			return "", fmt.Errorf("processor: save session id: %w", err)
		}
		log.Debug("processor: new session created", "session_id", sessionID)
	}

	// 4. Fetch recent conversation history and build prompt.
	history, err := p.db.GetRecentMessages(chat.ID, maxHistoryMessages)
	if err != nil {
		log.Warn("processor: failed to fetch history, continuing without", "error", err)
		history = nil
	}
	prompt := BuildPrompt(chat.SystemPrompt, history, msg.Text)
	log.Debug("processor: sending prompt", "session_id", sessionID, "prompt_len", len(prompt), "history_msgs", len(history))

	responseText, err := p.client.SendPrompt(ctx, sessionID, prompt)
	if err != nil {
		return "", fmt.Errorf("processor: send prompt: %w", err)
	}

	// 5. Save full assistant response (including internal tags) for history.
	if _, err := p.db.SaveMessage(chat.ID, 0, "assistant", responseText); err != nil {
		return "", fmt.Errorf("processor: save assistant message: %w", err)
	}

	// 6. Mark user message as completed.
	if err := p.db.UpdateMessageStatus(msg.ID, "completed"); err != nil {
		return "", fmt.Errorf("processor: update status completed: %w", err)
	}
	log.Debug("processor: message completed")

	// 7. Strip <internal>...</internal> blocks before returning to user.
	userVisible := StripInternalTags(responseText)
	if userVisible == "" {
		userVisible = "(Task completed)"
	}

	return userVisible, nil
}
