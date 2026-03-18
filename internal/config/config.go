package config

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// Config holds all configuration values for the Druzhok bot.
type Config struct {
	TelegramToken        string
	Providers            map[string]string // provider name -> API key
	OpenCodePort         int               // default 4096
	OpenCodeHost         string            // default "127.0.0.1"
	OpenCodeBin          string            // default: find in PATH or ~/.opencode/bin/opencode
	MaxConcurrentPrompts int               // default 5
	PollInterval         time.Duration     // default 2s
	DataDir              string            // default "data"
	LogLevel             string            // default "info"
}

// credentialsFile mirrors the structure of the YAML credentials file.
type credentialsFile struct {
	Telegram struct {
		BotToken string `yaml:"bot_token"`
	} `yaml:"telegram"`
	Providers map[string]struct {
		APIKey string `yaml:"api_key"`
	} `yaml:"providers"`
}

// Defaults returns a Config populated with all default values.
func Defaults() *Config {
	return &Config{
		OpenCodePort:         4096,
		OpenCodeHost:         "127.0.0.1",
		OpenCodeBin:          defaultOpenCodeBin(),
		MaxConcurrentPrompts: 5,
		PollInterval:         2 * time.Second,
		DataDir:              "data",
		LogLevel:             "info",
		Providers:            make(map[string]string),
	}
}

// defaultOpenCodeBin resolves the opencode binary path: first checks PATH,
// then falls back to ~/.opencode/bin/opencode.
func defaultOpenCodeBin() string {
	if path, err := exec.LookPath("opencode"); err == nil {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "opencode"
	}
	return filepath.Join(home, ".opencode", "bin", "opencode")
}

// Load creates a config from defaults and applies environment variable overrides.
func Load() (*Config, error) {
	c := Defaults()
	c.ApplyEnvOverrides()
	return c, nil
}

// LoadFromFile reads a YAML credentials file and returns a Config with defaults
// applied. Call ApplyEnvOverrides() afterwards if environment variables should
// take precedence.
func LoadFromFile(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("config: reading credentials file %q: %w", path, err)
	}

	var creds credentialsFile
	if err := yaml.Unmarshal(data, &creds); err != nil {
		return nil, fmt.Errorf("config: parsing credentials file %q: %w", path, err)
	}

	c := Defaults()
	c.TelegramToken = creds.Telegram.BotToken

	for name, providerCfg := range creds.Providers {
		c.Providers[name] = providerCfg.APIKey
	}

	return c, nil
}

// ApplyEnvOverrides overwrites config fields with non-empty environment
// variable values. This implements the highest-priority loading layer.
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
	if v := os.Getenv("DRUZHOK_OPENCODE_PORT"); v != "" {
		if port, err := strconv.Atoi(v); err == nil {
			c.OpenCodePort = port
		}
	}
}

// Validate checks that the config contains all required fields.
// Returns an error describing the first missing or invalid field.
func (c *Config) Validate() error {
	if strings.TrimSpace(c.TelegramToken) == "" {
		return fmt.Errorf("config: TelegramToken is required (set DRUZHOK_TELEGRAM_TOKEN or add telegram.bot_token to credentials.yaml)")
	}
	return nil
}

// DefaultCredentialsPath returns the default path for the credentials YAML
// file: ~/.config/druzhok/credentials.yaml.
func DefaultCredentialsPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".config", "druzhok", "credentials.yaml")
	}
	return filepath.Join(home, ".config", "druzhok", "credentials.yaml")
}
