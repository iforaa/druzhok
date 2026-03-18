package processor

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
	"github.com/igorkuznetsov/druzhok/internal/telegram"
)

var (
	internalTagRe = regexp.MustCompile(`(?s)<internal>.*?</internal>`)
	// Generic model markup: <|anything|> blocks and sections.
	// Catches tool calls, thinking tags, and other model-specific artifacts.
	pipeTagRe = regexp.MustCompile(`(?s)<\|[^|]+\|>`)
	// Catch content between pipe tag pairs (e.g. <|tool_call_begin|>...<|tool_call_end|>).
	pipeBlockRe = regexp.MustCompile(`(?s)<\|[^|]+_begin\|>.*?<\|[^|]+_end\|>`)
)

// editInterval is the minimum time between Telegram message edits (rate limit).
const editInterval = 1 * time.Second

// Processor handles incoming user messages by sending them to OpenCode
// and persisting the responses. It limits concurrent in-flight requests
// via a semaphore channel.
type Processor struct {
	db     *db.DB
	client *opencode.Client
	bot    *telegram.Bot
	sem    chan struct{}
	log    *slog.Logger
}

// New creates a Processor with the given concurrency limit.
func New(database *db.DB, client *opencode.Client, bot *telegram.Bot, maxConcurrent int) *Processor {
	return &Processor{
		db:     database,
		client: client,
		bot:    bot,
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

// StripInternalTags removes <internal> blocks, model-specific markup tags
// (<|...|> style), and other artifacts from agent output.
// This follows the NanoClaw pattern: strip everything that isn't meant for the user.
func StripInternalTags(text string) string {
	text = internalTagRe.ReplaceAllString(text, "")
	text = pipeBlockRe.ReplaceAllString(text, "")
	text = pipeTagRe.ReplaceAllString(text, "")
	// Clean up leftover whitespace from stripped blocks.
	text = regexp.MustCompile(`\n{3,}`).ReplaceAllString(text, "\n\n")
	return strings.TrimSpace(text)
}

// Process handles a single user message end-to-end:
//  1. Acquires a semaphore slot (respects ctx cancellation).
//  2. Marks the message as "processing".
//  3. Ensures the chat has an OpenCode session, creating one if needed.
//  4. Builds the prompt and sends it to OpenCode with streaming.
//  5. Streams partial responses to Telegram by editing a placeholder message.
//  6. Saves the assistant reply as a new message in the DB.
//  7. Marks the original user message as "completed".
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

	// 3. Ensure chat directory exists (for rules file).
	if err := EnsureChatDir(chat.TgChatID); err != nil {
		log.Warn("processor: failed to create chat dir", "error", err)
	}

	// 4. Ensure the chat has an OpenCode session.
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

	// 5. Send initial placeholder message to Telegram.
	tgMsgID, sendErr := p.bot.SendInitialMessage(ctx, chat.TgChatID, "...")
	if sendErr != nil {
		log.Warn("processor: failed to send initial message, falling back to non-streaming", "error", sendErr)
	}

	// 6. Send prompt with streaming callback.
	var mu sync.Mutex
	var lastEditTime time.Time
	var lastEditedText string

	onChunk := func(text string) {
		if tgMsgID == 0 {
			return // no placeholder message to edit
		}

		cleaned := StripInternalTags(text)
		if cleaned == "" {
			return
		}

		// Truncate to Telegram message limit.
		if len(cleaned) > telegram.TelegramMessageLimit {
			cleaned = cleaned[:telegram.TelegramMessageLimit]
		}

		mu.Lock()
		defer mu.Unlock()

		// Rate-limit: at most 1 edit per second.
		if time.Since(lastEditTime) < editInterval {
			return
		}
		// Skip if text hasn't changed.
		if cleaned == lastEditedText {
			return
		}

		if err := p.bot.EditMessage(ctx, chat.TgChatID, tgMsgID, cleaned); err != nil {
			log.Debug("processor: failed to edit message during streaming", "error", err)
			return
		}
		lastEditTime = time.Now()
		lastEditedText = cleaned
	}

	responseText, err := p.client.SendPromptStreaming(ctx, sessionID, prompt, onChunk)
	if err != nil {
		return "", fmt.Errorf("processor: send prompt: %w", err)
	}

	// 7. Save full assistant response (including internal tags) for history.
	if _, err := p.db.SaveMessage(chat.ID, 0, "assistant", responseText); err != nil {
		return "", fmt.Errorf("processor: save assistant message: %w", err)
	}

	// 8. Mark user message as completed.
	if err := p.db.UpdateMessageStatus(msg.ID, "completed"); err != nil {
		return "", fmt.Errorf("processor: update status completed: %w", err)
	}
	log.Debug("processor: message completed")

	// 9. Strip <internal>...</internal> blocks before returning to user.
	userVisible := StripInternalTags(responseText)
	if userVisible == "" {
		userVisible = "(Task completed)"
	}

	// 10. Final edit of the Telegram message with complete response.
	if tgMsgID != 0 {
		// Truncate for Telegram limit before final edit.
		finalText := userVisible
		if len(finalText) > telegram.TelegramMessageLimit {
			finalText = finalText[:telegram.TelegramMessageLimit]
		}
		if err := p.bot.EditMessage(ctx, chat.TgChatID, tgMsgID, finalText); err != nil {
			log.Warn("processor: failed to send final edit", "error", err)
		}
	}

	return userVisible, nil
}
