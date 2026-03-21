package registry

import (
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

type Instance struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	TelegramToken string    `json:"-"`
	ProxyKey      string    `json:"proxyKey"`
	Model         string    `json:"model"`
	Tier          string    `json:"tier"`
	ContainerID   string    `json:"containerId,omitempty"`
	Status        string    `json:"status"`
	CreatedAt     time.Time `json:"createdAt"`
}

type Store struct {
	db *sql.DB
}

func NewStore(dbPath string) (*Store, error) {
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		return nil, err
	}

	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS instances (
			id TEXT PRIMARY KEY,
			name TEXT NOT NULL UNIQUE,
			telegram_token TEXT NOT NULL,
			proxy_key TEXT NOT NULL UNIQUE,
			model TEXT NOT NULL,
			tier TEXT NOT NULL DEFAULT 'default',
			container_id TEXT DEFAULT '',
			status TEXT DEFAULT 'created',
			created_at DATETIME DEFAULT CURRENT_TIMESTAMP
		)
	`)
	if err != nil {
		return nil, err
	}

	return &Store{db: db}, nil
}

func (s *Store) Create(name, telegramToken, model, tier string) (*Instance, error) {
	id := name
	proxyKey := generateKey()

	_, err := s.db.Exec(
		`INSERT INTO instances (id, name, telegram_token, proxy_key, model, tier) VALUES (?, ?, ?, ?, ?, ?)`,
		id, name, telegramToken, proxyKey, model, tier,
	)
	if err != nil {
		return nil, fmt.Errorf("create instance: %w", err)
	}

	return s.Get(id)
}

func (s *Store) Get(id string) (*Instance, error) {
	var inst Instance
	var createdAt string
	err := s.db.QueryRow(
		`SELECT id, name, telegram_token, proxy_key, model, tier, container_id, status, created_at FROM instances WHERE id = ?`, id,
	).Scan(&inst.ID, &inst.Name, &inst.TelegramToken, &inst.ProxyKey, &inst.Model, &inst.Tier, &inst.ContainerID, &inst.Status, &createdAt)
	if err != nil {
		return nil, err
	}
	inst.CreatedAt, _ = time.Parse("2006-01-02 15:04:05", createdAt)
	return &inst, nil
}

func (s *Store) List() ([]Instance, error) {
	rows, err := s.db.Query(`SELECT id, name, proxy_key, model, tier, container_id, status, created_at FROM instances ORDER BY created_at`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var instances []Instance
	for rows.Next() {
		var inst Instance
		var createdAt string
		if err := rows.Scan(&inst.ID, &inst.Name, &inst.ProxyKey, &inst.Model, &inst.Tier, &inst.ContainerID, &inst.Status, &createdAt); err != nil {
			continue
		}
		inst.CreatedAt, _ = time.Parse("2006-01-02 15:04:05", createdAt)
		instances = append(instances, inst)
	}
	return instances, nil
}

func (s *Store) UpdateStatus(id, status string) error {
	_, err := s.db.Exec(`UPDATE instances SET status = ? WHERE id = ?`, status, id)
	return err
}

func (s *Store) UpdateContainerID(id, containerID string) error {
	_, err := s.db.Exec(`UPDATE instances SET container_id = ? WHERE id = ?`, containerID, id)
	return err
}

func (s *Store) UpdateModel(id, model string) error {
	_, err := s.db.Exec(`UPDATE instances SET model = ? WHERE id = ?`, model, id)
	return err
}

func (s *Store) Delete(id string) error {
	_, err := s.db.Exec(`DELETE FROM instances WHERE id = ?`, id)
	return err
}

func (s *Store) Close() error {
	return s.db.Close()
}

func generateKey() string {
	b := make([]byte, 24)
	rand.Read(b)
	return "dk_" + hex.EncodeToString(b)
}
