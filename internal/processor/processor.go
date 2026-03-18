package processor

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
)

var (
	internalTagRe = regexp.MustCompile(`(?s)<internal>.*?</internal>`)
	// Strip tool call markup that leaks from some models.
	toolCallsRe = regexp.MustCompile(`(?s)<\|tool_calls_section_begin\|>.*?<\|tool_calls_section_end\|>`)
	// Also catch individual tool call blocks if the section tags are missing.
	toolCallRe = regexp.MustCompile(`(?s)<\|tool_call_begin\|>.*?<\|tool_call_end\|>`)
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
// It includes chat rules, conversation history, rules file path, and the new user message.
func BuildPrompt(chatRules string, rulesFilePath string, history []db.Message, userMessage string) string {
	var parts []string

	if chatRules != "" {
		parts = append(parts, fmt.Sprintf("<system-context>\n%s\n</system-context>", chatRules))
	}

	if rulesFilePath != "" {
		parts = append(parts, fmt.Sprintf("<chat-rules-file>%s</chat-rules-file>", rulesFilePath))
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

// ChatRulesDir is the base directory for per-chat rules files.
const ChatRulesDir = "chats"

// RulesFilePath returns the path to the rules file for a given Telegram chat ID.
func RulesFilePath(tgChatID int64) string {
	return filepath.Join(ChatRulesDir, fmt.Sprintf("%d", tgChatID), "rules.md")
}

// LoadChatRules reads the rules.md file for a chat. Returns empty string if not found.
func LoadChatRules(tgChatID int64) string {
	data, err := os.ReadFile(RulesFilePath(tgChatID))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

// EnsureChatDir creates the per-chat directory if it doesn't exist.
func EnsureChatDir(tgChatID int64) error {
	dir := filepath.Join(ChatRulesDir, fmt.Sprintf("%d", tgChatID))
	return os.MkdirAll(dir, 0o755)
}

// StripInternalTags removes <internal>...</internal> blocks and tool call
// markup from agent output. Only clean text is shown to the user in Telegram.
func StripInternalTags(text string) string {
	text = internalTagRe.ReplaceAllString(text, "")
	text = toolCallsRe.ReplaceAllString(text, "")
	text = toolCallRe.ReplaceAllString(text, "")
	return strings.TrimSpace(text)
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
	isNewSession := chat.OcSessionID == ""
	sessionID := chat.OcSessionID
	if isNewSession {
		var err error
		sessionID, err = p.client.CreateSession(ctx)
		if err != nil {
			return "", fmt.Errorf("processor: create session: %w", err)
		}
		if err := p.db.UpdateSessionID(chat.ID, sessionID); err != nil {
			return "", fmt.Errorf("processor: save session id: %w", err)
		}
		// Also create the chat directory for rules on first session.
		if err := EnsureChatDir(chat.TgChatID); err != nil {
			log.Warn("processor: failed to create chat dir", "error", err)
		}
		log.Debug("processor: new session created", "session_id", sessionID)
	}

	// 4. Load per-chat rules and build prompt.
	chatRules := LoadChatRules(chat.TgChatID)
	rulesPath := ""
	if chatRules != "" {
		rulesPath = RulesFilePath(chat.TgChatID)
	} else {
		// Always include the path so the agent knows where to write rules.
		rulesPath = RulesFilePath(chat.TgChatID)
	}

	// History is only injected when the session is brand new.
	var history []db.Message
	if isNewSession {
		var histErr error
		history, histErr = p.db.GetRecentMessages(chat.ID, maxHistoryMessages)
		if histErr != nil {
			log.Warn("processor: failed to fetch history, continuing without", "error", histErr)
			history = nil
		}
	}
	prompt := BuildPrompt(chatRules, rulesPath, history, msg.Text)
	log.Debug("processor: sending prompt", "session_id", sessionID, "prompt_len", len(prompt))

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
