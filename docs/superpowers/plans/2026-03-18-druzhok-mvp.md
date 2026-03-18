# Druzhok MVP Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Telegram bot that routes messages to OpenCode's multi-model AI runtime, with per-chat isolation, system prompts, skills, and SQLite persistence.

**Architecture:** Single Go binary manages an `opencode serve` subprocess, a Telegram bot (long-polling), and SQLite state. Messages flow: Telegram → SQLite → Processor (goroutine per chat, semaphore-limited) → OpenCode SDK → response back to Telegram.

**Tech Stack:** Go 1.22+, `github.com/go-telegram/bot`, `modernc.org/sqlite` (CGo-free), `gopkg.in/yaml.v3`, `github.com/google/uuid`, `log/slog`

**Important:** Task 0 (SDK spike) determines whether we use `github.com/sst/opencode-sdk-go` or raw HTTP calls. Do NOT proceed past Task 0 until the spike confirms the API surface.

**Spec:** `docs/superpowers/specs/2026-03-18-druzhok-design.md`

---

## File Map

| File | Responsibility |
|------|---------------|
| `cmd/druzhok/main.go` | Entry point: parse flags, init components, run main loop, graceful shutdown |
| `internal/config/config.go` | Load config from env vars → credentials.yaml → .env, validate, expose struct |
| `internal/db/db.go` | Open SQLite in WAL mode, run migrations (CREATE TABLE IF NOT EXISTS) |
| `internal/db/users.go` | User CRUD: CreateUser, GetUserByTgID, IsAdmin |
| `internal/db/chats.go` | Chat CRUD: CreateChat, GetChatByTgID, UpdateSessionID, UpdateSystemPrompt, UpdateModel |
| `internal/db/messages.go` | Message CRUD: SaveMessage, UpdateStatus, GetPending, GetByChat |
| `internal/opencode/server.go` | Start/stop/monitor `opencode serve` subprocess, health checks |
| `internal/opencode/client.go` | Wrap Go SDK: CreateSession, SendPrompt, AbortSession |
| `internal/telegram/bot.go` | Initialize Telegram bot, start long-polling, dispatch to handler |
| `internal/telegram/handler.go` | Route messages: built-in commands → skills → regular messages |
| `internal/telegram/sender.go` | Send responses to Telegram, split long messages (4096 char limit) |
| `internal/processor/processor.go` | Process messages: build prompt, call OpenCode, update DB, semaphore concurrency |
| `internal/skills/loader.go` | Discover skill dirs, parse YAML frontmatter + markdown body |
| `internal/skills/registry.go` | Match messages against skill triggers, return skill content |
| `skills/setup/SKILL.md` | Setup skill: guided first-time installation instructions |
| `skills/customize/SKILL.md` | Customize skill: change chat behavior instructions |
| `skills/debug/SKILL.md` | Debug skill: troubleshooting instructions |
| `.opencode/agents/default.md` | Default OpenCode agent configuration |
| `Makefile` | Build, test, run targets |
| `.gitignore` | Ignore data/, .env, credentials |

---

### Task 0: OpenCode SDK Spike

**Purpose:** Verify the SDK API surface before building anything. This is the highest-risk item.

**Files:**
- Create: `spike/main.go`
- Create: `spike/go.mod`

- [ ] **Step 0.1: Create spike directory and Go module**

```bash
mkdir -p spike
cd spike
go mod init druzhok/spike
go get github.com/sst/opencode-sdk-go
```

- [ ] **Step 0.2: Write minimal spike program**

Create `spike/main.go`:

```go
package main

import (
	"context"
	"fmt"
	"log"
	"os/exec"
	"time"

	opencode "github.com/sst/opencode-sdk-go"
	"github.com/sst/opencode-sdk-go/option"
)

func main() {
	// 1. Start opencode serve
	cmd := exec.Command("opencode", "serve", "--port", "4096")
	cmd.Dir = "."
	if err := cmd.Start(); err != nil {
		log.Fatal("Failed to start opencode serve:", err)
	}
	defer cmd.Process.Kill()

	// 2. Wait for health
	time.Sleep(5 * time.Second)

	// 3. Connect via SDK
	client := opencode.NewClient(
		option.WithBaseURL("http://127.0.0.1:4096"),
	)

	ctx := context.Background()

	// 4. Check health
	health, err := client.Global.Health(ctx)
	if err != nil {
		log.Fatal("Health check failed:", err)
	}
	fmt.Printf("Health: %+v\n", health)

	// 5. Create session
	session, err := client.Session.New(ctx, opencode.SessionNewParams{})
	if err != nil {
		log.Fatal("Session create failed:", err)
	}
	fmt.Printf("Session ID: %s\n", session.ID)

	// 6. Send prompt
	resp, err := client.Session.Prompt(ctx, session.ID, opencode.SessionPromptParams{
		Parts: opencode.F([]opencode.SessionPromptParamsPart{
			// TODO: figure out exact part construction
		}),
	})
	if err != nil {
		log.Fatal("Prompt failed:", err)
	}
	fmt.Printf("Response: %+v\n", resp)
}
```

- [ ] **Step 0.3: Run the spike and document findings**

```bash
cd spike
go run main.go
```

Document:
- Does `opencode serve --port 4096` work?
- What does the health response look like?
- How exactly do you construct `SessionPromptParamsPart` for a text message?
- What does the prompt response look like? Which field contains the text?
- How long does startup take?
- Any auth required to connect?

Update the spike code based on findings. This becomes reference code for the real implementation.

- [ ] **Step 0.4: Commit spike**

```bash
git add spike/
git commit -m "add opencode sdk spike"
```

---

### Task 1: Project Scaffolding

**Files:**
- Create: `go.mod`
- Create: `cmd/druzhok/main.go`
- Create: `Makefile`
- Create: `.gitignore`
- Create: `.opencode/agents/default.md`

- [ ] **Step 1.1: Initialize Go module**

```bash
go mod init github.com/igorkuznetsov/druzhok
```

- [ ] **Step 1.2: Create `.gitignore`**

Create `.gitignore`:

```
data/
*.db
*.db-wal
*.db-shm
.env
credentials.yaml
spike/
nanoclaw/
```

- [ ] **Step 1.3: Create Makefile**

Create `Makefile`:

```makefile
.PHONY: build run test clean

build:
	go build -o bin/druzhok ./cmd/druzhok

run:
	go run ./cmd/druzhok

test:
	go test ./internal/... -v

clean:
	rm -rf bin/ data/
```

- [ ] **Step 1.4: Create main.go stub**

Create `cmd/druzhok/main.go`:

```go
package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Println("druzhok starting...")
	os.Exit(0)
}
```

- [ ] **Step 1.5: Create default OpenCode agent**

Create `.opencode/agents/default.md`:

```markdown
---
name: default
description: General-purpose assistant for Druzhok
mode: primary
---
You are a helpful assistant running inside Druzhok.
Follow any system context provided with each message.
Be concise and direct in your responses.
```

- [ ] **Step 1.6: Verify build**

```bash
make build
```

Expected: binary at `bin/druzhok`, runs and prints "druzhok starting..."

- [ ] **Step 1.7: Commit**

```bash
git add go.mod cmd/ Makefile .gitignore .opencode/
git commit -m "scaffold druzhok project"
```

---

### Task 2: Configuration

**Files:**
- Create: `internal/config/config.go`
- Create: `internal/config/config_test.go`

- [ ] **Step 2.1: Write config tests**

Create `internal/config/config_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadFromEnv(t *testing.T) {
	t.Setenv("DRUZHOK_TELEGRAM_TOKEN", "test-token")
	t.Setenv("ANTHROPIC_API_KEY", "sk-test")

	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TelegramToken != "test-token" {
		t.Errorf("got %q, want %q", cfg.TelegramToken, "test-token")
	}
	if cfg.Providers["anthropic"] != "sk-test" {
		t.Errorf("got %q, want %q", cfg.Providers["anthropic"], "sk-test")
	}
}

func TestLoadFromCredentialsFile(t *testing.T) {
	dir := t.TempDir()
	credsPath := filepath.Join(dir, "credentials.yaml")
	err := os.WriteFile(credsPath, []byte(`
telegram:
  bot_token: "file-token"
providers:
  openai:
    api_key: "sk-file"
`), 0600)
	if err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadFromFile(credsPath)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.TelegramToken != "file-token" {
		t.Errorf("got %q, want %q", cfg.TelegramToken, "file-token")
	}
	if cfg.Providers["openai"] != "sk-file" {
		t.Errorf("got %q, want %q", cfg.Providers["openai"], "sk-file")
	}
}

func TestEnvOverridesFile(t *testing.T) {
	dir := t.TempDir()
	credsPath := filepath.Join(dir, "credentials.yaml")
	os.WriteFile(credsPath, []byte(`
telegram:
  bot_token: "file-token"
`), 0600)

	t.Setenv("DRUZHOK_TELEGRAM_TOKEN", "env-token")

	cfg, err := LoadFromFile(credsPath)
	if err != nil {
		t.Fatal(err)
	}

	// Apply env overrides
	cfg.ApplyEnvOverrides()

	if cfg.TelegramToken != "env-token" {
		t.Errorf("env should override file: got %q, want %q", cfg.TelegramToken, "env-token")
	}
}

func TestDefaultValues(t *testing.T) {
	cfg := Defaults()
	if cfg.OpenCodePort != 4096 {
		t.Errorf("default port: got %d, want 4096", cfg.OpenCodePort)
	}
	if cfg.MaxConcurrentPrompts != 5 {
		t.Errorf("default concurrency: got %d, want 5", cfg.MaxConcurrentPrompts)
	}
	if cfg.PollInterval.Seconds() != 2 {
		t.Errorf("default poll: got %v, want 2s", cfg.PollInterval)
	}
}

func TestValidation(t *testing.T) {
	cfg := &Config{}
	err := cfg.Validate()
	if err == nil {
		t.Error("expected validation error for missing telegram token")
	}
}
```

- [ ] **Step 2.2: Run tests to verify they fail**

```bash
go test ./internal/config/ -v
```

Expected: compilation error (package doesn't exist yet)

- [ ] **Step 2.3: Implement config**

Create `internal/config/config.go`:

```go
package config

import (
	"errors"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	TelegramToken        string            `yaml:"-"`
	Providers            map[string]string  `yaml:"-"`
	OpenCodePort         int               `yaml:"-"`
	OpenCodeHost         string            `yaml:"-"`
	MaxConcurrentPrompts int               `yaml:"-"`
	PollInterval         time.Duration     `yaml:"-"`
	DataDir              string            `yaml:"-"`
	LogLevel             string            `yaml:"-"`
}

type credentialsFile struct {
	Telegram struct {
		BotToken string `yaml:"bot_token"`
	} `yaml:"telegram"`
	Providers map[string]struct {
		APIKey string `yaml:"api_key"`
	} `yaml:"providers"`
}

func Defaults() *Config {
	return &Config{
		Providers:            make(map[string]string),
		OpenCodePort:         4096,
		OpenCodeHost:         "127.0.0.1",
		MaxConcurrentPrompts: 5,
		PollInterval:         2 * time.Second,
		DataDir:              "data",
		LogLevel:             "info",
	}
}

func Load() (*Config, error) {
	cfg := Defaults()
	cfg.ApplyEnvOverrides()
	return cfg, nil
}

func LoadFromFile(path string) (*Config, error) {
	cfg := Defaults()

	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return cfg, nil
		}
		return nil, err
	}

	var creds credentialsFile
	if err := yaml.Unmarshal(data, &creds); err != nil {
		return nil, err
	}

	if creds.Telegram.BotToken != "" {
		cfg.TelegramToken = creds.Telegram.BotToken
	}
	for name, prov := range creds.Providers {
		if prov.APIKey != "" {
			cfg.Providers[name] = prov.APIKey
		}
	}

	return cfg, nil
}

func (c *Config) ApplyEnvOverrides() {
	if v := os.Getenv("DRUZHOK_TELEGRAM_TOKEN"); v != "" {
		c.TelegramToken = v
	}
	if v := os.Getenv("ANTHROPIC_API_KEY"); v != "" {
		c.Providers["anthropic"] = v
	}
	if v := os.Getenv("OPENAI_API_KEY"); v != "" {
		c.Providers["openai"] = v
	}
	if v := os.Getenv("DRUZHOK_LOG_LEVEL"); v != "" {
		c.LogLevel = v
	}
}

func (c *Config) Validate() error {
	if c.TelegramToken == "" {
		return errors.New("telegram bot token required: set DRUZHOK_TELEGRAM_TOKEN or configure in credentials.yaml")
	}
	return nil
}

func DefaultCredentialsPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "druzhok", "credentials.yaml")
}
```

- [ ] **Step 2.4: Add yaml dependency and run tests**

```bash
go get gopkg.in/yaml.v3
go test ./internal/config/ -v
```

Expected: all tests pass

- [ ] **Step 2.5: Commit**

```bash
git add internal/config/ go.mod go.sum
git commit -m "add config loading with env/file priority"
```

---

### Task 3: Database Layer

**Files:**
- Create: `internal/db/db.go`
- Create: `internal/db/users.go`
- Create: `internal/db/chats.go`
- Create: `internal/db/messages.go`
- Create: `internal/db/db_test.go`

- [ ] **Step 3.1: Write database tests**

Create `internal/db/db_test.go`:

```go
package db

import (
	"testing"
)

func testDB(t *testing.T) *DB {
	t.Helper()
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

func TestMigrations(t *testing.T) {
	d := testDB(t)
	// Running Open twice should be idempotent
	if err := d.Migrate(); err != nil {
		t.Fatal(err)
	}
}

func TestCreateAndGetUser(t *testing.T) {
	d := testDB(t)

	u, err := d.CreateUser(12345, "Igor")
	if err != nil {
		t.Fatal(err)
	}
	if u.Name != "Igor" {
		t.Errorf("got %q, want %q", u.Name, "Igor")
	}
	if !u.IsAdmin {
		t.Error("first user should be admin")
	}

	got, err := d.GetUserByTgID(12345)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != u.ID {
		t.Errorf("got %q, want %q", got.ID, u.ID)
	}

	// Second user is NOT admin
	u2, err := d.CreateUser(67890, "Other")
	if err != nil {
		t.Fatal(err)
	}
	if u2.IsAdmin {
		t.Error("second user should not be admin")
	}
}

func TestCreateAndGetChat(t *testing.T) {
	d := testDB(t)
	u, _ := d.CreateUser(12345, "Igor")

	chat, err := d.CreateChat(u.ID, -100123, "Family")
	if err != nil {
		t.Fatal(err)
	}
	if chat.Name != "Family" {
		t.Errorf("got %q, want %q", chat.Name, "Family")
	}

	got, err := d.GetChatByTgID(-100123)
	if err != nil {
		t.Fatal(err)
	}
	if got.ID != chat.ID {
		t.Errorf("got %q, want %q", got.ID, chat.ID)
	}
}

func TestUpdateSystemPrompt(t *testing.T) {
	d := testDB(t)
	u, _ := d.CreateUser(12345, "Igor")
	chat, _ := d.CreateChat(u.ID, -100123, "Family")

	err := d.UpdateSystemPrompt(chat.ID, "You are a pirate")
	if err != nil {
		t.Fatal(err)
	}

	got, _ := d.GetChatByTgID(-100123)
	if got.SystemPrompt != "You are a pirate" {
		t.Errorf("got %q, want %q", got.SystemPrompt, "You are a pirate")
	}
}

func TestUpdateSessionID(t *testing.T) {
	d := testDB(t)
	u, _ := d.CreateUser(12345, "Igor")
	chat, _ := d.CreateChat(u.ID, -100123, "Family")

	err := d.UpdateSessionID(chat.ID, "sess_abc")
	if err != nil {
		t.Fatal(err)
	}

	got, _ := d.GetChatByTgID(-100123)
	if got.OCSessionID != "sess_abc" {
		t.Errorf("got %q, want %q", got.OCSessionID, "sess_abc")
	}
}

func TestMessageLifecycle(t *testing.T) {
	d := testDB(t)
	u, _ := d.CreateUser(12345, "Igor")
	chat, _ := d.CreateChat(u.ID, -100123, "Family")

	msg, err := d.SaveMessage(chat.ID, 999, "user", "Hello")
	if err != nil {
		t.Fatal(err)
	}
	if msg.Status != "pending" {
		t.Errorf("got %q, want %q", msg.Status, "pending")
	}

	pending, err := d.GetPendingMessages()
	if err != nil {
		t.Fatal(err)
	}
	if len(pending) != 1 {
		t.Fatalf("got %d pending, want 1", len(pending))
	}

	err = d.UpdateMessageStatus(msg.ID, "processing")
	if err != nil {
		t.Fatal(err)
	}

	pending, _ = d.GetPendingMessages()
	if len(pending) != 0 {
		t.Errorf("got %d pending after processing, want 0", len(pending))
	}
}

func TestDuplicateChat(t *testing.T) {
	d := testDB(t)
	u, _ := d.CreateUser(12345, "Igor")
	d.CreateChat(u.ID, -100123, "Family")

	_, err := d.CreateChat(u.ID, -100123, "Duplicate")
	if err == nil {
		t.Error("expected error for duplicate tg_chat_id")
	}
}
```

- [ ] **Step 3.2: Run tests to verify they fail**

```bash
go test ./internal/db/ -v
```

Expected: compilation error

- [ ] **Step 3.3: Implement db.go**

Create `internal/db/db.go`:

```go
package db

import (
	"database/sql"
	"fmt"

	"github.com/google/uuid"
	_ "modernc.org/sqlite"
)

type DB struct {
	conn *sql.DB
}

func Open(dsn string) (*DB, error) {
	conn, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}

	// WAL mode for concurrent reads
	if _, err := conn.Exec("PRAGMA journal_mode=WAL"); err != nil {
		conn.Close()
		return nil, fmt.Errorf("set WAL: %w", err)
	}
	if _, err := conn.Exec("PRAGMA foreign_keys=ON"); err != nil {
		conn.Close()
		return nil, fmt.Errorf("enable foreign keys: %w", err)
	}

	d := &DB{conn: conn}
	if err := d.Migrate(); err != nil {
		conn.Close()
		return nil, err
	}

	return d, nil
}

func (d *DB) Migrate() error {
	migrations := []string{
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
		`CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, created_at)`,
		`CREATE INDEX IF NOT EXISTS idx_chats_tg ON chats(tg_chat_id)`,
	}

	for _, m := range migrations {
		if _, err := d.conn.Exec(m); err != nil {
			return fmt.Errorf("migration: %w", err)
		}
	}
	return nil
}

func (d *DB) Close() error {
	return d.conn.Close()
}

func newID() string {
	return uuid.NewString()
}
```

- [ ] **Step 3.4: Implement users.go**

Create `internal/db/users.go`:

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

type User struct {
	ID        string
	TgUserID  int64
	Name      string
	IsAdmin   bool
	CreatedAt time.Time
}

func (d *DB) CreateUser(tgUserID int64, name string) (*User, error) {
	// First user is admin
	var count int
	d.conn.QueryRow("SELECT COUNT(*) FROM users").Scan(&count)
	isAdmin := count == 0

	u := &User{
		ID:       newID(),
		TgUserID: tgUserID,
		Name:     name,
		IsAdmin:  isAdmin,
	}

	_, err := d.conn.Exec(
		"INSERT INTO users (id, tg_user_id, name, is_admin) VALUES (?, ?, ?, ?)",
		u.ID, u.TgUserID, u.Name, boolToInt(u.IsAdmin),
	)
	if err != nil {
		return nil, fmt.Errorf("create user: %w", err)
	}
	return u, nil
}

func (d *DB) GetUserByTgID(tgUserID int64) (*User, error) {
	u := &User{}
	var isAdmin int
	err := d.conn.QueryRow(
		"SELECT id, tg_user_id, name, is_admin, created_at FROM users WHERE tg_user_id = ?",
		tgUserID,
	).Scan(&u.ID, &u.TgUserID, &u.Name, &isAdmin, &u.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	u.IsAdmin = isAdmin == 1
	return u, nil
}

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
```

- [ ] **Step 3.5: Implement chats.go**

Create `internal/db/chats.go`:

```go
package db

import (
	"database/sql"
	"errors"
	"fmt"
	"time"
)

type Chat struct {
	ID           string
	UserID       string
	TgChatID     int64
	OCSessionID  string
	Name         string
	SystemPrompt string
	Model        string
	Status       string
	CreatedAt    time.Time
}

func (d *DB) CreateChat(userID string, tgChatID int64, name string) (*Chat, error) {
	c := &Chat{
		ID:       newID(),
		UserID:   userID,
		TgChatID: tgChatID,
		Name:     name,
		Status:   "active",
	}

	_, err := d.conn.Exec(
		"INSERT INTO chats (id, user_id, tg_chat_id, name) VALUES (?, ?, ?, ?)",
		c.ID, c.UserID, c.TgChatID, c.Name,
	)
	if err != nil {
		return nil, fmt.Errorf("create chat: %w", err)
	}
	return c, nil
}

func (d *DB) GetChatByTgID(tgChatID int64) (*Chat, error) {
	c := &Chat{}
	err := d.conn.QueryRow(
		`SELECT id, user_id, tg_chat_id, oc_session_id, name, system_prompt, model, status, created_at
		 FROM chats WHERE tg_chat_id = ?`,
		tgChatID,
	).Scan(&c.ID, &c.UserID, &c.TgChatID, &c.OCSessionID, &c.Name, &c.SystemPrompt, &c.Model, &c.Status, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get chat: %w", err)
	}
	return c, nil
}

func (d *DB) UpdateSessionID(chatID, sessionID string) error {
	_, err := d.conn.Exec("UPDATE chats SET oc_session_id = ? WHERE id = ?", sessionID, chatID)
	return err
}

func (d *DB) UpdateSystemPrompt(chatID, prompt string) error {
	_, err := d.conn.Exec("UPDATE chats SET system_prompt = ? WHERE id = ?", prompt, chatID)
	return err
}

func (d *DB) UpdateModel(chatID, model string) error {
	_, err := d.conn.Exec("UPDATE chats SET model = ? WHERE id = ?", model, chatID)
	return err
}

func (d *DB) UpdateChatStatus(chatID, status string) error {
	_, err := d.conn.Exec("UPDATE chats SET status = ? WHERE id = ?", status, chatID)
	return err
}
```

- [ ] **Step 3.6: Implement messages.go**

Create `internal/db/messages.go`:

```go
package db

import (
	"fmt"
	"time"
)

type Message struct {
	ID          string
	ChatID      string
	TgMessageID int64
	Role        string
	Text        string
	Status      string
	CreatedAt   time.Time
}

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
		"INSERT INTO messages (id, chat_id, tg_message_id, role, text, status) VALUES (?, ?, ?, ?, ?, ?)",
		m.ID, m.ChatID, m.TgMessageID, m.Role, m.Text, m.Status,
	)
	if err != nil {
		return nil, fmt.Errorf("save message: %w", err)
	}
	return m, nil
}

func (d *DB) UpdateMessageStatus(id, status string) error {
	_, err := d.conn.Exec("UPDATE messages SET status = ? WHERE id = ?", status, id)
	return err
}

func (d *DB) GetPendingMessages() ([]Message, error) {
	rows, err := d.conn.Query(
		`SELECT m.id, m.chat_id, m.tg_message_id, m.role, m.text, m.status, m.created_at
		 FROM messages m
		 JOIN chats c ON m.chat_id = c.id
		 WHERE m.status = 'pending' AND m.role = 'user' AND c.status = 'active'
		 ORDER BY m.created_at ASC`,
	)
	if err != nil {
		return nil, fmt.Errorf("get pending: %w", err)
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var m Message
		if err := rows.Scan(&m.ID, &m.ChatID, &m.TgMessageID, &m.Role, &m.Text, &m.Status, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}
```

- [ ] **Step 3.7: Add SQLite dependency and run tests**

```bash
go get modernc.org/sqlite
go test ./internal/db/ -v
```

Expected: all tests pass

- [ ] **Step 3.8: Commit**

```bash
git add internal/db/ go.mod go.sum
git commit -m "add sqlite database layer"
```

---

### Task 4: OpenCode Server Management

**Files:**
- Create: `internal/opencode/server.go`
- Create: `internal/opencode/server_test.go`

- [ ] **Step 4.1: Write server management tests**

Create `internal/opencode/server_test.go`:

```go
package opencode

import (
	"testing"
	"time"
)

func TestServerConfig(t *testing.T) {
	cfg := ServerConfig{
		Port:       4096,
		Host:       "127.0.0.1",
		WorkingDir: t.TempDir(),
	}

	s := NewServer(cfg)
	if s.baseURL() != "http://127.0.0.1:4096" {
		t.Errorf("got %q, want %q", s.baseURL(), "http://127.0.0.1:4096")
	}
}

func TestHealthCheckURL(t *testing.T) {
	s := NewServer(ServerConfig{Port: 4096, Host: "127.0.0.1"})
	want := "http://127.0.0.1:4096/global/health"
	if got := s.healthURL(); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestMaxRetriesExceeded(t *testing.T) {
	s := NewServer(ServerConfig{
		Port:       19999, // nothing listening
		Host:       "127.0.0.1",
		MaxRetries: 1,
		RetryDelay: 10 * time.Millisecond,
	})
	err := s.waitForHealth()
	if err == nil {
		t.Error("expected error when server not reachable")
	}
}
```

- [ ] **Step 4.2: Run tests to verify they fail**

```bash
go test ./internal/opencode/ -v
```

Expected: compilation error

- [ ] **Step 4.3: Implement server.go**

Create `internal/opencode/server.go`:

```go
package opencode

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"time"
)

type ServerConfig struct {
	Port       int
	Host       string
	WorkingDir string
	MaxRetries int
	RetryDelay time.Duration
}

type Server struct {
	cfg ServerConfig
	cmd *exec.Cmd
	log *slog.Logger
}

func NewServer(cfg ServerConfig) *Server {
	if cfg.MaxRetries == 0 {
		cfg.MaxRetries = 3
	}
	if cfg.RetryDelay == 0 {
		cfg.RetryDelay = 2 * time.Second
	}
	return &Server{
		cfg: cfg,
		log: slog.Default().With("component", "opencode-server"),
	}
}

func (s *Server) baseURL() string {
	return fmt.Sprintf("http://%s:%d", s.cfg.Host, s.cfg.Port)
}

func (s *Server) healthURL() string {
	return s.baseURL() + "/global/health"
}

func (s *Server) Start(ctx context.Context) error {
	s.log.Info("starting opencode serve", "port", s.cfg.Port)

	s.cmd = exec.CommandContext(ctx, "opencode", "serve",
		"--port", fmt.Sprintf("%d", s.cfg.Port),
		"--hostname", s.cfg.Host,
	)
	if s.cfg.WorkingDir != "" {
		s.cmd.Dir = s.cfg.WorkingDir
	}

	// Capture output for debugging
	s.cmd.Stdout = &logWriter{logger: s.log, level: slog.LevelDebug, prefix: "stdout"}
	s.cmd.Stderr = &logWriter{logger: s.log, level: slog.LevelDebug, prefix: "stderr"}

	if err := s.cmd.Start(); err != nil {
		return fmt.Errorf("start opencode: %w", err)
	}

	s.log.Info("opencode serve started", "pid", s.cmd.Process.Pid)
	return s.waitForHealth()
}

func (s *Server) waitForHealth() error {
	client := &http.Client{Timeout: 2 * time.Second}

	for i := 0; i < s.cfg.MaxRetries*10; i++ {
		resp, err := client.Get(s.healthURL())
		if err == nil && resp.StatusCode == http.StatusOK {
			resp.Body.Close()
			s.log.Info("opencode serve is healthy")
			return nil
		}
		if resp != nil {
			resp.Body.Close()
		}
		time.Sleep(s.cfg.RetryDelay)
	}

	return fmt.Errorf("opencode serve not healthy after %d retries", s.cfg.MaxRetries*10)
}

func (s *Server) Stop() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}

	s.log.Info("stopping opencode serve")

	// Try graceful shutdown
	s.cmd.Process.Signal(os.Interrupt)

	done := make(chan error, 1)
	go func() { done <- s.cmd.Wait() }()

	select {
	case err := <-done:
		s.log.Info("opencode serve stopped gracefully")
		return err
	case <-time.After(10 * time.Second):
		s.log.Warn("opencode serve did not stop, killing")
		s.cmd.Process.Kill()
		return <-done
	}
}

func (s *Server) BaseURL() string {
	return s.baseURL()
}

// logWriter adapts slog for use as io.Writer
type logWriter struct {
	logger *slog.Logger
	level  slog.Level
	prefix string
}

func (w *logWriter) Write(p []byte) (n int, err error) {
	w.logger.Log(context.Background(), w.level, string(p), "stream", w.prefix)
	return len(p), nil
}
```

- [ ] **Step 4.4: Run tests**

```bash
go test ./internal/opencode/ -v
```

Expected: all tests pass

- [ ] **Step 4.5: Commit**

```bash
git add internal/opencode/ go.mod go.sum
git commit -m "add opencode server lifecycle management"
```

---

### Task 5: OpenCode Client Wrapper

**Files:**
- Create: `internal/opencode/client.go`
- Create: `internal/opencode/client_test.go`

- [ ] **Step 5.1: Write client tests**

Create `internal/opencode/client_test.go`:

```go
package opencode

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCreateSession(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" || r.URL.Path != "/session" {
			t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		json.NewEncoder(w).Encode(map[string]any{
			"id": "sess_test123",
		})
	}))
	defer ts.Close()

	c := NewClient(ts.URL)
	id, err := c.CreateSession()
	if err != nil {
		t.Fatal(err)
	}
	if id != "sess_test123" {
		t.Errorf("got %q, want %q", id, "sess_test123")
	}
}

func TestSendPrompt(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/session/sess_test/message" {
			// Return a mock response
			json.NewEncoder(w).Encode(map[string]any{
				"parts": []map[string]any{
					{"type": "text", "text": "Hello! I'm your assistant."},
				},
			})
			return
		}
		t.Errorf("unexpected request: %s %s", r.Method, r.URL.Path)
	}))
	defer ts.Close()

	c := NewClient(ts.URL)
	resp, err := c.SendPrompt("sess_test", "Hello")
	if err != nil {
		t.Fatal(err)
	}
	if resp != "Hello! I'm your assistant." {
		t.Errorf("got %q", resp)
	}
}

func TestSendPromptError(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer ts.Close()

	c := NewClient(ts.URL)
	_, err := c.SendPrompt("sess_test", "Hello")
	if err == nil {
		t.Error("expected error for 500 response")
	}
}
```

- [ ] **Step 5.2: Run tests to verify they fail**

```bash
go test ./internal/opencode/ -v -run TestCreate
```

Expected: compilation error

- [ ] **Step 5.3: Implement client.go**

Create `internal/opencode/client.go`:

```go
package opencode

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// Client wraps the OpenCode REST API.
// We use raw HTTP instead of the Go SDK to keep the dependency light
// and have full control over request/response handling.
// If the SDK proves more reliable, we can swap this out.
type Client struct {
	baseURL string
	http    *http.Client
	log     *slog.Logger
}

func NewClient(baseURL string) *Client {
	return &Client{
		baseURL: baseURL,
		http:    &http.Client{Timeout: 5 * time.Minute},
		log:     slog.Default().With("component", "opencode-client"),
	}
}

func (c *Client) CreateSession() (string, error) {
	resp, err := c.post("/session", nil)
	if err != nil {
		return "", fmt.Errorf("create session: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode session: %w", err)
	}

	c.log.Info("session created", "id", result.ID)
	return result.ID, nil
}

func (c *Client) SendPrompt(sessionID, prompt string) (string, error) {
	body := map[string]any{
		"parts": []map[string]any{
			{"type": "text", "text": prompt},
		},
	}

	c.log.Debug("sending prompt", "session", sessionID, "length", len(prompt))

	resp, err := c.post(fmt.Sprintf("/session/%s/message", sessionID), body)
	if err != nil {
		return "", fmt.Errorf("send prompt: %w", err)
	}
	defer resp.Body.Close()

	var result struct {
		Parts []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"parts"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", fmt.Errorf("decode response: %w", err)
	}

	// Extract text from parts
	var text string
	for _, p := range result.Parts {
		if p.Type == "text" {
			text += p.Text
		}
	}

	c.log.Debug("prompt response", "session", sessionID, "length", len(text))
	return text, nil
}

func (c *Client) AbortSession(sessionID string) error {
	resp, err := c.post(fmt.Sprintf("/session/%s/abort", sessionID), nil)
	if err != nil {
		return fmt.Errorf("abort session: %w", err)
	}
	resp.Body.Close()
	return nil
}

func (c *Client) DeleteSession(sessionID string) error {
	req, err := http.NewRequest("DELETE", c.baseURL+"/session/"+sessionID, nil)
	if err != nil {
		return err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("delete session: %w", err)
	}
	resp.Body.Close()
	return nil
}

func (c *Client) post(path string, body any) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		data, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(data)
	}

	req, err := http.NewRequest("POST", c.baseURL+path, reader)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode >= 400 {
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(respBody))
	}

	return resp, nil
}
```

**Note:** This uses raw HTTP instead of the Go SDK. The spike (Task 0) may reveal that the SDK is preferable — adjust this implementation based on spike findings.

- [ ] **Step 5.4: Run tests**

```bash
go test ./internal/opencode/ -v
```

Expected: all tests pass

- [ ] **Step 5.5: Commit**

```bash
git add internal/opencode/
git commit -m "add opencode client wrapper"
```

---

### Task 6: Skills System

**Files:**
- Create: `internal/skills/loader.go`
- Create: `internal/skills/registry.go`
- Create: `internal/skills/skills_test.go`
- Create: `skills/setup/SKILL.md`
- Create: `skills/customize/SKILL.md`
- Create: `skills/debug/SKILL.md`

- [ ] **Step 6.1: Write skills tests**

Create `internal/skills/skills_test.go`:

```go
package skills

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeSkill(t *testing.T, dir, name, content string) {
	t.Helper()
	skillDir := filepath.Join(dir, name)
	os.MkdirAll(skillDir, 0755)
	os.WriteFile(filepath.Join(skillDir, "SKILL.md"), []byte(content), 0644)
}

func TestLoadSkill(t *testing.T) {
	dir := t.TempDir()
	writeSkill(t, dir, "test-skill", `---
name: test-skill
description: A test skill
triggers:
  - "^/test$"
  - "test me"
---
# Test Skill
Do the test thing.
`)

	skill, err := LoadSkill(filepath.Join(dir, "test-skill", "SKILL.md"))
	if err != nil {
		t.Fatal(err)
	}
	if skill.Name != "test-skill" {
		t.Errorf("name: got %q, want %q", skill.Name, "test-skill")
	}
	if skill.Description != "A test skill" {
		t.Errorf("desc: got %q, want %q", skill.Description, "A test skill")
	}
	if len(skill.Triggers) != 2 {
		t.Fatalf("triggers: got %d, want 2", len(skill.Triggers))
	}
	if skill.Body == "" {
		t.Error("body should not be empty")
	}
}

func TestRegistryDiscover(t *testing.T) {
	dir := t.TempDir()
	writeSkill(t, dir, "setup", `---
name: setup
description: Setup
triggers:
  - "^/setup$"
---
Setup instructions.
`)
	writeSkill(t, dir, "debug", `---
name: debug
description: Debug
triggers:
  - "^/debug$"
---
Debug instructions.
`)

	reg, err := NewRegistry(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(reg.skills) != 2 {
		t.Errorf("got %d skills, want 2", len(reg.skills))
	}
}

func TestRegistryMatch(t *testing.T) {
	dir := t.TempDir()
	writeSkill(t, dir, "setup", `---
name: setup
description: Setup
triggers:
  - "^/setup$"
  - "help me set up"
---
Setup instructions here.
`)

	reg, _ := NewRegistry(dir)

	tests := []struct {
		input string
		match bool
	}{
		{"/setup", true},
		{"/setup extra", false},
		{"help me set up", true},
		{"hello", false},
		{"/debug", false},
	}

	for _, tt := range tests {
		skill := reg.Match(tt.input)
		got := skill != nil
		if got != tt.match {
			t.Errorf("Match(%q) = %v, want %v", tt.input, got, tt.match)
		}
	}
}

func TestBuildSkillPrompt(t *testing.T) {
	s := &Skill{
		Name: "customize",
		Body: "# Customize\nHelp the user customize.",
	}
	prompt := s.BuildPrompt("speak Russian")
	if prompt == "" {
		t.Error("prompt should not be empty")
	}
	if !strings.Contains(prompt, "Customize") || !strings.Contains(prompt, "speak Russian") {
		t.Errorf("prompt missing expected content: %s", prompt)
	}
}
```

- [ ] **Step 6.2: Run tests to verify they fail**

```bash
go test ./internal/skills/ -v
```

Expected: compilation error

- [ ] **Step 6.3: Implement loader.go**

Create `internal/skills/loader.go`:

```go
package skills

import (
	"fmt"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

type Skill struct {
	Name        string   `yaml:"name"`
	Description string   `yaml:"description"`
	Triggers    []string `yaml:"triggers"`
	Body        string   `yaml:"-"`
}

func LoadSkill(path string) (*Skill, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read skill: %w", err)
	}

	content := string(data)

	// Parse YAML frontmatter between --- delimiters
	if !strings.HasPrefix(content, "---") {
		return nil, fmt.Errorf("skill %s: missing YAML frontmatter", path)
	}

	parts := strings.SplitN(content[3:], "---", 2)
	if len(parts) < 2 {
		return nil, fmt.Errorf("skill %s: malformed frontmatter", path)
	}

	var skill Skill
	if err := yaml.Unmarshal([]byte(parts[0]), &skill); err != nil {
		return nil, fmt.Errorf("skill %s: parse frontmatter: %w", path, err)
	}

	skill.Body = strings.TrimSpace(parts[1])
	return &skill, nil
}

func (s *Skill) BuildPrompt(userInput string) string {
	if userInput == "" {
		return s.Body
	}
	return fmt.Sprintf("%s\n\nUser request: %s", s.Body, userInput)
}
```

- [ ] **Step 6.4: Implement registry.go**

Create `internal/skills/registry.go`:

```go
package skills

import (
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"regexp"
)

type Registry struct {
	skills []*Skill
	log    *slog.Logger
}

func NewRegistry(dir string) (*Registry, error) {
	reg := &Registry{
		log: slog.Default().With("component", "skills"),
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read skills dir: %w", err)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		skillPath := filepath.Join(dir, entry.Name(), "SKILL.md")
		if _, err := os.Stat(skillPath); err != nil {
			continue
		}

		skill, err := LoadSkill(skillPath)
		if err != nil {
			reg.log.Warn("failed to load skill", "path", skillPath, "error", err)
			continue
		}

		reg.skills = append(reg.skills, skill)
		reg.log.Info("loaded skill", "name", skill.Name, "triggers", len(skill.Triggers))
	}

	return reg, nil
}

func (r *Registry) Match(input string) *Skill {
	for _, s := range r.skills {
		for _, trigger := range s.Triggers {
			re, err := regexp.Compile(trigger)
			if err != nil {
				continue
			}
			if re.MatchString(input) {
				return s
			}
		}
	}
	return nil
}

func (r *Registry) Get(name string) *Skill {
	for _, s := range r.skills {
		if s.Name == name {
			return s
		}
	}
	return nil
}
```

- [ ] **Step 6.5: Create built-in skill files**

Create `skills/setup/SKILL.md`:

```markdown
---
name: setup
description: Guided first-time Druzhok installation and configuration
triggers:
  - "^/setup$"
---
# Druzhok Setup

You are helping the user set up Druzhok. Walk them through these steps:

1. Verify OpenCode is installed (`opencode --version`)
2. Check that the Telegram bot is connected
3. Verify AI provider credentials are working
4. Send a test message to confirm everything works

Be helpful and fix issues as you find them. Don't tell the user to fix things themselves.
```

Create `skills/customize/SKILL.md`:

```markdown
---
name: customize
description: Change chat behavior, system prompt, or model settings
triggers:
  - "^/customize"
---
# Customize Chat

The user wants to change how this chat behaves. Help them by:

1. Understanding what they want to change
2. Suggesting the right command:
   - `/prompt <text>` to set a new system prompt
   - `/model <provider/model>` to switch AI models
   - `/reset` to start a fresh conversation
3. Explaining what each change does
```

Create `skills/debug/SKILL.md`:

```markdown
---
name: debug
description: Troubleshoot Druzhok issues
triggers:
  - "^/debug$"
---
# Debug Druzhok

Help the user troubleshoot issues. Check:

1. OpenCode server status — is it running and healthy?
2. Recent errors in logs
3. Session state — is the chat mapped to a valid session?
4. Message queue — are there stuck messages?

Provide actionable fixes, not just diagnostics.
```

- [ ] **Step 6.6: Run tests**

```bash
go test ./internal/skills/ -v
```

Expected: all tests pass

- [ ] **Step 6.7: Commit**

```bash
git add internal/skills/ skills/
git commit -m "add skills system with loader and registry"
```

---

### Task 7: Telegram Bot

**Files:**
- Create: `internal/telegram/bot.go`
- Create: `internal/telegram/handler.go`
- Create: `internal/telegram/sender.go`
- Create: `internal/telegram/handler_test.go`
- Create: `internal/telegram/sender_test.go`

- [ ] **Step 7.1: Write handler tests**

Create `internal/telegram/handler_test.go`:

```go
package telegram

import (
	"testing"
)

func TestClassifyMessage(t *testing.T) {
	tests := []struct {
		text string
		kind MessageKind
		cmd  string
		args string
	}{
		{"/start", KindCommand, "start", ""},
		{"/prompt You are a pirate", KindCommand, "prompt", "You are a pirate"},
		{"/model openai/gpt-4o", KindCommand, "model", "openai/gpt-4o"},
		{"/reset", KindCommand, "reset", ""},
		{"/stop", KindCommand, "stop", ""},
		{"hello there", KindRegular, "", ""},
		{"/unknown_cmd", KindRegular, "", ""}, // unknown commands are regular messages
	}

	commands := map[string]bool{
		"start": true, "stop": true, "reset": true,
		"prompt": true, "model": true,
	}

	for _, tt := range tests {
		kind, cmd, args := ClassifyMessage(tt.text, commands)
		if kind != tt.kind {
			t.Errorf("ClassifyMessage(%q) kind = %v, want %v", tt.text, kind, tt.kind)
		}
		if cmd != tt.cmd {
			t.Errorf("ClassifyMessage(%q) cmd = %q, want %q", tt.text, cmd, tt.cmd)
		}
		if args != tt.args {
			t.Errorf("ClassifyMessage(%q) args = %q, want %q", tt.text, args, tt.args)
		}
	}
}
```

- [ ] **Step 7.2: Write sender tests**

Create `internal/telegram/sender_test.go`:

```go
package telegram

import (
	"testing"
)

func TestSplitMessage(t *testing.T) {
	tests := []struct {
		name   string
		text   string
		limit  int
		chunks int
	}{
		{"short", "hello", 4096, 1},
		{"exact", string(make([]byte, 4096)), 4096, 1},
		{"split", string(make([]byte, 5000)), 4096, 2},
		{"multi", string(make([]byte, 10000)), 4096, 3},
		{"empty", "", 4096, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			chunks := SplitMessage(tt.text, tt.limit)
			if len(chunks) != tt.chunks {
				t.Errorf("got %d chunks, want %d", len(chunks), tt.chunks)
			}
			// Verify all content is preserved
			var joined string
			for _, c := range chunks {
				joined += c
			}
			if joined != tt.text {
				t.Error("content not preserved after split")
			}
		})
	}
}
```

- [ ] **Step 7.3: Run tests to verify they fail**

```bash
go test ./internal/telegram/ -v
```

Expected: compilation error

- [ ] **Step 7.4: Implement handler.go**

Create `internal/telegram/handler.go`:

```go
package telegram

import (
	"strings"
)

type MessageKind int

const (
	KindRegular MessageKind = iota
	KindCommand
)

// ClassifyMessage determines if a message is a built-in command or regular text.
// Returns (kind, commandName, arguments).
func ClassifyMessage(text string, knownCommands map[string]bool) (MessageKind, string, string) {
	if !strings.HasPrefix(text, "/") {
		return KindRegular, "", ""
	}

	// Extract command name (strip leading /)
	parts := strings.SplitN(text[1:], " ", 2)
	cmd := strings.ToLower(parts[0])

	// Strip @botname suffix if present
	if at := strings.Index(cmd, "@"); at != -1 {
		cmd = cmd[:at]
	}

	if !knownCommands[cmd] {
		return KindRegular, "", ""
	}

	args := ""
	if len(parts) > 1 {
		args = strings.TrimSpace(parts[1])
	}

	return KindCommand, cmd, args
}
```

- [ ] **Step 7.5: Implement sender.go**

Create `internal/telegram/sender.go`:

```go
package telegram

import "unicode/utf8"

// SplitMessage breaks text into chunks of at most `limit` bytes,
// splitting on rune boundaries to avoid corrupting UTF-8.
func SplitMessage(text string, limit int) []string {
	if text == "" {
		return nil
	}
	if len(text) <= limit {
		return []string{text}
	}

	var chunks []string
	for len(text) > 0 {
		if len(text) <= limit {
			chunks = append(chunks, text)
			break
		}
		// Find the last valid rune boundary at or before limit
		end := limit
		for end > 0 && !utf8.RuneStart(text[end]) {
			end--
		}
		if end == 0 {
			end = limit // fallback: shouldn't happen with valid UTF-8
		}
		chunks = append(chunks, text[:end])
		text = text[end:]
	}
	return chunks
}

const TelegramMessageLimit = 4096
```

- [ ] **Step 7.6: Implement bot.go**

Create `internal/telegram/bot.go`:

```go
package telegram

import (
	"context"
	"log/slog"

	tgbot "github.com/go-telegram/bot"
	"github.com/go-telegram/bot/models"
)

// Handler is called for each incoming Telegram message.
type Handler func(ctx context.Context, chatID int64, userID int64, userName string, messageID int, text string)

type Bot struct {
	bot     *tgbot.Bot
	handler Handler
	log     *slog.Logger
}

func NewBot(token string, handler Handler) (*Bot, error) {
	b := &Bot{
		handler: handler,
		log:     slog.Default().With("component", "telegram"),
	}

	opts := []tgbot.Option{
		tgbot.WithDefaultHandler(b.onMessage),
	}

	bot, err := tgbot.New(token, opts...)
	if err != nil {
		return nil, err
	}
	b.bot = bot

	return b, nil
}

func (b *Bot) Start(ctx context.Context) {
	b.log.Info("telegram bot starting")
	b.bot.Start(ctx)
}

func (b *Bot) SendMessage(ctx context.Context, chatID int64, text string) error {
	chunks := SplitMessage(text, TelegramMessageLimit)
	for _, chunk := range chunks {
		_, err := b.bot.SendMessage(ctx, &tgbot.SendMessageParams{
			ChatID: chatID,
			Text:   chunk,
		})
		if err != nil {
			return err
		}
	}
	return nil
}

func (b *Bot) onMessage(ctx context.Context, bot *tgbot.Bot, update *models.Update) {
	if update.Message == nil || update.Message.Text == "" {
		return
	}

	msg := update.Message
	b.log.Debug("received message",
		"chat_id", msg.Chat.ID,
		"user_id", msg.From.ID,
		"text_len", len(msg.Text),
	)

	userName := msg.From.FirstName
	if msg.From.LastName != "" {
		userName += " " + msg.From.LastName
	}

	b.handler(ctx, msg.Chat.ID, msg.From.ID, userName, msg.ID, msg.Text)
}
```

- [ ] **Step 7.7: Add telegram bot dependency and run tests**

```bash
go get github.com/go-telegram/bot
go test ./internal/telegram/ -v
```

Expected: all tests pass

- [ ] **Step 7.8: Commit**

```bash
git add internal/telegram/ go.mod go.sum
git commit -m "add telegram bot with message handling"
```

---

### Task 8: Message Processor

**Files:**
- Create: `internal/processor/processor.go`
- Create: `internal/processor/processor_test.go`

- [ ] **Step 8.1: Write processor tests**

Create `internal/processor/processor_test.go`:

```go
package processor

import (
	"strings"
	"testing"
)

func TestBuildPrompt(t *testing.T) {
	tests := []struct {
		name         string
		systemPrompt string
		userMessage  string
		wantContains string
		wantMissing  string
	}{
		{
			name:         "no system prompt",
			systemPrompt: "",
			userMessage:  "Hello",
			wantContains: "Hello",
			wantMissing:  "system-context",
		},
		{
			name:         "with system prompt",
			systemPrompt: "You are a pirate",
			userMessage:  "Hello",
			wantContains: "You are a pirate",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := BuildPrompt(tt.systemPrompt, tt.userMessage)
			if tt.wantContains != "" && !strings.Contains(got, tt.wantContains) {
				t.Errorf("prompt missing %q: %s", tt.wantContains, got)
			}
			if tt.wantMissing != "" && strings.Contains(got, tt.wantMissing) {
				t.Errorf("prompt should not contain %q: %s", tt.wantMissing, got)
			}
		})
	}
}
```

- [ ] **Step 8.2: Run tests to verify they fail**

```bash
go test ./internal/processor/ -v
```

Expected: compilation error

- [ ] **Step 8.3: Implement processor.go**

Create `internal/processor/processor.go`:

```go
package processor

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
)

type Processor struct {
	db     *db.DB
	client *opencode.Client
	sem    chan struct{}
	log    *slog.Logger
}

func New(database *db.DB, client *opencode.Client, maxConcurrent int) *Processor {
	return &Processor{
		db:     database,
		client: client,
		sem:    make(chan struct{}, maxConcurrent),
		log:    slog.Default().With("component", "processor"),
	}
}

func BuildPrompt(systemPrompt, userMessage string) string {
	if systemPrompt != "" {
		return fmt.Sprintf("<system-context>\n%s\n</system-context>\n\n%s", systemPrompt, userMessage)
	}
	return userMessage
}

// Process handles a single user message: builds prompt, calls OpenCode, stores response.
// Returns the assistant's response text.
func (p *Processor) Process(ctx context.Context, msg db.Message, chat *db.Chat) (string, error) {
	// Acquire concurrency slot
	select {
	case p.sem <- struct{}{}:
		defer func() { <-p.sem }()
	case <-ctx.Done():
		return "", ctx.Err()
	}

	p.log.Info("processing message", "chat", chat.Name, "msg_id", msg.ID)

	// Update status
	if err := p.db.UpdateMessageStatus(msg.ID, "processing"); err != nil {
		return "", fmt.Errorf("update status: %w", err)
	}

	// Ensure session exists
	sessionID := chat.OCSessionID
	if sessionID == "" {
		var err error
		sessionID, err = p.client.CreateSession()
		if err != nil {
			return "", fmt.Errorf("create session: %w", err)
		}
		if err := p.db.UpdateSessionID(chat.ID, sessionID); err != nil {
			return "", fmt.Errorf("save session: %w", err)
		}
		p.log.Info("created session", "chat", chat.Name, "session", sessionID)
	}

	// Build and send prompt
	prompt := BuildPrompt(chat.SystemPrompt, msg.Text)
	response, err := p.client.SendPrompt(sessionID, prompt)
	if err != nil {
		return "", fmt.Errorf("send prompt: %w", err)
	}

	// Save assistant message
	_, err = p.db.SaveMessage(chat.ID, 0, "assistant", response)
	if err != nil {
		return "", fmt.Errorf("save response: %w", err)
	}

	// Update user message status
	if err := p.db.UpdateMessageStatus(msg.ID, "completed"); err != nil {
		return "", fmt.Errorf("update completed: %w", err)
	}

	p.log.Info("message processed", "chat", chat.Name, "response_len", len(response))
	return response, nil
}
```

- [ ] **Step 8.4: Run tests**

```bash
go test ./internal/processor/ -v
```

Expected: all tests pass

- [ ] **Step 8.5: Commit**

```bash
git add internal/processor/
git commit -m "add message processor with concurrency control"
```

---

### Task 9: Wire Everything Together

**Files:**
- Modify: `cmd/druzhok/main.go`

- [ ] **Step 9.1: Implement the App struct**

The App struct holds all dependencies, solving the circular reference between the bot and handler.

Rewrite `cmd/druzhok/main.go`:

```go
package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/igorkuznetsov/druzhok/internal/config"
	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
	"github.com/igorkuznetsov/druzhok/internal/processor"
	"github.com/igorkuznetsov/druzhok/internal/skills"
	"github.com/igorkuznetsov/druzhok/internal/telegram"
)

type App struct {
	cfg      *config.Config
	db       *db.DB
	server   *opencode.Server
	client   *opencode.Client
	bot      *telegram.Bot
	proc     *processor.Processor
	skills   *skills.Registry
	wg       sync.WaitGroup
	commands map[string]bool
}

func main() {
	// Load config
	cfg, err := config.LoadFromFile(config.DefaultCredentialsPath())
	if err != nil {
		slog.Warn("no credentials file", "error", err)
		cfg, _ = config.Load()
	}
	cfg.ApplyEnvOverrides()

	// Setup logging
	level := slog.LevelInfo
	switch strings.ToLower(cfg.LogLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))

	if err := cfg.Validate(); err != nil {
		slog.Error("config validation failed", "error", err)
		os.Exit(1)
	}

	// Context with graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	// Open database
	os.MkdirAll(cfg.DataDir, 0755)
	database, err := db.Open(filepath.Join(cfg.DataDir, "druzhok.db"))
	if err != nil {
		slog.Error("failed to open database", "error", err)
		os.Exit(1)
	}
	defer database.Close()

	// Start OpenCode server
	server := opencode.NewServer(opencode.ServerConfig{
		Port:       cfg.OpenCodePort,
		Host:       cfg.OpenCodeHost,
		WorkingDir: ".",
	})
	if err := server.Start(ctx); err != nil {
		slog.Error("failed to start opencode", "error", err)
		os.Exit(1)
	}
	defer server.Stop()

	// Create OpenCode client
	client := opencode.NewClient(server.BaseURL())

	// Load skills
	registry, err := skills.NewRegistry("skills")
	if err != nil {
		slog.Warn("failed to load skills", "error", err)
		registry, _ = skills.NewRegistry(os.TempDir())
	}

	app := &App{
		cfg:    cfg,
		db:     database,
		server: server,
		client: client,
		proc:   processor.New(database, client, cfg.MaxConcurrentPrompts),
		skills: registry,
		commands: map[string]bool{
			"start": true, "stop": true, "reset": true,
			"prompt": true, "model": true,
		},
	}

	// Create Telegram bot — handler references app.bot via app struct
	bot, err := telegram.NewBot(cfg.TelegramToken, app.handleMessage)
	if err != nil {
		slog.Error("failed to create telegram bot", "error", err)
		os.Exit(1)
	}
	app.bot = bot

	// Start health monitor for OpenCode server
	go app.monitorHealth(ctx)

	// Start message retry loop (polls for failed/pending messages)
	go app.retryLoop(ctx)

	// Start Telegram bot
	go bot.Start(ctx)
	slog.Info("druzhok started", "port", cfg.OpenCodePort)

	// Wait for shutdown signal
	<-sigCh
	slog.Info("shutting down, waiting for in-flight requests...")
	cancel()

	// Wait for in-flight goroutines (up to 30s)
	done := make(chan struct{})
	go func() { app.wg.Wait(); close(done) }()
	select {
	case <-done:
		slog.Info("all requests completed")
	case <-time.After(30 * time.Second):
		slog.Warn("shutdown timeout, some requests may be incomplete")
	}

	slog.Info("goodbye")
}

func (a *App) handleMessage(ctx context.Context, chatID int64, userID int64, userName string, messageID int, text string) {
	// 1. Check built-in commands
	kind, cmd, args := telegram.ClassifyMessage(text, a.commands)
	if kind == telegram.KindCommand {
		a.handleCommand(ctx, chatID, userID, userName, cmd, args)
		return
	}

	// 2. Check skills — transform text if skill matches
	if skill := a.skills.Match(text); skill != nil {
		userArgs := text
		if strings.HasPrefix(text, "/") {
			parts := strings.SplitN(text, " ", 2)
			if len(parts) > 1 {
				userArgs = parts[1]
			} else {
				userArgs = ""
			}
		}
		text = skill.BuildPrompt(userArgs)
	}

	// 3. Get or create chat
	chat, err := a.db.GetChatByTgID(chatID)
	if err != nil {
		slog.Error("db error", "error", err)
		return
	}
	if chat == nil {
		user, err := a.db.GetUserByTgID(userID)
		if err != nil {
			slog.Error("get user failed", "error", err)
			return
		}
		if user == nil {
			user, err = a.db.CreateUser(userID, userName)
			if err != nil {
				slog.Error("create user failed", "error", err)
				return
			}
		}
		chat, err = a.db.CreateChat(user.ID, chatID, fmt.Sprintf("chat-%d", chatID))
		if err != nil {
			slog.Error("create chat failed", "error", err)
			return
		}
	}

	// 4. Save message to DB
	msg, err := a.db.SaveMessage(chat.ID, int64(messageID), "user", text)
	if err != nil {
		slog.Error("save message failed", "error", err)
		return
	}

	// 5. Process in goroutine (tracked by WaitGroup for graceful shutdown)
	a.wg.Add(1)
	go func() {
		defer a.wg.Done()
		response, err := a.proc.Process(ctx, *msg, chat)
		if err != nil {
			slog.Error("process failed", "error", err, "chat", chat.Name)
			a.bot.SendMessage(ctx, chatID, "Sorry, something went wrong. Please try again.")
			return
		}
		if err := a.bot.SendMessage(ctx, chatID, response); err != nil {
			slog.Error("send failed", "error", err, "chat", chat.Name)
		}
	}()
}

func (a *App) handleCommand(ctx context.Context, chatID int64, userID int64, userName string, cmd string, args string) {
	switch cmd {
	case "start":
		user, err := a.db.GetUserByTgID(userID)
		if err != nil {
			slog.Error("get user failed", "error", err)
		}
		if user == nil {
			var createErr error
			user, createErr = a.db.CreateUser(userID, userName)
			if createErr != nil {
				slog.Error("create user failed", "error", createErr)
				return
			}
		}
		chat, _ := a.db.GetChatByTgID(chatID)
		if chat == nil {
			if _, err := a.db.CreateChat(user.ID, chatID, fmt.Sprintf("chat-%d", chatID)); err != nil {
				slog.Error("create chat failed", "error", err)
			}
		} else if chat.Status == "paused" {
			a.db.UpdateChatStatus(chat.ID, "active")
		}
		a.bot.SendMessage(ctx, chatID, "Welcome to Druzhok! Send me a message to get started.")

	case "stop":
		chat, _ := a.db.GetChatByTgID(chatID)
		if chat != nil {
			a.db.UpdateChatStatus(chat.ID, "paused")
		}
		a.bot.SendMessage(ctx, chatID, "Chat paused. Send /start to resume.")

	case "reset":
		chat, _ := a.db.GetChatByTgID(chatID)
		if chat != nil {
			if chat.OCSessionID != "" {
				a.client.DeleteSession(chat.OCSessionID)
			}
			a.db.UpdateSessionID(chat.ID, "")
		}
		a.bot.SendMessage(ctx, chatID, "Session reset. Starting fresh.")

	case "prompt":
		chat, _ := a.db.GetChatByTgID(chatID)
		if chat == nil {
			a.bot.SendMessage(ctx, chatID, "Chat not registered. Send /start first.")
			return
		}
		if args == "" {
			if chat.SystemPrompt == "" {
				a.bot.SendMessage(ctx, chatID, "No system prompt set.")
			} else {
				a.bot.SendMessage(ctx, chatID, fmt.Sprintf("Current system prompt:\n\n%s", chat.SystemPrompt))
			}
			return
		}
		user, _ := a.db.GetUserByTgID(userID)
		if user == nil || !user.IsAdmin {
			a.bot.SendMessage(ctx, chatID, "Only admin can change the system prompt.")
			return
		}
		a.db.UpdateSystemPrompt(chat.ID, args)
		a.bot.SendMessage(ctx, chatID, "System prompt updated.")

	case "model":
		if args == "" {
			a.bot.SendMessage(ctx, chatID, "Usage: /model <provider/model-id>")
			return
		}
		user, _ := a.db.GetUserByTgID(userID)
		if user == nil || !user.IsAdmin {
			a.bot.SendMessage(ctx, chatID, "Only admin can change the model.")
			return
		}
		chat, _ := a.db.GetChatByTgID(chatID)
		if chat != nil {
			a.db.UpdateModel(chat.ID, args)
		}
		a.bot.SendMessage(ctx, chatID, fmt.Sprintf("Model set to: %s", args))
	}
}

// monitorHealth checks OpenCode server health every 30s and auto-restarts on failure.
func (a *App) monitorHealth(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	failures := 0
	maxRetries := 3

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if a.server.IsHealthy() {
				failures = 0
				continue
			}

			failures++
			slog.Warn("opencode health check failed", "failures", failures)

			if failures <= maxRetries {
				slog.Info("restarting opencode server", "attempt", failures)
				a.server.Stop()
				if err := a.server.Start(ctx); err != nil {
					slog.Error("restart failed", "error", err)
				} else {
					failures = 0
				}
			} else {
				slog.Error("opencode server unrecoverable after retries")
				// TODO: alert admin via Telegram
			}
		}
	}
}

// retryLoop polls for failed/pending messages and retries them.
func (a *App) retryLoop(ctx context.Context) {
	ticker := time.NewTicker(a.cfg.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			msgs, err := a.db.GetPendingMessages()
			if err != nil {
				slog.Error("retry loop: get pending failed", "error", err)
				continue
			}
			for _, msg := range msgs {
				chat, err := a.db.GetChatByTgID(0) // Need chat lookup by chat_id
				// For retry, we need to look up the chat by the message's chat_id
				chat, err = a.db.GetChatByID(msg.ChatID)
				if err != nil || chat == nil {
					slog.Error("retry loop: chat not found", "chat_id", msg.ChatID)
					continue
				}
				a.wg.Add(1)
				go func(m db.Message, c *db.Chat) {
					defer a.wg.Done()
					response, err := a.proc.Process(ctx, m, c)
					if err != nil {
						slog.Error("retry failed", "error", err, "msg_id", m.ID)
						return
					}
					if err := a.bot.SendMessage(ctx, c.TgChatID, response); err != nil {
						slog.Error("retry send failed", "error", err)
					}
				}(msg, chat)
			}
		}
	}
}
```

- [ ] **Step 9.2: Add GetChatByID to db/chats.go**

The retry loop needs to look up chats by internal ID (not Telegram ID). Add to `internal/db/chats.go`:

```go
func (d *DB) GetChatByID(chatID string) (*Chat, error) {
	c := &Chat{}
	err := d.conn.QueryRow(
		`SELECT id, user_id, tg_chat_id, oc_session_id, name, system_prompt, model, status, created_at
		 FROM chats WHERE id = ?`,
		chatID,
	).Scan(&c.ID, &c.UserID, &c.TgChatID, &c.OCSessionID, &c.Name, &c.SystemPrompt, &c.Model, &c.Status, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get chat by id: %w", err)
	}
	return c, nil
}
```

- [ ] **Step 9.3: Add IsHealthy to opencode/server.go**

Add to `internal/opencode/server.go`:

```go
func (s *Server) IsHealthy() bool {
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(s.healthURL())
	if err != nil {
		return false
	}
	resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}
```

- [ ] **Step 9.4: Compile and verify**

```bash
go build ./cmd/druzhok/
```

Expected: compiles without errors.

- [ ] **Step 9.5: Run all tests**

```bash
make test
```

Expected: all tests pass

- [ ] **Step 9.6: Commit**

```bash
git add cmd/ internal/ go.mod go.sum
git commit -m "wire all components into main entrypoint"
```

---

### Task 10: End-to-End Manual Test

- [ ] **Step 10.1: Set up credentials**

```bash
mkdir -p ~/.config/druzhok
cat > ~/.config/druzhok/credentials.yaml << 'EOF'
telegram:
  bot_token: "YOUR_TOKEN_HERE"
providers:
  anthropic:
    api_key: "YOUR_KEY_HERE"
EOF
chmod 600 ~/.config/druzhok/credentials.yaml
```

- [ ] **Step 10.2: Run Druzhok**

```bash
make run
```

Expected: sees "druzhok started" in logs

- [ ] **Step 10.3: Test basic flow**

In Telegram:
1. Send `/start` to bot → "Welcome to Druzhok!"
2. Send "Hello, who are you?" → AI response
3. Send `/prompt You are a pirate` → "System prompt updated."
4. Send "Hello again" → pirate-themed response
5. Send `/reset` → "Session reset."
6. Send "Hello" → normal response (system prompt persists, session is fresh)

- [ ] **Step 10.4: Test error recovery**

1. Kill the `opencode serve` process manually
2. Send a message → should queue
3. Wait for auto-restart → queued message gets processed

- [ ] **Step 10.5: Test multiple chats**

1. Add bot to a group chat
2. Send message in group → separate session from private chat
3. Set different system prompt in group
4. Verify responses are isolated

- [ ] **Step 10.6: Fix any issues found, commit**

```bash
git add -A
git commit -m "fix issues from manual testing"
```

---

### Task 11: Clean Up and Document

**Files:**
- Modify: `CLAUDE.md`
- Create: `README.md` (only because this is a new project)

- [ ] **Step 11.1: Update CLAUDE.md with actual file paths**

Update `CLAUDE.md` to reflect the real project structure.

- [ ] **Step 11.2: Create minimal README**

Create `README.md` with:
- One-line description
- Quick start (3 steps)
- Available commands
- Link to design spec

- [ ] **Step 11.3: Final commit**

```bash
git add CLAUDE.md README.md
git commit -m "add readme and update project docs"
```
