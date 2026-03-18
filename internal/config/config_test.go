package config_test

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/igorkuznetsov/druzhok/internal/config"
)

func TestDefaults(t *testing.T) {
	c := config.Defaults()

	tests := []struct {
		name string
		got  interface{}
		want interface{}
	}{
		{"OpenCodePort", c.OpenCodePort, 4096},
		{"OpenCodeHost", c.OpenCodeHost, "127.0.0.1"},
		{"MaxConcurrentPrompts", c.MaxConcurrentPrompts, 5},
		{"PollInterval", c.PollInterval, 2 * time.Second},
		{"DataDir", c.DataDir, "data"},
		{"LogLevel", c.LogLevel, "info"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.got != tt.want {
				t.Errorf("got %v, want %v", tt.got, tt.want)
			}
		})
	}

	if c.Providers == nil {
		t.Error("Providers map should be initialized, got nil")
	}
}

func TestLoadFromEnv(t *testing.T) {
	t.Setenv("DRUZHOK_TELEGRAM_TOKEN", "test-token-123")
	t.Setenv("ANTHROPIC_API_KEY", "sk-ant-test")
	t.Setenv("OPENAI_API_KEY", "sk-openai-test")
	t.Setenv("DRUZHOK_LOG_LEVEL", "debug")
	t.Setenv("DRUZHOK_OPENCODE_PORT", "8080")

	c, err := config.Load()
	if err != nil {
		t.Fatalf("Load() returned error: %v", err)
	}

	if c.TelegramToken != "test-token-123" {
		t.Errorf("TelegramToken: got %q, want %q", c.TelegramToken, "test-token-123")
	}
	if c.Providers["anthropic"] != "sk-ant-test" {
		t.Errorf("Providers[anthropic]: got %q, want %q", c.Providers["anthropic"], "sk-ant-test")
	}
	if c.Providers["openai"] != "sk-openai-test" {
		t.Errorf("Providers[openai]: got %q, want %q", c.Providers["openai"], "sk-openai-test")
	}
	if c.LogLevel != "debug" {
		t.Errorf("LogLevel: got %q, want %q", c.LogLevel, "debug")
	}
	if c.OpenCodePort != 8080 {
		t.Errorf("OpenCodePort: got %d, want %d", c.OpenCodePort, 8080)
	}
}

func TestLoadFromEnvDefaults(t *testing.T) {
	// Ensure env vars are not set so defaults are used
	t.Setenv("DRUZHOK_TELEGRAM_TOKEN", "")
	t.Setenv("DRUZHOK_LOG_LEVEL", "")
	t.Setenv("DRUZHOK_OPENCODE_PORT", "")

	c, err := config.Load()
	if err != nil {
		t.Fatalf("Load() returned error: %v", err)
	}

	if c.LogLevel != "info" {
		t.Errorf("LogLevel default: got %q, want %q", c.LogLevel, "info")
	}
	if c.OpenCodePort != 4096 {
		t.Errorf("OpenCodePort default: got %d, want %d", c.OpenCodePort, 4096)
	}
}

func TestLoadFromFile(t *testing.T) {
	dir := t.TempDir()
	credFile := filepath.Join(dir, "credentials.yaml")

	content := `
telegram:
  bot_token: "file-token-456"
providers:
  anthropic:
    api_key: "sk-ant-from-file"
  openai:
    api_key: "sk-openai-from-file"
`
	if err := os.WriteFile(credFile, []byte(content), 0600); err != nil {
		t.Fatalf("failed to write temp credentials file: %v", err)
	}

	c, err := config.LoadFromFile(credFile)
	if err != nil {
		t.Fatalf("LoadFromFile() returned error: %v", err)
	}

	if c.TelegramToken != "file-token-456" {
		t.Errorf("TelegramToken: got %q, want %q", c.TelegramToken, "file-token-456")
	}
	if c.Providers["anthropic"] != "sk-ant-from-file" {
		t.Errorf("Providers[anthropic]: got %q, want %q", c.Providers["anthropic"], "sk-ant-from-file")
	}
	if c.Providers["openai"] != "sk-openai-from-file" {
		t.Errorf("Providers[openai]: got %q, want %q", c.Providers["openai"], "sk-openai-from-file")
	}
	// Defaults should still be applied
	if c.LogLevel != "info" {
		t.Errorf("LogLevel default: got %q, want %q", c.LogLevel, "info")
	}
	if c.OpenCodePort != 4096 {
		t.Errorf("OpenCodePort default: got %d, want %d", c.OpenCodePort, 4096)
	}
}

func TestLoadFromFileMissingFile(t *testing.T) {
	_, err := config.LoadFromFile("/nonexistent/path/credentials.yaml")
	if err == nil {
		t.Error("LoadFromFile() should return error for missing file")
	}
}

func TestLoadFromFileInvalidYAML(t *testing.T) {
	dir := t.TempDir()
	credFile := filepath.Join(dir, "credentials.yaml")

	if err := os.WriteFile(credFile, []byte("not: valid: yaml: [[["), 0600); err != nil {
		t.Fatalf("failed to write temp credentials file: %v", err)
	}

	_, err := config.LoadFromFile(credFile)
	if err == nil {
		t.Error("LoadFromFile() should return error for invalid YAML")
	}
}

func TestEnvOverridesFile(t *testing.T) {
	dir := t.TempDir()
	credFile := filepath.Join(dir, "credentials.yaml")

	content := `
telegram:
  bot_token: "file-token"
providers:
  anthropic:
    api_key: "sk-ant-from-file"
`
	if err := os.WriteFile(credFile, []byte(content), 0600); err != nil {
		t.Fatalf("failed to write temp credentials file: %v", err)
	}

	t.Setenv("DRUZHOK_TELEGRAM_TOKEN", "env-token-override")
	t.Setenv("ANTHROPIC_API_KEY", "sk-ant-from-env")
	t.Setenv("DRUZHOK_LOG_LEVEL", "warn")
	t.Setenv("DRUZHOK_OPENCODE_PORT", "9090")

	c, err := config.LoadFromFile(credFile)
	if err != nil {
		t.Fatalf("LoadFromFile() returned error: %v", err)
	}
	c.ApplyEnvOverrides()

	if c.TelegramToken != "env-token-override" {
		t.Errorf("TelegramToken: got %q, want %q (env should override file)", c.TelegramToken, "env-token-override")
	}
	if c.Providers["anthropic"] != "sk-ant-from-env" {
		t.Errorf("Providers[anthropic]: got %q, want %q (env should override file)", c.Providers["anthropic"], "sk-ant-from-env")
	}
	if c.LogLevel != "warn" {
		t.Errorf("LogLevel: got %q, want %q (env should override)", c.LogLevel, "warn")
	}
	if c.OpenCodePort != 9090 {
		t.Errorf("OpenCodePort: got %d, want %d (env should override)", c.OpenCodePort, 9090)
	}
}

func TestEnvDoesNotOverrideFileWhenEmpty(t *testing.T) {
	dir := t.TempDir()
	credFile := filepath.Join(dir, "credentials.yaml")

	content := `
telegram:
  bot_token: "file-token"
providers:
  anthropic:
    api_key: "sk-ant-from-file"
`
	if err := os.WriteFile(credFile, []byte(content), 0600); err != nil {
		t.Fatalf("failed to write temp credentials file: %v", err)
	}

	// Clear env vars so they don't override
	t.Setenv("DRUZHOK_TELEGRAM_TOKEN", "")
	t.Setenv("ANTHROPIC_API_KEY", "")

	c, err := config.LoadFromFile(credFile)
	if err != nil {
		t.Fatalf("LoadFromFile() returned error: %v", err)
	}
	c.ApplyEnvOverrides()

	if c.TelegramToken != "file-token" {
		t.Errorf("TelegramToken: got %q, want %q (empty env should not override file)", c.TelegramToken, "file-token")
	}
	if c.Providers["anthropic"] != "sk-ant-from-file" {
		t.Errorf("Providers[anthropic]: got %q, want %q (empty env should not override file)", c.Providers["anthropic"], "sk-ant-from-file")
	}
}

func TestValidate(t *testing.T) {
	tests := []struct {
		name    string
		setup   func(*config.Config)
		wantErr bool
	}{
		{
			name: "valid config",
			setup: func(c *config.Config) {
				c.TelegramToken = "valid-token"
			},
			wantErr: false,
		},
		{
			name:    "missing telegram token",
			setup:   func(c *config.Config) {},
			wantErr: true,
		},
		{
			name: "whitespace-only telegram token",
			setup: func(c *config.Config) {
				c.TelegramToken = "   "
			},
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c := config.Defaults()
			tt.setup(c)
			err := c.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestDefaultCredentialsPath(t *testing.T) {
	path := config.DefaultCredentialsPath()
	if path == "" {
		t.Error("DefaultCredentialsPath() should not return empty string")
	}

	// Should contain druzhok and credentials.yaml
	base := filepath.Base(path)
	if base != "credentials.yaml" {
		t.Errorf("DefaultCredentialsPath() base: got %q, want %q", base, "credentials.yaml")
	}

	dir := filepath.Base(filepath.Dir(path))
	if dir != "druzhok" {
		t.Errorf("DefaultCredentialsPath() parent dir: got %q, want %q", dir, "druzhok")
	}
}
