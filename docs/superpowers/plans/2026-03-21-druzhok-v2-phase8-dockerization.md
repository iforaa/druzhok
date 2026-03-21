# Druzhok v2 Phase 8: Dockerization & Orchestrator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Go orchestrator that manages per-user Docker containers via REST API, update the proxy to support dynamic instance registration, and set up the host data directory structure.

**Architecture:** Go orchestrator with Docker Engine API + SQLite registry. Communicates with the existing Node.js proxy via shared `instances.json` file. Each instance is a Docker container with bind-mounted workspace.

**Tech Stack:** Go 1.25+, `github.com/docker/docker/client`, `github.com/go-chi/chi/v5`, `modernc.org/sqlite`, Docker

**Spec:** `docs/superpowers/specs/2026-03-21-dockerization-design.md`

---

## File Structure

```
services/orchestrator/
├── go.mod
├── go.sum
├── main.go                     # Entry point, HTTP server, graceful shutdown
├── api/
│   ├── handlers.go             # HTTP handlers for /instances CRUD
│   └── middleware.go           # Logging, error recovery
├── docker/
│   └── manager.go              # Docker container create/start/stop/remove
├── registry/
│   └── store.go                # SQLite instance registry
├── proxy/
│   └── sync.go                 # Write instances.json for proxy
└── config/
    └── config.go               # Env var loading
data/
├── proxy/
│   └── instances.json          # Shared registry
├── instances/                  # Per-user data (created at runtime)
│   └── .gitkeep
```

---

### Task 1: Go Module + Config

**Files:**
- Create: `services/orchestrator/go.mod`
- Create: `services/orchestrator/config/config.go`
- Create: `services/orchestrator/main.go` (skeleton)

- [ ] **Step 1: Create go.mod**

```
cd services/orchestrator && go mod init github.com/igorkuznetsov/druzhok/services/orchestrator
```

- [ ] **Step 2: Implement config.go**

```go
// services/orchestrator/config/config.go
package config

import "os"

type Config struct {
	Port           string
	DataDir        string
	ProxyURL       string
	ProxyPort      string
	DockerImage    string
	DockerNetwork  string
	DefaultModel   string
	DefaultTier    string
	InstancesJSON  string
	WorkspaceTemplate string
}

func Load() Config {
	return Config{
		Port:              getEnv("ORCHESTRATOR_PORT", "9090"),
		DataDir:           getEnv("ORCHESTRATOR_DATA_DIR", "./data"),
		ProxyURL:          getEnv("ORCHESTRATOR_PROXY_URL", "http://proxy:8080"),
		ProxyPort:         getEnv("ORCHESTRATOR_PROXY_PORT", "8080"),
		DockerImage:       getEnv("ORCHESTRATOR_DOCKER_IMAGE", "druzhok-instance"),
		DockerNetwork:     getEnv("ORCHESTRATOR_DOCKER_NETWORK", "druzhok-net"),
		DefaultModel:      getEnv("ORCHESTRATOR_DEFAULT_MODEL", "nebius/moonshotai/Kimi-K2.5-fast"),
		DefaultTier:       getEnv("ORCHESTRATOR_DEFAULT_TIER", "default"),
		InstancesJSON:     getEnv("ORCHESTRATOR_INSTANCES_JSON", "./data/proxy/instances.json"),
		WorkspaceTemplate: getEnv("ORCHESTRATOR_WORKSPACE_TEMPLATE", "./workspace-template"),
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
```

- [ ] **Step 3: Create skeleton main.go**

```go
// services/orchestrator/main.go
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/igorkuznetsov/druzhok/services/orchestrator/config"
)

func main() {
	cfg := config.Load()
	fmt.Printf("Orchestrator starting on port %s\n", cfg.Port)
	fmt.Printf("  Data dir: %s\n", cfg.DataDir)
	fmt.Printf("  Docker image: %s\n", cfg.DockerImage)

	// TODO: wire handlers
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"status":"ok"}`))
	})

	server := &http.Server{Addr: ":" + cfg.Port, Handler: mux}

	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	fmt.Println("Shutting down...")
	server.Close()
}
```

- [ ] **Step 4: Install deps, verify build**

```
cd services/orchestrator && go mod tidy && go build .
```

- [ ] **Step 5: Commit**

```bash
git commit -m "scaffold Go orchestrator with config"
```

---

### Task 2: SQLite Instance Registry

**Files:**
- Create: `services/orchestrator/registry/store.go`

- [ ] **Step 1: Implement store.go**

```go
// services/orchestrator/registry/store.go
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
```

- [ ] **Step 2: Add dependency, build**

```
cd services/orchestrator && go get modernc.org/sqlite && go build .
```

- [ ] **Step 3: Commit**

```bash
git commit -m "add SQLite instance registry"
```

---

### Task 3: Proxy Sync (instances.json)

**Files:**
- Create: `services/orchestrator/proxy/sync.go`

- [ ] **Step 1: Implement sync.go**

```go
// services/orchestrator/proxy/sync.go
package proxy

import (
	"encoding/json"
	"os"
	"path/filepath"

	"github.com/igorkuznetsov/druzhok/services/orchestrator/registry"
)

type InstanceEntry struct {
	Name    string `json:"name"`
	Tier    string `json:"tier"`
	Enabled bool   `json:"enabled"`
}

type InstancesFile struct {
	Instances map[string]InstanceEntry `json:"instances"`
}

// SyncInstancesToFile writes the current instance registry to instances.json
// for the proxy to read.
func SyncInstancesToFile(store *registry.Store, path string) error {
	instances, err := store.List()
	if err != nil {
		return err
	}

	file := InstancesFile{
		Instances: make(map[string]InstanceEntry),
	}

	for _, inst := range instances {
		file.Instances[inst.ProxyKey] = InstanceEntry{
			Name:    inst.Name,
			Tier:    inst.Tier,
			Enabled: inst.Status == "running",
		}
	}

	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}

	data, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(path, data, 0644)
}
```

- [ ] **Step 2: Build**

```
cd services/orchestrator && go build .
```

- [ ] **Step 3: Commit**

```bash
git commit -m "add proxy sync (instances.json writer)"
```

---

### Task 4: Docker Container Manager

**Files:**
- Create: `services/orchestrator/docker/manager.go`

- [ ] **Step 1: Implement manager.go**

```go
// services/orchestrator/docker/manager.go
package docker

import (
	"context"
	"fmt"
	"io"
	"path/filepath"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/api/types/mount"
	"github.com/docker/docker/api/types/network"
	"github.com/docker/docker/client"
)

type Manager struct {
	cli          *client.Client
	image        string
	networkName  string
	dataDir      string
	proxyURL     string
}

type CreateOpts struct {
	ID             string
	TelegramToken  string
	ProxyKey       string
	Model          string
}

func NewManager(image, networkName, dataDir, proxyURL string) (*Manager, error) {
	cli, err := client.NewClientWithOpts(client.FromEnv, client.WithAPIVersionNegotiation())
	if err != nil {
		return nil, err
	}
	return &Manager{cli: cli, image: image, networkName: networkName, dataDir: dataDir, proxyURL: proxyURL}, nil
}

func (m *Manager) CreateAndStart(ctx context.Context, opts CreateOpts) (string, error) {
	instanceDir := filepath.Join(m.dataDir, "instances", opts.ID)
	containerName := "druzhok-" + opts.ID

	resp, err := m.cli.ContainerCreate(ctx,
		&container.Config{
			Image: m.image,
			Env: []string{
				"DRUZHOK_TELEGRAM_TOKEN=" + opts.TelegramToken,
				"DRUZHOK_PROXY_URL=" + m.proxyURL,
				"DRUZHOK_PROXY_KEY=" + opts.ProxyKey,
				"DRUZHOK_WORKSPACE_DIR=/data/workspace",
			},
		},
		&container.HostConfig{
			Mounts: []mount.Mount{
				{
					Type:   mount.TypeBind,
					Source: instanceDir,
					Target: "/data",
				},
			},
			RestartPolicy: container.RestartPolicy{Name: "unless-stopped"},
		},
		&network.NetworkingConfig{
			EndpointsConfig: map[string]*network.EndpointSettings{
				m.networkName: {},
			},
		},
		nil,
		containerName,
	)
	if err != nil {
		return "", fmt.Errorf("create container: %w", err)
	}

	if err := m.cli.ContainerStart(ctx, resp.ID, container.StartOptions{}); err != nil {
		return "", fmt.Errorf("start container: %w", err)
	}

	return resp.ID, nil
}

func (m *Manager) Stop(ctx context.Context, containerID string) error {
	timeout := 30
	return m.cli.ContainerStop(ctx, containerID, container.StopOptions{Timeout: &timeout})
}

func (m *Manager) Remove(ctx context.Context, containerID string) error {
	return m.cli.ContainerRemove(ctx, containerID, container.RemoveOptions{Force: true})
}

func (m *Manager) IsRunning(ctx context.Context, containerID string) (bool, error) {
	inspect, err := m.cli.ContainerInspect(ctx, containerID)
	if err != nil {
		return false, err
	}
	return inspect.State.Running, nil
}

func (m *Manager) Logs(ctx context.Context, containerID string, tail int) (string, error) {
	reader, err := m.cli.ContainerLogs(ctx, containerID, container.LogsOptions{
		ShowStdout: true,
		ShowStderr: true,
		Tail:       fmt.Sprintf("%d", tail),
	})
	if err != nil {
		return "", err
	}
	defer reader.Close()

	data, err := io.ReadAll(reader)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (m *Manager) Close() error {
	return m.cli.Close()
}

// EnsureNetwork creates the Docker network if it doesn't exist.
func (m *Manager) EnsureNetwork(ctx context.Context) error {
	_, err := m.cli.NetworkInspect(ctx, m.networkName, network.InspectOptions{})
	if err == nil {
		return nil // already exists
	}
	_, err = m.cli.NetworkCreate(ctx, m.networkName, network.CreateOptions{
		Driver: "bridge",
	})
	return err
}

var _ = time.Second // keep import
```

- [ ] **Step 2: Add Docker dependency**

```
cd services/orchestrator && go get github.com/docker/docker/client && go get github.com/docker/docker/api/types && go mod tidy && go build .
```

- [ ] **Step 3: Commit**

```bash
git commit -m "add Docker container manager"
```

---

### Task 5: API Handlers

**Files:**
- Create: `services/orchestrator/api/handlers.go`
- Create: `services/orchestrator/api/middleware.go`

- [ ] **Step 1: Implement middleware.go**

```go
// services/orchestrator/api/middleware.go
package api

import (
	"log"
	"net/http"
	"time"
)

func LoggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

func RecoveryMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				log.Printf("panic: %v", err)
				http.Error(w, "internal server error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}
```

- [ ] **Step 2: Implement handlers.go**

```go
// services/orchestrator/api/handlers.go
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"

	dockermgr "github.com/igorkuznetsov/druzhok/services/orchestrator/docker"
	"github.com/igorkuznetsov/druzhok/services/orchestrator/proxy"
	"github.com/igorkuznetsov/druzhok/services/orchestrator/registry"
)

type Handlers struct {
	Store             *registry.Store
	Docker            *dockermgr.Manager
	DataDir           string
	DefaultModel      string
	DefaultTier       string
	InstancesJSONPath string
	WorkspaceTemplate string
}

type CreateRequest struct {
	Name          string `json:"name"`
	TelegramToken string `json:"telegramToken"`
	Model         string `json:"model,omitempty"`
	Tier          string `json:"tier,omitempty"`
}

func (h *Handlers) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /instances", h.ListInstances)
	mux.HandleFunc("POST /instances", h.CreateInstance)
	mux.HandleFunc("GET /instances/{id}", h.GetInstance)
	mux.HandleFunc("DELETE /instances/{id}", h.DeleteInstance)
	mux.HandleFunc("POST /instances/{id}/restart", h.RestartInstance)
	mux.HandleFunc("PUT /instances/{id}/config", h.UpdateConfig)
}

func (h *Handlers) ListInstances(w http.ResponseWriter, r *http.Request) {
	instances, err := h.Store.List()
	if err != nil {
		jsonError(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if instances == nil {
		instances = []registry.Instance{}
	}
	jsonResponse(w, instances)
}

func (h *Handlers) CreateInstance(w http.ResponseWriter, r *http.Request) {
	var req CreateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if req.Name == "" || req.TelegramToken == "" {
		jsonError(w, "name and telegramToken are required", http.StatusBadRequest)
		return
	}
	if req.Model == "" {
		req.Model = h.DefaultModel
	}
	if req.Tier == "" {
		req.Tier = h.DefaultTier
	}

	// Create registry entry
	inst, err := h.Store.Create(req.Name, req.TelegramToken, req.Model, req.Tier)
	if err != nil {
		jsonError(w, fmt.Sprintf("failed to create instance: %v", err), http.StatusConflict)
		return
	}

	// Setup data directory
	instanceDir := filepath.Join(h.DataDir, "instances", inst.ID)
	workspaceDir := filepath.Join(instanceDir, "workspace")
	if err := os.MkdirAll(workspaceDir, 0755); err != nil {
		jsonError(w, "failed to create workspace directory", http.StatusInternalServerError)
		return
	}

	// Copy workspace template if workspace is empty
	entries, _ := os.ReadDir(workspaceDir)
	if len(entries) == 0 && h.WorkspaceTemplate != "" {
		copyDir(h.WorkspaceTemplate, workspaceDir)
	}

	// Write druzhok.json
	druzhokConfig := map[string]interface{}{
		"defaultModel": req.Model,
		"workspaceDir": "/data/workspace",
		"chats":        map[string]interface{}{},
		"heartbeat":    map[string]interface{}{"enabled": false},
	}
	configData, _ := json.MarshalIndent(druzhokConfig, "", "  ")
	os.WriteFile(filepath.Join(instanceDir, "druzhok.json"), configData, 0644)

	// Sync proxy instances.json
	proxy.SyncInstancesToFile(h.Store, h.InstancesJSONPath)

	// Start Docker container
	containerID, err := h.Docker.CreateAndStart(r.Context(), dockermgr.CreateOpts{
		ID:            inst.ID,
		TelegramToken: req.TelegramToken,
		ProxyKey:      inst.ProxyKey,
		Model:         req.Model,
	})
	if err != nil {
		h.Store.UpdateStatus(inst.ID, "error")
		jsonError(w, fmt.Sprintf("failed to start container: %v", err), http.StatusInternalServerError)
		return
	}

	h.Store.UpdateContainerID(inst.ID, containerID)
	h.Store.UpdateStatus(inst.ID, "running")
	proxy.SyncInstancesToFile(h.Store, h.InstancesJSONPath)

	inst, _ = h.Store.Get(inst.ID)
	w.WriteHeader(http.StatusCreated)
	jsonResponse(w, inst)
}

func (h *Handlers) GetInstance(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	inst, err := h.Store.Get(id)
	if err != nil {
		jsonError(w, "instance not found", http.StatusNotFound)
		return
	}
	jsonResponse(w, inst)
}

func (h *Handlers) DeleteInstance(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	inst, err := h.Store.Get(id)
	if err != nil {
		jsonError(w, "instance not found", http.StatusNotFound)
		return
	}

	if inst.ContainerID != "" {
		h.Docker.Stop(r.Context(), inst.ContainerID)
		h.Docker.Remove(r.Context(), inst.ContainerID)
	}

	h.Store.UpdateStatus(id, "stopped")
	h.Store.UpdateContainerID(id, "")
	proxy.SyncInstancesToFile(h.Store, h.InstancesJSONPath)

	jsonResponse(w, map[string]string{"status": "stopped"})
}

func (h *Handlers) RestartInstance(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	inst, err := h.Store.Get(id)
	if err != nil {
		jsonError(w, "instance not found", http.StatusNotFound)
		return
	}

	// Stop old container
	if inst.ContainerID != "" {
		h.Docker.Stop(r.Context(), inst.ContainerID)
		h.Docker.Remove(r.Context(), inst.ContainerID)
	}

	// Start new container
	containerID, err := h.Docker.CreateAndStart(r.Context(), dockermgr.CreateOpts{
		ID:            inst.ID,
		TelegramToken: inst.TelegramToken,
		ProxyKey:      inst.ProxyKey,
		Model:         inst.Model,
	})
	if err != nil {
		h.Store.UpdateStatus(id, "error")
		jsonError(w, fmt.Sprintf("restart failed: %v", err), http.StatusInternalServerError)
		return
	}

	h.Store.UpdateContainerID(id, containerID)
	h.Store.UpdateStatus(id, "running")
	proxy.SyncInstancesToFile(h.Store, h.InstancesJSONPath)

	inst, _ = h.Store.Get(id)
	jsonResponse(w, inst)
}

func (h *Handlers) UpdateConfig(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	_, err := h.Store.Get(id)
	if err != nil {
		jsonError(w, "instance not found", http.StatusNotFound)
		return
	}

	var req struct {
		Model string `json:"model,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		jsonError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Model != "" {
		h.Store.UpdateModel(id, req.Model)

		// Update druzhok.json
		configPath := filepath.Join(h.DataDir, "instances", id, "druzhok.json")
		if data, err := os.ReadFile(configPath); err == nil {
			var cfg map[string]interface{}
			json.Unmarshal(data, &cfg)
			cfg["defaultModel"] = req.Model
			newData, _ := json.MarshalIndent(cfg, "", "  ")
			os.WriteFile(configPath, newData, 0644)
		}
	}

	// Restart to pick up new config
	h.RestartInstance(w, r)
}

func jsonResponse(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(data)
}

func jsonError(w http.ResponseWriter, msg string, code int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func copyDir(src, dst string) error {
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		srcPath := filepath.Join(src, entry.Name())
		dstPath := filepath.Join(dst, entry.Name())
		if entry.IsDir() {
			os.MkdirAll(dstPath, 0755)
			copyDir(srcPath, dstPath)
		} else {
			data, err := os.ReadFile(srcPath)
			if err != nil {
				continue
			}
			os.WriteFile(dstPath, data, 0644)
		}
	}
	return nil
}
```

- [ ] **Step 3: Build**

```
cd services/orchestrator && go build .
```

- [ ] **Step 4: Commit**

```bash
git commit -m "add orchestrator API handlers"
```

---

### Task 6: Wire Main + Docker Compose

**Files:**
- Modify: `services/orchestrator/main.go` — wire all components
- Modify: `docker/docker-compose.example.yml` — add orchestrator

- [ ] **Step 1: Update main.go**

```go
// services/orchestrator/main.go
package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/igorkuznetsov/druzhok/services/orchestrator/api"
	"github.com/igorkuznetsov/druzhok/services/orchestrator/config"
	dockermgr "github.com/igorkuznetsov/druzhok/services/orchestrator/docker"
	"github.com/igorkuznetsov/druzhok/services/orchestrator/registry"
)

func main() {
	cfg := config.Load()

	// Ensure data directories
	os.MkdirAll(filepath.Join(cfg.DataDir, "instances"), 0755)
	os.MkdirAll(filepath.Join(cfg.DataDir, "proxy"), 0755)

	// SQLite registry
	store, err := registry.NewStore(filepath.Join(cfg.DataDir, "orchestrator.db"))
	if err != nil {
		log.Fatalf("Failed to open registry: %v", err)
	}
	defer store.Close()

	// Docker manager
	docker, err := dockermgr.NewManager(cfg.DockerImage, cfg.DockerNetwork, cfg.DataDir, cfg.ProxyURL)
	if err != nil {
		log.Fatalf("Failed to connect to Docker: %v", err)
	}
	defer docker.Close()

	// Ensure Docker network
	if err := docker.EnsureNetwork(context.Background()); err != nil {
		log.Printf("Warning: failed to create Docker network %s: %v", cfg.DockerNetwork, err)
	}

	// HTTP server
	mux := http.NewServeMux()

	mux.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"status":"ok"}`))
	})

	handlers := &api.Handlers{
		Store:             store,
		Docker:            docker,
		DataDir:           cfg.DataDir,
		DefaultModel:      cfg.DefaultModel,
		DefaultTier:       cfg.DefaultTier,
		InstancesJSONPath: cfg.InstancesJSON,
		WorkspaceTemplate: cfg.WorkspaceTemplate,
	}
	handlers.Register(mux)

	handler := api.RecoveryMiddleware(api.LoggingMiddleware(mux))
	server := &http.Server{Addr: ":" + cfg.Port, Handler: handler}

	fmt.Printf("Orchestrator starting on port %s\n", cfg.Port)
	fmt.Printf("  Data dir: %s\n", cfg.DataDir)
	fmt.Printf("  Docker image: %s\n", cfg.DockerImage)
	fmt.Printf("  Docker network: %s\n", cfg.DockerNetwork)
	fmt.Printf("  Proxy URL: %s\n", cfg.ProxyURL)

	go func() {
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatal(err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	fmt.Println("Shutting down...")
	server.Close()
}
```

- [ ] **Step 2: Update docker-compose.example.yml**

```yaml
services:
  proxy:
    build:
      context: .
      dockerfile: docker/Dockerfile.proxy
    ports:
      - "8080:8080"
    environment:
      - NEBIUS_API_KEY=${NEBIUS_API_KEY}
      - NEBIUS_BASE_URL=${NEBIUS_BASE_URL}
      - DRUZHOK_PROXY_PORT=8080
      - DRUZHOK_PROXY_REGISTRY_PATH=/data/proxy/instances.json
    volumes:
      - ./data/proxy:/data/proxy:ro
    networks:
      - druzhok-net
    restart: unless-stopped

  orchestrator:
    build:
      context: .
      dockerfile: services/orchestrator/Dockerfile
    ports:
      - "9090:9090"
    environment:
      - ORCHESTRATOR_PORT=9090
      - ORCHESTRATOR_DATA_DIR=/data
      - ORCHESTRATOR_PROXY_URL=http://proxy:8080
      - ORCHESTRATOR_DOCKER_IMAGE=druzhok-instance
      - ORCHESTRATOR_DOCKER_NETWORK=druzhok-net
      - ORCHESTRATOR_INSTANCES_JSON=/data/proxy/instances.json
      - ORCHESTRATOR_WORKSPACE_TEMPLATE=/app/workspace-template
    volumes:
      - ./data:/data
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - druzhok-net
    depends_on:
      - proxy
    restart: unless-stopped

networks:
  druzhok-net:
    driver: bridge
```

- [ ] **Step 3: Create orchestrator Dockerfile**

```dockerfile
# services/orchestrator/Dockerfile
FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY services/orchestrator/go.mod services/orchestrator/go.sum ./
RUN go mod download
COPY services/orchestrator/ .
RUN CGO_ENABLED=0 go build -o /orchestrator .

FROM alpine:3.21
RUN apk add --no-cache ca-certificates
COPY --from=builder /orchestrator /usr/local/bin/orchestrator
COPY workspace-template/ /app/workspace-template/
EXPOSE 9090
CMD ["orchestrator"]
```

- [ ] **Step 4: Build orchestrator**

```
cd services/orchestrator && go mod tidy && go build .
```

- [ ] **Step 5: Commit**

```bash
git commit -m "wire orchestrator main, add Dockerfile and docker-compose"
```

---

## Phase 8 Complete Checklist

- [ ] Go orchestrator builds and runs
- [ ] `POST /instances` creates registry entry + data dir + Docker container
- [ ] `GET /instances` lists all instances with status
- [ ] `DELETE /instances/:id` stops and removes container (keeps data)
- [ ] `POST /instances/:id/restart` recreates container
- [ ] `PUT /instances/:id/config` updates model and restarts
- [ ] `instances.json` is synced after every change
- [ ] Proxy reads `instances.json` for auth
- [ ] Docker containers connect to proxy via `druzhok-net` bridge network
- [ ] Workspace data persists in `data/instances/{id}/workspace/`
