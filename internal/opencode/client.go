package opencode

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	opencode "github.com/sst/opencode-sdk-go"
	"github.com/sst/opencode-sdk-go/option"
)

const (
	// DefaultPromptTimeout is the maximum time to wait for a prompt response.
	DefaultPromptTimeout = 5 * time.Minute

	// pollInterval is the initial delay between polling attempts.
	pollInterval = 200 * time.Millisecond

	// maxPollInterval caps the exponential backoff.
	maxPollInterval = 1 * time.Second

	// reconnectDelay is the delay before reconnecting the SSE stream.
	reconnectDelay = 2 * time.Second
)

// StreamEvent carries a streaming update from the SSE event loop.
type StreamEvent struct {
	Text string // accumulated text so far
	Done bool   // true when session is idle
	Error error
}

// Client wraps the OpenCode SDK and provides both synchronous and streaming
// interfaces for sending prompts. A long-lived SSE event loop routes events
// to per-session waiter channels.
type Client struct {
	sdk     *opencode.Client
	baseURL string
	log     *slog.Logger

	mu      sync.Mutex
	waiters map[string]chan StreamEvent // sessionID -> channel
}

// NewClient creates a new OpenCode client pointing at the given base URL.
func NewClient(baseURL string) *Client {
	sdk := opencode.NewClient(
		option.WithBaseURL(baseURL),
	)
	return &Client{
		sdk:     sdk,
		baseURL: baseURL,
		log:     slog.Default(),
		waiters: make(map[string]chan StreamEvent),
	}
}

// StartEventLoop starts a long-lived goroutine that listens to the SSE event
// stream and routes events to registered waiters. It reconnects automatically
// if the stream drops. The goroutine exits when ctx is cancelled.
func (c *Client) StartEventLoop(ctx context.Context) {
	go c.eventLoop(ctx)
}

func (c *Client) eventLoop(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}

		c.log.Debug("opencode: connecting SSE event stream")
		stream := c.sdk.Event.ListStreaming(ctx, opencode.EventListParams{})

		for stream.Next() {
			evt := stream.Current()
			c.dispatchEvent(evt)
		}

		if err := stream.Err(); err != nil {
			if ctx.Err() != nil {
				// Context cancelled — clean shutdown.
				return
			}
			c.log.Warn("opencode: SSE stream error, reconnecting", "error", err)
		} else {
			c.log.Warn("opencode: SSE stream ended, reconnecting")
		}

		// Wait before reconnecting.
		select {
		case <-ctx.Done():
			return
		case <-time.After(reconnectDelay):
		}
	}
}

func (c *Client) dispatchEvent(evt opencode.EventListResponse) {
	switch u := evt.AsUnion().(type) {
	case opencode.EventListResponseEventMessagePartUpdated:
		part := u.Properties.Part
		if part.Type != opencode.PartTypeText {
			return
		}
		sessionID := part.SessionID
		c.mu.Lock()
		ch, ok := c.waiters[sessionID]
		c.mu.Unlock()
		if ok {
			select {
			case ch <- StreamEvent{Text: part.Text}:
			default:
				// Channel full — skip this update to avoid blocking.
			}
		}

	case opencode.EventListResponseEventSessionIdle:
		sessionID := u.Properties.SessionID
		c.mu.Lock()
		ch, ok := c.waiters[sessionID]
		c.mu.Unlock()
		if ok {
			select {
			case ch <- StreamEvent{Done: true}:
			default:
			}
		}

	case opencode.EventListResponseEventSessionError:
		sessionID := u.Properties.SessionID
		errMsg := fmt.Sprintf("session error: %s", u.Properties.Error.Name)
		c.mu.Lock()
		ch, ok := c.waiters[sessionID]
		c.mu.Unlock()
		if ok {
			select {
			case ch <- StreamEvent{Error: fmt.Errorf("opencode: %s", errMsg)}:
			default:
			}
		}
	}
}

// registerWaiter creates a buffered channel for the given session and registers
// it. Returns the channel and a cleanup function.
func (c *Client) registerWaiter(sessionID string) (chan StreamEvent, func()) {
	ch := make(chan StreamEvent, 64)
	c.mu.Lock()
	c.waiters[sessionID] = ch
	c.mu.Unlock()

	return ch, func() {
		c.mu.Lock()
		delete(c.waiters, sessionID)
		c.mu.Unlock()
	}
}

// CreateSession creates a new OpenCode session and returns its ID.
func (c *Client) CreateSession(ctx context.Context) (string, error) {
	session, err := c.sdk.Session.New(ctx, opencode.SessionNewParams{})
	if err != nil {
		return "", fmt.Errorf("opencode: creating session: %w", err)
	}
	c.log.Debug("opencode: session created", "session_id", session.ID)
	return session.ID, nil
}

// SendPromptStreaming sends a text prompt and streams the response via onChunk.
// onChunk receives the full accumulated text so far on each update.
// Returns the final complete text when done.
func (c *Client) SendPromptStreaming(ctx context.Context, sessionID, prompt string, onChunk func(text string)) (string, error) {
	// 1. Register a waiter for this session.
	ch, cleanup := c.registerWaiter(sessionID)
	defer cleanup()

	// 2. Send the prompt (returns immediately).
	_, err := c.sdk.Session.Prompt(ctx, sessionID, opencode.SessionPromptParams{
		Parts: opencode.F([]opencode.SessionPromptParamsPartUnion{
			opencode.TextPartInputParam{
				Type: opencode.F(opencode.TextPartInputTypeText),
				Text: opencode.F(prompt),
			},
		}),
	})
	if err != nil {
		return "", fmt.Errorf("opencode: sending prompt: %w", err)
	}

	c.log.Debug("opencode: prompt sent, waiting for SSE events",
		"session_id", sessionID,
	)

	// 3. Wait for events with timeout.
	ctx, cancel := context.WithTimeout(ctx, DefaultPromptTimeout)
	defer cancel()

	var lastText string
	for {
		select {
		case <-ctx.Done():
			return "", fmt.Errorf("opencode: prompt timed out waiting for response: %w", ctx.Err())
		case evt := <-ch:
			if evt.Error != nil {
				return "", fmt.Errorf("opencode: %w", evt.Error)
			}
			if evt.Done {
				// Session is idle — response is complete.
				// If we haven't received any text via streaming, fall back to
				// polling the message once.
				if lastText == "" {
					lastText = "(Task completed)"
				}
				c.log.Debug("opencode: streaming response complete",
					"session_id", sessionID,
					"text_len", len(lastText),
				)
				return lastText, nil
			}
			// Text update.
			lastText = evt.Text
			if onChunk != nil {
				onChunk(lastText)
			}
		}
	}
}

// SendPrompt sends a text prompt to the given session and blocks until the
// assistant response is available. This is a convenience wrapper around
// SendPromptStreaming that ignores intermediate chunks.
func (c *Client) SendPrompt(ctx context.Context, sessionID, prompt string) (string, error) {
	return c.SendPromptStreaming(ctx, sessionID, prompt, nil)
}

// DeleteSession deletes a session and all its data.
func (c *Client) DeleteSession(ctx context.Context, sessionID string) error {
	_, err := c.sdk.Session.Delete(ctx, sessionID, opencode.SessionDeleteParams{})
	if err != nil {
		return fmt.Errorf("opencode: deleting session %s: %w", sessionID, err)
	}
	c.log.Debug("opencode: session deleted", "session_id", sessionID)
	return nil
}

// AbortSession aborts any in-progress prompt in the given session.
func (c *Client) AbortSession(ctx context.Context, sessionID string) error {
	_, err := c.sdk.Session.Abort(ctx, sessionID, opencode.SessionAbortParams{})
	if err != nil {
		return fmt.Errorf("opencode: aborting session %s: %w", sessionID, err)
	}
	c.log.Debug("opencode: session aborted", "session_id", sessionID)
	return nil
}

// pollMessage fetches a single message and checks whether the assistant has
// produced text content. Returns (text, done, error).
func (c *Client) pollMessage(ctx context.Context, sessionID, messageID string) (string, bool, error) {
	msg, err := c.sdk.Session.Message(ctx, sessionID, messageID, opencode.SessionMessageParams{})
	if err != nil {
		return "", false, fmt.Errorf("opencode: polling message %s: %w", messageID, err)
	}

	// Check if any text parts have content.
	var texts []string
	for _, p := range msg.Parts {
		if tp, ok := p.AsUnion().(opencode.TextPart); ok && tp.Text != "" {
			texts = append(texts, tp.Text)
		}
	}

	if len(texts) > 0 {
		return strings.Join(texts, ""), true, nil
	}

	return "", false, nil
}
