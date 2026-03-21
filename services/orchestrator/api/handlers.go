package api

import (
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
	mux.HandleFunc("GET /instances/{id}/workspace", h.ListWorkspaceFiles)
	mux.HandleFunc("GET /instances/{id}/workspace/{path...}", h.GetWorkspaceFile)
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

	if inst.ContainerID != "" {
		h.Docker.Stop(r.Context(), inst.ContainerID)
		h.Docker.Remove(r.Context(), inst.ContainerID)
	}

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

		configPath := filepath.Join(h.DataDir, "instances", id, "druzhok.json")
		if data, err := os.ReadFile(configPath); err == nil {
			var cfg map[string]interface{}
			json.Unmarshal(data, &cfg)
			cfg["defaultModel"] = req.Model
			newData, _ := json.MarshalIndent(cfg, "", "  ")
			os.WriteFile(configPath, newData, 0644)
		}
	}

	h.RestartInstance(w, r)
}

type FileEntry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Size  int64  `json:"size"`
}

func (h *Handlers) ListWorkspaceFiles(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.Store.Get(id); err != nil {
		jsonError(w, "instance not found", http.StatusNotFound)
		return
	}

	dir := filepath.Join(h.DataDir, "instances", id, "workspace")
	sub := r.URL.Query().Get("path")
	if sub != "" {
		dir = filepath.Join(dir, sub)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		jsonError(w, "cannot read directory", http.StatusNotFound)
		return
	}

	files := []FileEntry{}
	for _, e := range entries {
		info, _ := e.Info()
		size := int64(0)
		if info != nil {
			size = info.Size()
		}
		files = append(files, FileEntry{Name: e.Name(), IsDir: e.IsDir(), Size: size})
	}
	jsonResponse(w, files)
}

func (h *Handlers) GetWorkspaceFile(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if _, err := h.Store.Get(id); err != nil {
		jsonError(w, "instance not found", http.StatusNotFound)
		return
	}

	filePath := r.PathValue("path")
	fullPath := filepath.Join(h.DataDir, "instances", id, "workspace", filePath)

	// Security: prevent path traversal
	absBase, _ := filepath.Abs(filepath.Join(h.DataDir, "instances", id, "workspace"))
	absTarget, _ := filepath.Abs(fullPath)
	if len(absTarget) < len(absBase) || absTarget[:len(absBase)] != absBase {
		jsonError(w, "access denied", http.StatusForbidden)
		return
	}

	info, err := os.Stat(fullPath)
	if err != nil {
		jsonError(w, "file not found", http.StatusNotFound)
		return
	}

	if info.IsDir() {
		entries, _ := os.ReadDir(fullPath)
		files := []FileEntry{}
		for _, e := range entries {
			eInfo, _ := e.Info()
			size := int64(0)
			if eInfo != nil {
				size = eInfo.Size()
			}
			files = append(files, FileEntry{Name: e.Name(), IsDir: e.IsDir(), Size: size})
		}
		jsonResponse(w, files)
		return
	}

	data, err := os.ReadFile(fullPath)
	if err != nil {
		jsonError(w, "cannot read file", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Write(data)
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
