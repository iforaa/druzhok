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
		log.Printf("Warning: Docker network %s: %v (Docker may not be running)", cfg.DockerNetwork, err)
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
