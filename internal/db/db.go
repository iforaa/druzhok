package db

import (
	"database/sql"
	"fmt"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

// DB wraps the sql.DB connection.
type DB struct {
	conn *sql.DB
}

// Open opens a SQLite database at the given DSN, enables WAL mode and
// foreign keys, then runs migrations.
func Open(dsn string) (*DB, error) {
	conn, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("db open: %w", err)
	}

	// Enable WAL mode for better concurrent read performance.
	if _, err := conn.Exec("PRAGMA journal_mode=WAL;"); err != nil {
		conn.Close()
		return nil, fmt.Errorf("db wal mode: %w", err)
	}

	// Enable foreign key enforcement.
	if _, err := conn.Exec("PRAGMA foreign_keys=ON;"); err != nil {
		conn.Close()
		return nil, fmt.Errorf("db foreign keys: %w", err)
	}

	d := &DB{conn: conn}
	if err := d.Migrate(); err != nil {
		conn.Close()
		return nil, fmt.Errorf("db migrate: %w", err)
	}

	return d, nil
}

// Migrate creates all tables and indexes if they don't already exist.
// It is safe to call multiple times (idempotent).
func (d *DB) Migrate() error {
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS users (
			id         TEXT PRIMARY KEY,
			tg_user_id INTEGER NOT NULL UNIQUE,
			name       TEXT NOT NULL,
			is_admin   INTEGER NOT NULL DEFAULT 0,
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)`,

		`CREATE TABLE IF NOT EXISTS chats (
			id            TEXT PRIMARY KEY,
			user_id       TEXT NOT NULL REFERENCES users(id),
			tg_chat_id    INTEGER NOT NULL UNIQUE,
			oc_session_id TEXT NOT NULL DEFAULT '',
			name          TEXT NOT NULL DEFAULT '',
			system_prompt TEXT NOT NULL DEFAULT '',
			model         TEXT NOT NULL DEFAULT '',
			status        TEXT NOT NULL DEFAULT 'active',
			created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
		)`,

		`CREATE TABLE IF NOT EXISTS messages (
			id            TEXT PRIMARY KEY,
			chat_id       TEXT NOT NULL REFERENCES chats(id),
			tg_message_id INTEGER,
			role          TEXT NOT NULL CHECK(role IN ('user', 'assistant')),
			text          TEXT NOT NULL,
			status        TEXT NOT NULL DEFAULT 'pending'
			              CHECK(status IN ('pending', 'processing', 'completed', 'sent', 'failed')),
			created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
		)`,

		`CREATE INDEX IF NOT EXISTS idx_messages_status ON messages(status)`,
		`CREATE INDEX IF NOT EXISTS idx_messages_chat   ON messages(chat_id, created_at)`,
		`CREATE INDEX IF NOT EXISTS idx_chats_tg        ON chats(tg_chat_id)`,
	}

	for _, stmt := range stmts {
		if _, err := d.conn.Exec(stmt); err != nil {
			return fmt.Errorf("migrate: %w", err)
		}
	}
	return nil
}

// Close closes the underlying database connection.
func (d *DB) Close() error {
	return d.conn.Close()
}

// newID returns a new random UUID string.
func newID() string {
	return uuid.NewString()
}

// boolToInt converts a bool to an integer suitable for SQLite storage.
func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
