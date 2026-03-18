package opencode

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// sessionJSON is the JSON shape returned by POST /session.
func mockSessionJSON(id string) string {
	return `{
		"id": "` + id + `",
		"directory": "/tmp/test",
		"projectID": "proj_test",
		"time": {"created": 1000, "updated": 1000},
		"title": "Test Session",
		"version": "1.0.0"
	}`
}

// promptResponseJSON is the JSON shape returned by POST /session/{id}/message.
// Parts are empty because the response is async.
func promptResponseJSON(sessionID, messageID string) string {
	return `{
		"info": {
			"id": "` + messageID + `",
			"cost": 0,
			"mode": "build",
			"modelID": "test-model",
			"parentID": "",
			"path": {"cwd": "/tmp", "root": "/tmp"},
			"providerID": "test",
			"role": "assistant",
			"sessionID": "` + sessionID + `",
			"system": [],
			"time": {"created": 1000},
			"tokens": {"cache": {"read": 0, "write": 0}, "input": 0, "output": 0, "reasoning": 0}
		},
		"parts": []
	}`
}

func mustJSON(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func TestCreateSession(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" && r.URL.Path == "/session" {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(mockSessionJSON("ses_test123")))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	client := NewClient(srv.URL)
	id, err := client.CreateSession(context.Background())
	if err != nil {
		t.Fatalf("CreateSession() error: %v", err)
	}
	if id != "ses_test123" {
		t.Errorf("CreateSession() = %q, want %q", id, "ses_test123")
	}
}

// TestSendPromptStreaming tests the streaming flow by injecting events directly
// into the waiter channel (bypassing the SSE event loop), which validates the
// core SendPromptStreaming logic without depending on SSE parsing.
func TestSendPromptStreaming(t *testing.T) {
	const (
		sessionID = "ses_prompt"
		messageID = "msg_resp1"
		wantText  = "Hello! How can I help you today?"
	)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		switch {
		case r.Method == "POST" && r.URL.Path == "/session/"+sessionID+"/message":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(promptResponseJSON(sessionID, messageID)))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client := NewClient(srv.URL)

	// Feed events in a goroutine (after a small delay to let SendPromptStreaming
	// register its waiter). We look up the waiter channel dynamically.
	go func() {
		// Wait for the waiter to be registered.
		var ch chan StreamEvent
		for i := 0; i < 50; i++ {
			time.Sleep(10 * time.Millisecond)
			client.mu.Lock()
			ch = client.waiters[sessionID]
			client.mu.Unlock()
			if ch != nil {
				break
			}
		}
		if ch == nil {
			return
		}
		ch <- StreamEvent{Text: "Hello!"}
		time.Sleep(20 * time.Millisecond)
		ch <- StreamEvent{Text: wantText}
		time.Sleep(20 * time.Millisecond)
		ch <- StreamEvent{Done: true}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var chunks []string
	got, err := client.SendPromptStreaming(ctx, sessionID, "Say hello", func(text string) {
		chunks = append(chunks, text)
	})
	if err != nil {
		t.Fatalf("SendPromptStreaming() error: %v", err)
	}
	if got != wantText {
		t.Errorf("SendPromptStreaming() = %q, want %q", got, wantText)
	}
	if len(chunks) < 2 {
		t.Errorf("expected at least 2 chunk callbacks, got %d", len(chunks))
	}
}

func TestSendPromptTimeout(t *testing.T) {
	const sessionID = "ses_timeout"
	const messageID = "msg_timeout"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		switch {
		case r.Method == "POST" && r.URL.Path == "/session/"+sessionID+"/message":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(promptResponseJSON(sessionID, messageID)))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client := NewClient(srv.URL)

	// Use a short timeout so the test finishes quickly.
	// SendPromptStreaming will register its own waiter, but no events will arrive.
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()

	_, err := client.SendPrompt(ctx, sessionID, "This will time out")
	if err == nil {
		t.Fatal("SendPrompt() expected timeout error, got nil")
	}
	if !strings.Contains(err.Error(), "timed out") && !strings.Contains(err.Error(), "deadline exceeded") &&
		!strings.Contains(err.Error(), context.DeadlineExceeded.Error()) {
		t.Errorf("SendPrompt() error = %v, want timeout-related error", err)
	}
}

func TestDeleteSession(t *testing.T) {
	const sessionID = "ses_delete"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "DELETE" && r.URL.Path == "/session/"+sessionID {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("true"))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	client := NewClient(srv.URL)
	err := client.DeleteSession(context.Background(), sessionID)
	if err != nil {
		t.Fatalf("DeleteSession() error: %v", err)
	}
}

func TestSendPromptError(t *testing.T) {
	const sessionID = "ses_error"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == "POST" && r.URL.Path == "/session/"+sessionID+"/message" {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error": "internal server error"}`))
			return
		}
		http.NotFound(w, r)
	}))
	defer srv.Close()

	client := NewClient(srv.URL)
	_, err := client.SendPrompt(context.Background(), sessionID, "This will fail")
	if err == nil {
		t.Fatal("SendPrompt() expected error, got nil")
	}
	if !strings.Contains(err.Error(), "sending prompt") {
		t.Errorf("SendPrompt() error = %v, want error containing 'sending prompt'", err)
	}
}

// TestStreamEventRouting verifies that events are routed to the correct session waiter.
func TestStreamEventRouting(t *testing.T) {
	const (
		session1 = "ses_1"
		session2 = "ses_2"
	)

	client := NewClient("http://unused")

	ch1, cleanup1 := client.registerWaiter(session1)
	defer cleanup1()

	ch2, cleanup2 := client.registerWaiter(session2)
	defer cleanup2()

	// Simulate dispatching an event for session1.
	client.mu.Lock()
	client.waiters[session1] <- StreamEvent{Text: "hello from 1"}
	client.mu.Unlock()

	select {
	case evt := <-ch1:
		if evt.Text != "hello from 1" {
			t.Errorf("expected 'hello from 1', got %q", evt.Text)
		}
	case <-time.After(time.Second):
		t.Fatal("timeout waiting for event on ch1")
	}

	// ch2 should be empty.
	select {
	case evt := <-ch2:
		t.Errorf("unexpected event on ch2: %+v", evt)
	default:
		// expected
	}
}

// TestSendPromptStreamingError tests that session errors are propagated correctly.
func TestSendPromptStreamingError(t *testing.T) {
	const sessionID = "ses_err"
	const messageID = "msg_err1"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == "POST" && r.URL.Path == "/session/"+sessionID+"/message":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(promptResponseJSON(sessionID, messageID)))
		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client := NewClient(srv.URL)

	go func() {
		// Wait for the waiter to be registered.
		var ch chan StreamEvent
		for i := 0; i < 50; i++ {
			time.Sleep(10 * time.Millisecond)
			client.mu.Lock()
			ch = client.waiters[sessionID]
			client.mu.Unlock()
			if ch != nil {
				break
			}
		}
		if ch == nil {
			return
		}
		ch <- StreamEvent{Error: fmt.Errorf("opencode: session error: APIError")}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	_, err := client.SendPromptStreaming(ctx, sessionID, "This will error", nil)
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "session error") {
		t.Errorf("error = %v, want it to contain 'session error'", err)
	}
}

// Keep pollCount reference for backward compatibility.
var _ atomic.Int32
