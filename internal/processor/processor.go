package processor

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
)

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
// When systemPrompt is empty the user message is returned unchanged.
// When systemPrompt is non-empty it is wrapped in <system-context> tags
// and prepended to the user message.
func BuildPrompt(systemPrompt, userMessage string) string {
	if systemPrompt == "" {
		return userMessage
	}
	return fmt.Sprintf("<system-context>\n%s\n</system-context>\n\n%s", systemPrompt, userMessage)
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

	// 4. Build prompt and send to OpenCode.
	prompt := BuildPrompt(chat.SystemPrompt, msg.Text)
	log.Debug("processor: sending prompt", "session_id", sessionID, "prompt_len", len(prompt))

	responseText, err := p.client.SendPrompt(ctx, sessionID, prompt)
	if err != nil {
		return "", fmt.Errorf("processor: send prompt: %w", err)
	}

	// 5. Save assistant response as a new message.
	if _, err := p.db.SaveMessage(chat.ID, 0, "assistant", responseText); err != nil {
		return "", fmt.Errorf("processor: save assistant message: %w", err)
	}

	// 6. Mark user message as completed.
	if err := p.db.UpdateMessageStatus(msg.ID, "completed"); err != nil {
		return "", fmt.Errorf("processor: update status completed: %w", err)
	}
	log.Debug("processor: message completed")

	return responseText, nil
}
