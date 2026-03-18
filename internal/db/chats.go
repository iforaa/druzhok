package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Chat represents a row in the chats table.
type Chat struct {
	ID           string
	UserID       string
	TgChatID     int64
	OcSessionID  string
	Name         string
	SystemPrompt string
	Model        string
	Status       string
	CreatedAt    time.Time
}

// CreateChat inserts a new chat associated with the given user.
func (d *DB) CreateChat(userID string, tgChatID int64, name string) (*Chat, error) {
	c := &Chat{
		ID:       newID(),
		UserID:   userID,
		TgChatID: tgChatID,
		Name:     name,
	}

	_, err := d.conn.Exec(
		`INSERT INTO chats (id, user_id, tg_chat_id, name) VALUES (?, ?, ?, ?)`,
		c.ID, c.UserID, c.TgChatID, c.Name,
	)
	if err != nil {
		return nil, fmt.Errorf("create chat insert: %w", err)
	}

	return d.GetChatByID(c.ID)
}

// GetChatByTgID looks up a chat by its Telegram chat ID.
// Returns nil, nil when the chat does not exist.
func (d *DB) GetChatByTgID(tgChatID int64) (*Chat, error) {
	row := d.conn.QueryRow(
		`SELECT id, user_id, tg_chat_id, oc_session_id, name, system_prompt, model, status, created_at
		 FROM chats WHERE tg_chat_id = ?`,
		tgChatID,
	)
	return scanChat(row)
}

// GetChatByID looks up a chat by its internal UUID.
// Returns nil, nil when the chat does not exist.
func (d *DB) GetChatByID(chatID string) (*Chat, error) {
	row := d.conn.QueryRow(
		`SELECT id, user_id, tg_chat_id, oc_session_id, name, system_prompt, model, status, created_at
		 FROM chats WHERE id = ?`,
		chatID,
	)
	return scanChat(row)
}

// UpdateSessionID sets the OpenChat session ID for a chat.
func (d *DB) UpdateSessionID(chatID, sessionID string) error {
	return updateChatField(d, `UPDATE chats SET oc_session_id = ? WHERE id = ?`, sessionID, chatID)
}

// UpdateSystemPrompt sets the system prompt for a chat.
func (d *DB) UpdateSystemPrompt(chatID, prompt string) error {
	return updateChatField(d, `UPDATE chats SET system_prompt = ? WHERE id = ?`, prompt, chatID)
}

// UpdateModel sets the model for a chat.
func (d *DB) UpdateModel(chatID, model string) error {
	return updateChatField(d, `UPDATE chats SET model = ? WHERE id = ?`, model, chatID)
}

// UpdateChatStatus sets the status for a chat.
func (d *DB) UpdateChatStatus(chatID, status string) error {
	return updateChatField(d, `UPDATE chats SET status = ? WHERE id = ?`, status, chatID)
}

// --- helpers -----------------------------------------------------------------

func scanChat(row *sql.Row) (*Chat, error) {
	c := &Chat{}
	err := row.Scan(
		&c.ID, &c.UserID, &c.TgChatID, &c.OcSessionID,
		&c.Name, &c.SystemPrompt, &c.Model, &c.Status, &c.CreatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("scan chat: %w", err)
	}
	return c, nil
}

func updateChatField(d *DB, query string, args ...any) error {
	_, err := d.conn.Exec(query, args...)
	if err != nil {
		return fmt.Errorf("update chat field: %w", err)
	}
	return nil
}
