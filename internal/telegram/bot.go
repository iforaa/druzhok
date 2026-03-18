package telegram

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	tgbot "github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

// Handler is the callback invoked for every incoming message.
type Handler func(ctx context.Context, chatID int64, userID int64, userName string, messageID int, text string)

// Bot wraps the go-telegram/bot client and dispatches messages to a Handler.
type Bot struct {
	bot     *tgbot.Bot
	handler Handler
	log     *slog.Logger
}

// NewBot creates a new Bot instance.  The provided handler will be called for
// every message the bot receives.
func NewBot(token string, handler Handler) (*Bot, error) {
	b := &Bot{
		handler: handler,
		log:     slog.Default(),
	}

	tb, err := tgbot.New(token, tgbot.WithDefaultHandler(b.onUpdate))
	if err != nil {
		return nil, fmt.Errorf("telegram: create bot: %w", err)
	}
	b.bot = tb
	return b, nil
}

// Start begins long-polling for updates.  It blocks until ctx is cancelled.
func (b *Bot) Start(ctx context.Context) {
	b.log.Info("telegram bot starting")
	b.bot.Start(ctx)
	b.log.Info("telegram bot stopped")
}

// SendMessage sends text to chatID, splitting into multiple messages if the
// text exceeds TelegramMessageLimit.
func (b *Bot) SendMessage(ctx context.Context, chatID int64, text string) error {
	chunks := SplitMessage(text, TelegramMessageLimit)
	for _, chunk := range chunks {
		_, err := b.bot.SendMessage(ctx, &tgbot.SendMessageParams{
			ChatID: chatID,
			Text:   chunk,
		})
		if err != nil {
			return fmt.Errorf("telegram: send message: %w", err)
		}
	}
	return nil
}

// SendInitialMessage sends an initial placeholder message and returns its ID.
// This is used to create a message that will later be edited with streaming content.
func (b *Bot) SendInitialMessage(ctx context.Context, chatID int64, text string) (int, error) {
	msg, err := b.bot.SendMessage(ctx, &tgbot.SendMessageParams{
		ChatID: chatID,
		Text:   text,
	})
	if err != nil {
		return 0, fmt.Errorf("telegram: send initial message: %w", err)
	}
	return msg.ID, nil
}

// EditMessage edits an existing message's text using the Telegram Bot API's
// editMessageText method. If the new text is identical to the current text,
// Telegram returns an error which this method silently ignores.
func (b *Bot) EditMessage(ctx context.Context, chatID int64, messageID int, text string) error {
	_, err := b.bot.EditMessageText(ctx, &tgbot.EditMessageTextParams{
		ChatID:    chatID,
		MessageID: messageID,
		Text:      text,
	})
	if err != nil {
		// Telegram returns "message is not modified" if the text hasn't changed.
		// This is not a real error.
		if strings.Contains(err.Error(), "message is not modified") {
			return nil
		}
		return fmt.Errorf("telegram: edit message: %w", err)
	}
	return nil
}

// onUpdate is the default handler wired into the tgbot library.
func (b *Bot) onUpdate(ctx context.Context, _ *tgbot.Bot, update *models.Update) {
	msg := update.Message
	if msg == nil {
		return
	}

	// Skip messages with no text (photos, stickers, etc.)
	if msg.Text == "" {
		return
	}

	chatID := msg.Chat.ID
	messageID := msg.ID
	text := msg.Text

	var userID int64
	var userName string
	if msg.From != nil {
		userID = msg.From.ID
		userName = strings.TrimSpace(msg.From.FirstName + " " + msg.From.LastName)
	}

	b.log.Debug("telegram: received message",
		"chat_id", chatID,
		"user_id", userID,
		"user", userName,
		"message_id", messageID,
	)

	b.handler(ctx, chatID, userID, userName, messageID, text)
}
