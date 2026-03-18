package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

// User represents a row in the users table.
type User struct {
	ID        string
	TgUserID  int64
	Name      string
	IsAdmin   bool
	CreatedAt time.Time
}

// CreateUser inserts a new user. The very first user in the database is
// automatically granted admin privileges.
func (d *DB) CreateUser(tgUserID int64, name string) (*User, error) {
	// Determine whether this will be the first user (→ admin).
	var count int
	if err := d.conn.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&count); err != nil {
		return nil, fmt.Errorf("create user count: %w", err)
	}
	isAdmin := count == 0

	u := &User{
		ID:       newID(),
		TgUserID: tgUserID,
		Name:     name,
		IsAdmin:  isAdmin,
	}

	_, err := d.conn.Exec(
		`INSERT INTO users (id, tg_user_id, name, is_admin) VALUES (?, ?, ?, ?)`,
		u.ID, u.TgUserID, u.Name, boolToInt(u.IsAdmin),
	)
	if err != nil {
		return nil, fmt.Errorf("create user insert: %w", err)
	}

	// Re-read to get the server-generated created_at timestamp.
	return d.GetUserByTgID(tgUserID)
}

// GetUserByTgID looks up a user by their Telegram user ID.
// Returns nil, nil when the user does not exist.
func (d *DB) GetUserByTgID(tgUserID int64) (*User, error) {
	row := d.conn.QueryRow(
		`SELECT id, tg_user_id, name, is_admin, created_at FROM users WHERE tg_user_id = ?`,
		tgUserID,
	)

	u := &User{}
	var isAdmin int
	err := row.Scan(&u.ID, &u.TgUserID, &u.Name, &isAdmin, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get user by tg id: %w", err)
	}
	u.IsAdmin = isAdmin == 1
	return u, nil
}
