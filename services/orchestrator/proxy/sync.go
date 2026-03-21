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
