package opencode

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
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
)

// Client wraps the OpenCode SDK and provides a synchronous interface
// for sending prompts. The underlying API is asynchronous (POST /session/{id}/message
// returns immediately), so SendPrompt polls until the response is ready.
type Client struct {
	sdk     *opencode.Client
	baseURL string
	log     *slog.Logger
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

// SendPrompt sends a text prompt to the given session and blocks until the
// assistant response is available. It polls the messages endpoint with
// exponential backoff up to DefaultPromptTimeout.
func (c *Client) SendPrompt(ctx context.Context, sessionID, prompt string) (string, error) {
	// 1. Send the prompt (returns immediately with an empty shell).
	resp, err := c.sdk.Session.Prompt(ctx, sessionID, opencode.SessionPromptParams{
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

	assistantMsgID := resp.Info.ID
	c.log.Debug("opencode: prompt sent, polling for response",
		"session_id", sessionID,
		"message_id", assistantMsgID,
	)

	// 2. Poll for the completed response.
	ctx, cancel := context.WithTimeout(ctx, DefaultPromptTimeout)
	defer cancel()

	delay := pollInterval
	for {
		text, done, err := c.pollMessage(ctx, sessionID, assistantMsgID)
		if err != nil {
			return "", err
		}
		if done {
			c.log.Debug("opencode: response received",
				"session_id", sessionID,
				"message_id", assistantMsgID,
				"text_len", len(text),
			)
			return text, nil
		}

		select {
		case <-ctx.Done():
			return "", fmt.Errorf("opencode: prompt timed out waiting for response: %w", ctx.Err())
		case <-time.After(delay):
		}

		// Exponential backoff.
		delay = delay * 2
		if delay > maxPollInterval {
			delay = maxPollInterval
		}
	}
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
