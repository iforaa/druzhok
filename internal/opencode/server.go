package opencode

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"sync"
	"time"
)

// ServerConfig holds configuration for the OpenCode server process.
type ServerConfig struct {
	Port       int           // default 4096
	Host       string        // default "127.0.0.1"
	WorkingDir string        // where .opencode/ config lives
	BinPath    string        // path to opencode binary
	MaxRetries int           // default 3
	RetryDelay time.Duration // default 2s
}

// defaults fills in zero-value fields with their defaults.
func (c *ServerConfig) defaults() {
	if c.Port == 0 {
		c.Port = 4096
	}
	if c.Host == "" {
		c.Host = "127.0.0.1"
	}
	if c.MaxRetries == 0 {
		c.MaxRetries = 3
	}
	if c.RetryDelay == 0 {
		c.RetryDelay = 2 * time.Second
	}
}

// Server manages the lifecycle of an OpenCode server subprocess.
type Server struct {
	cfg    ServerConfig
	mu     sync.Mutex
	cmd    *exec.Cmd
	cancel context.CancelFunc
}

// NewServer creates a new Server with the given configuration.
// Zero-value fields are filled with defaults.
func NewServer(cfg ServerConfig) *Server {
	cfg.defaults()
	return &Server{cfg: cfg}
}

// BaseURL returns the HTTP base URL for the server.
func (s *Server) BaseURL() string {
	return fmt.Sprintf("http://%s:%d", s.cfg.Host, s.cfg.Port)
}

// healthURL returns the full URL for the health check endpoint.
func (s *Server) healthURL() string {
	return s.BaseURL() + "/global/health"
}

// Start spawns the opencode subprocess and waits until the server is healthy
// or the context is cancelled. Returns an error if the server fails to become
// healthy within the configured retries.
func (s *Server) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	procCtx, cancel := context.WithCancel(ctx)

	cmd := exec.CommandContext(
		procCtx,
		s.cfg.BinPath,
		"serve",
		"--port", fmt.Sprintf("%d", s.cfg.Port),
		"--hostname", s.cfg.Host,
	)

	if s.cfg.WorkingDir != "" {
		cmd.Dir = s.cfg.WorkingDir
	}

	logger := slog.Default()
	cmd.Stdout = &logWriter{logger: logger, level: slog.LevelDebug, prefix: "opencode/stdout"}
	cmd.Stderr = &logWriter{logger: logger, level: slog.LevelDebug, prefix: "opencode/stderr"}

	if err := cmd.Start(); err != nil {
		cancel()
		return fmt.Errorf("opencode: starting process: %w", err)
	}

	s.cmd = cmd
	s.cancel = cancel

	if err := s.waitForHealth(ctx); err != nil {
		_ = s.stopLocked()
		return err
	}

	return nil
}

// waitForHealth polls the health endpoint using exponential backoff until
// the server responds 200 or max retries are exceeded.
func (s *Server) waitForHealth(ctx context.Context) error {
	delay := s.cfg.RetryDelay
	for attempt := 0; attempt <= s.cfg.MaxRetries; attempt++ {
		if s.IsHealthy() {
			return nil
		}
		if attempt == s.cfg.MaxRetries {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
		delay *= 2
	}
	return fmt.Errorf("opencode: server not healthy after %d retries", s.cfg.MaxRetries)
}

// Stop sends SIGINT to the subprocess and waits up to 10 seconds for it to
// exit. If it has not exited by then, SIGKILL is sent.
func (s *Server) Stop() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stopLocked()
}

// stopLocked performs the actual stop; must be called with s.mu held.
func (s *Server) stopLocked() error {
	if s.cmd == nil || s.cmd.Process == nil {
		return nil
	}

	// Graceful: send SIGINT (os.Interrupt).
	if err := s.cmd.Process.Signal(os.Interrupt); err != nil {
		// Process may already be gone; fall through to kill.
		slog.Debug("opencode: sending SIGINT failed", "err", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- s.cmd.Wait()
	}()

	select {
	case <-done:
		// Exited cleanly.
	case <-time.After(10 * time.Second):
		slog.Debug("opencode: process did not exit within 10s, sending SIGKILL")
		_ = s.cmd.Process.Kill()
		<-done
	}

	if s.cancel != nil {
		s.cancel()
		s.cancel = nil
	}
	s.cmd = nil
	return nil
}

// healthClient is a shared HTTP client with a short timeout for health checks.
var healthClient = &http.Client{Timeout: 5 * time.Second}

// IsHealthy performs a GET /global/health request and returns true iff the
// response status is 200.
func (s *Server) IsHealthy() bool {
	resp, err := healthClient.Get(s.healthURL()) //nolint:noctx
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode == http.StatusOK
}

// logWriter is an io.Writer that forwards each write as a structured log line.
type logWriter struct {
	logger *slog.Logger
	level  slog.Level
	prefix string
}

// Write emits p as a single log record, stripping a trailing newline.
func (w *logWriter) Write(p []byte) (n int, err error) {
	msg := string(p)
	// Trim trailing newline so log lines aren't doubled.
	if len(msg) > 0 && msg[len(msg)-1] == '\n' {
		msg = msg[:len(msg)-1]
	}
	w.logger.Log(context.Background(), w.level, msg, "source", w.prefix)
	return len(p), nil
}
