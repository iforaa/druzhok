package opencode

import (
	"context"
	"encoding/json"
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

// messageResponseJSON is the JSON shape returned by GET /session/{id}/message/{msgID}.
// If text is empty, parts are empty (still processing).
func messageResponseJSON(sessionID, messageID, text string) string {
	if text == "" {
		return `{
			"info": {
				"id": "` + messageID + `",
				"role": "assistant",
				"sessionID": "` + sessionID + `",
				"time": {"created": 1000},
				"cost": 0,
				"mode": "build",
				"modelID": "test-model",
				"parentID": "",
				"path": {"cwd": "/tmp", "root": "/tmp"},
				"providerID": "test",
				"system": [],
				"tokens": {"cache": {"read": 0, "write": 0}, "input": 0, "output": 0, "reasoning": 0}
			},
			"parts": []
		}`
	}
	return `{
		"info": {
			"id": "` + messageID + `",
			"role": "assistant",
			"sessionID": "` + sessionID + `",
			"time": {"created": 1000, "completed": 2000},
			"cost": 0.001,
			"mode": "build",
			"modelID": "test-model",
			"parentID": "",
			"path": {"cwd": "/tmp", "root": "/tmp"},
			"providerID": "test",
			"system": [],
			"tokens": {"cache": {"read": 0, "write": 0}, "input": 100, "output": 50, "reasoning": 0}
		},
		"parts": [
			{
				"type": "text",
				"id": "part_1",
				"sessionID": "` + sessionID + `",
				"messageID": "` + messageID + `",
				"text": ` + mustJSON(text) + `
			}
		]
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

func TestSendPrompt(t *testing.T) {
	const (
		sessionID = "ses_prompt"
		messageID = "msg_resp1"
		wantText  = "Hello! How can I help you today?"
	)

	var pollCount atomic.Int32

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")

		switch {
		// POST /session/{id}/message — send prompt (async, returns empty shell).
		case r.Method == "POST" && r.URL.Path == "/session/"+sessionID+"/message":
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(promptResponseJSON(sessionID, messageID)))

		// GET /session/{id}/message/{msgID} — poll for response.
		case r.Method == "GET" && r.URL.Path == "/session/"+sessionID+"/message/"+messageID:
			n := pollCount.Add(1)
			if n < 2 {
				// First poll: still processing.
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(messageResponseJSON(sessionID, messageID, "")))
			} else {
				// Second poll: complete.
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write([]byte(messageResponseJSON(sessionID, messageID, wantText)))
			}

		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client := NewClient(srv.URL)
	got, err := client.SendPrompt(context.Background(), sessionID, "Say hello")
	if err != nil {
		t.Fatalf("SendPrompt() error: %v", err)
	}
	if got != wantText {
		t.Errorf("SendPrompt() = %q, want %q", got, wantText)
	}
	if n := pollCount.Load(); n < 2 {
		t.Errorf("expected at least 2 polls, got %d", n)
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

		case r.Method == "GET" && r.URL.Path == "/session/"+sessionID+"/message/"+messageID:
			// Always return empty — never completes.
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(messageResponseJSON(sessionID, messageID, "")))

		default:
			http.NotFound(w, r)
		}
	}))
	defer srv.Close()

	client := NewClient(srv.URL)

	// Use a short timeout so the test finishes quickly.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
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
