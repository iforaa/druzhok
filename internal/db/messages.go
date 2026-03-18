package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// Message represents a row in the messages table.
type Message struct {
	ID          string
	ChatID      string
	TgMessageID int64
	Role        string
	Text        string
	Status      string
	CreatedAt   time.Time
}

// SaveMessage inserts a new message with status 'pending'.
func (d *DB) SaveMessage(chatID string, tgMessageID int64, role, text string) (*Message, error) {
	m := &Message{
		ID:          newID(),
		ChatID:      chatID,
		TgMessageID: tgMessageID,
		Role:        role,
		Text:        text,
		Status:      "pending",
	}

	_, err := d.conn.Exec(
		`INSERT INTO messages (id, chat_id, tg_message_id, role, text) VALUES (?, ?, ?, ?, ?)`,
		m.ID, m.ChatID, m.TgMessageID, m.Role, m.Text,
	)
	if err != nil {
		return nil, fmt.Errorf("save message: %w", err)
	}

	return d.getMessageByID(m.ID)
}

// UpdateMessageStatus transitions a message to a new status.
func (d *DB) UpdateMessageStatus(id, status string) error {
	_, err := d.conn.Exec(`UPDATE messages SET status = ? WHERE id = ?`, status, id)
	if err != nil {
		return fmt.Errorf("update message status: %w", err)
	}
	return nil
}

// GetPendingMessages returns all user messages with status 'pending' that
// belong to an active chat, ordered by creation time.
func (d *DB) GetPendingMessages() ([]Message, error) {
	rows, err := d.conn.Query(`
		SELECT m.id, m.chat_id, m.tg_message_id, m.role, m.text, m.status, m.created_at
		FROM messages m
		JOIN chats c ON c.id = m.chat_id
		WHERE m.role   = 'user'
		  AND m.status = 'pending'
		  AND c.status = 'active'
		ORDER BY m.created_at ASC
	`)
	if err != nil {
		return nil, fmt.Errorf("get pending messages query: %w", err)
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(
			&m.ID, &m.ChatID, &m.TgMessageID, &m.Role, &m.Text, &m.Status, &m.CreatedAt,
		); err != nil {
			return nil, fmt.Errorf("get pending messages scan: %w", err)
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("get pending messages rows: %w", err)
	}
	return msgs, nil
}

// getMessageByID is an internal helper that fetches a single message by UUID.
func (d *DB) getMessageByID(id string) (*Message, error) {
	row := d.conn.QueryRow(
		`SELECT id, chat_id, tg_message_id, role, text, status, created_at
		 FROM messages WHERE id = ?`,
		id,
	)
	m := &Message{}
	err := row.Scan(&m.ID, &m.ChatID, &m.TgMessageID, &m.Role, &m.Text, &m.Status, &m.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get message by id: %w", err)
	}
	return m, nil
}
