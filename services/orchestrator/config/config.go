package config

import "os"

type Config struct {
	Port              string
	DataDir           string
	ProxyURL          string
	DockerImage       string
	DockerNetwork     string
	DefaultModel      string
	DefaultTier       string
	InstancesJSON     string
	WorkspaceTemplate string
}

func Load() Config {
	return Config{
		Port:              getEnv("ORCHESTRATOR_PORT", "9090"),
		DataDir:           getEnv("ORCHESTRATOR_DATA_DIR", "./data"),
		ProxyURL:          getEnv("ORCHESTRATOR_PROXY_URL", "http://proxy:8080"),
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
