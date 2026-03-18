package opencode

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestServerConfig verifies that NewServer applies defaults and constructs
// BaseURL correctly.
func TestServerConfig(t *testing.T) {
	t.Run("defaults applied", func(t *testing.T) {
		s := NewServer(ServerConfig{})
		if s.cfg.Port != 4096 {
			t.Errorf("Port: got %d, want 4096", s.cfg.Port)
		}
		if s.cfg.Host != "127.0.0.1" {
			t.Errorf("Host: got %q, want 127.0.0.1", s.cfg.Host)
		}
		if s.cfg.MaxRetries != 3 {
			t.Errorf("MaxRetries: got %d, want 3", s.cfg.MaxRetries)
		}
		if s.cfg.RetryDelay != 2*time.Second {
			t.Errorf("RetryDelay: got %v, want 2s", s.cfg.RetryDelay)
		}
	})

	t.Run("BaseURL uses configured host and port", func(t *testing.T) {
		s := NewServer(ServerConfig{Host: "0.0.0.0", Port: 9000})
		want := "http://0.0.0.0:9000"
		if got := s.BaseURL(); got != want {
			t.Errorf("BaseURL: got %q, want %q", got, want)
		}
	})

	t.Run("BaseURL with defaults", func(t *testing.T) {
		s := NewServer(ServerConfig{})
		want := "http://127.0.0.1:4096"
		if got := s.BaseURL(); got != want {
			t.Errorf("BaseURL: got %q, want %q", got, want)
		}
	})
}

// TestHealthCheckURL verifies the health endpoint URL is constructed correctly.
func TestHealthCheckURL(t *testing.T) {
	s := NewServer(ServerConfig{Host: "localhost", Port: 8080})
	want := "http://localhost:8080/global/health"
	if got := s.healthURL(); got != want {
		t.Errorf("healthURL: got %q, want %q", got, want)
	}
}

// TestMaxRetriesExceeded verifies that waitForHealth returns an error when
// nothing is listening on the target port.
func TestMaxRetriesExceeded(t *testing.T) {
	s := NewServer(ServerConfig{
		Host:       "127.0.0.1",
		Port:       1, // nothing listening here; connections are refused immediately
		MaxRetries: 2,
		RetryDelay: 10 * time.Millisecond,
	})

	err := s.waitForHealth(context.Background())
	if err == nil {
		t.Fatal("expected error when nothing is listening, got nil")
	}
}

// TestIsHealthyWithMockServer verifies IsHealthy returns true when the server
// responds with HTTP 200.
func TestIsHealthyWithMockServer(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/global/health" {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusNotFound)
	}))
	defer ts.Close()

	host, port := parseHostPort(t, ts.URL)
	s := NewServer(ServerConfig{Host: host, Port: port})

	if !s.IsHealthy() {
		t.Error("IsHealthy: expected true with mock server returning 200, got false")
	}
}

// TestIsHealthyWhenDown verifies IsHealthy returns false when nothing is
// listening on the target port.
func TestIsHealthyWhenDown(t *testing.T) {
	s := NewServer(ServerConfig{
		Host: "127.0.0.1",
		Port: 1, // nothing listening
	})
	if s.IsHealthy() {
		t.Error("IsHealthy: expected false when nothing listening, got true")
	}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// parseHostPort splits a URL like "http://127.0.0.1:12345" into host string
// and port int.
func parseHostPort(t *testing.T, rawURL string) (string, int) {
	t.Helper()
	rest := rawURL
	if len(rest) > 7 && rest[:7] == "http://" {
		rest = rest[7:]
	}
	for i := len(rest) - 1; i >= 0; i-- {
		if rest[i] == ':' {
			host := rest[:i]
			var port int
			if _, err := fmt.Sscanf(rest[i+1:], "%d", &port); err != nil {
				t.Fatalf("parseHostPort: parsing port from %q: %v", rawURL, err)
			}
			return host, port
		}
	}
	t.Fatalf("parseHostPort: no port found in URL %q", rawURL)
	return "", 0
}
