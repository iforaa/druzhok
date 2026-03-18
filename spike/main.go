// spike/main.go — OpenCode SDK spike
//
// Starts opencode serve, creates a session, sends a prompt, prints the response.
// Run: go run . (from the spike/ directory)
//
// Requires:
//   - ANTHROPIC_API_KEY or another provider key in the environment
//   - opencode binary at /Users/igorkuznetsov/.opencode/bin/opencode

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	opencode "github.com/sst/opencode-sdk-go"
	"github.com/sst/opencode-sdk-go/option"
)

const (
	opencodeBin = "/Users/igorkuznetsov/.opencode/bin/opencode"
	port        = 14096
	baseURL     = "http://127.0.0.1:14096"
	// Where opencode runs — needs a directory with opencode.json
	workDir = "/Users/igorkuznetsov/Documents/druzhok/spike"
)

func main() {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Trap signals for cleanup
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\n[spike] caught signal, shutting down...")
		cancel()
	}()

	// ── Step 1: Start opencode serve ──────────────────────────────────────
	fmt.Println("[spike] starting opencode serve on port", port)
	cmd := exec.CommandContext(ctx, opencodeBin, "serve", "--port", fmt.Sprint(port), "--print-logs", "--log-level", "DEBUG")
	cmd.Dir = workDir
	cmd.Stdout = os.Stderr // pipe server logs to stderr so we can see them
	cmd.Stderr = os.Stderr
	// Pass through env (provider keys, etc.)
	cmd.Env = os.Environ()

	if err := cmd.Start(); err != nil {
		log.Fatalf("[spike] failed to start opencode: %v", err)
	}
	defer func() {
		fmt.Println("[spike] killing opencode subprocess")
		_ = cmd.Process.Signal(syscall.SIGTERM)
		_ = cmd.Wait()
	}()

	// ── Step 2: Wait for health ──────────────────────────────────────────
	fmt.Println("[spike] waiting for opencode to become healthy...")
	startupStart := time.Now()
	if err := waitForHealth(ctx, baseURL+"/global/health", 30*time.Second); err != nil {
		// Try alternate health endpoint
		fmt.Println("[spike] /global/health failed, trying /health...")
		if err2 := waitForHealth(ctx, baseURL+"/health", 10*time.Second); err2 != nil {
			log.Fatalf("[spike] opencode not healthy after 40s: %v / %v", err, err2)
		}
	}
	startupDuration := time.Since(startupStart)
	fmt.Printf("[spike] opencode healthy in %s\n", startupDuration)

	// ── Step 3: Explore the API surface (raw HTTP) ───────────────────────
	fmt.Println("\n=== RAW HTTP APPROACH ===\n")

	// 3a. List agents
	fmt.Println("[spike][raw] GET /agent")
	dumpHTTP(ctx, "GET", baseURL+"/agent", nil)

	// 3b. Get config
	fmt.Println("[spike][raw] GET /config")
	dumpHTTP(ctx, "GET", baseURL+"/config", nil)

	// 3c. List providers
	fmt.Println("[spike][raw] GET /config/providers")
	dumpHTTP(ctx, "GET", baseURL+"/config/providers", nil)

	// 3d. Create a session
	fmt.Println("[spike][raw] POST /session")
	sessionBody := map[string]interface{}{}
	sessionResp := dumpHTTP(ctx, "POST", baseURL+"/session", sessionBody)

	var session struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(sessionResp, &session); err != nil {
		fmt.Printf("[spike][raw] could not parse session response: %v\n", err)
	} else {
		fmt.Printf("[spike][raw] created session: %s\n", session.ID)
	}

	// 3e. Send a prompt
	if session.ID != "" {
		fmt.Printf("[spike][raw] POST /session/%s/message\n", session.ID)
		promptBody := map[string]interface{}{
			"parts": []map[string]interface{}{
				{
					"type": "text",
					"text": "Say hello in one sentence.",
				},
			},
		}
		promptStart := time.Now()
		promptResp := dumpHTTP(ctx, "POST", baseURL+"/session/"+session.ID+"/message", promptBody)
		promptDuration := time.Since(promptStart)
		fmt.Printf("[spike][raw] prompt completed in %s\n", promptDuration)

		// Try to extract text from response
		var pr struct {
			Parts []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"parts"`
		}
		if err := json.Unmarshal(promptResp, &pr); err == nil {
			for _, p := range pr.Parts {
				if p.Type == "text" {
					fmt.Printf("[spike][raw] response text: %s\n", p.Text)
				}
			}
		}

		// 3f. List messages in session
		fmt.Printf("[spike][raw] GET /session/%s/messages\n", session.ID)
		dumpHTTP(ctx, "GET", baseURL+"/session/"+session.ID+"/messages", nil)
	}

	// ── Step 4: SDK approach ─────────────────────────────────────────────
	fmt.Println("\n=== SDK APPROACH ===\n")

	client := opencode.NewClient(
		option.WithBaseURL(baseURL),
	)

	// 4a. List sessions
	fmt.Println("[spike][sdk] listing sessions...")
	sessions, err := client.Session.List(ctx, opencode.SessionListParams{})
	if err != nil {
		fmt.Printf("[spike][sdk] session list error: %v\n", err)
	} else {
		fmt.Printf("[spike][sdk] found %d sessions\n", len(*sessions))
	}

	// 4b. Create a new session
	fmt.Println("[spike][sdk] creating session...")
	sdkSession, err := client.Session.New(ctx, opencode.SessionNewParams{})
	if err != nil {
		fmt.Printf("[spike][sdk] session create error: %v\n", err)
	} else {
		fmt.Printf("[spike][sdk] created session: %s (title: %q)\n", sdkSession.ID, sdkSession.Title)

		// 4c. Send prompt
		fmt.Println("[spike][sdk] sending prompt...")
		promptStart := time.Now()
		resp, err := client.Session.Prompt(ctx, sdkSession.ID, opencode.SessionPromptParams{
			Parts: opencode.F([]opencode.SessionPromptParamsPartUnion{
				opencode.TextPartInputParam{
					Type: opencode.F(opencode.TextPartInputTypeText),
					Text: opencode.F("Say hello in one sentence."),
				},
			}),
		})
		promptDuration := time.Since(promptStart)
		if err != nil {
			fmt.Printf("[spike][sdk] prompt error: %v\n", err)
		} else {
			fmt.Printf("[spike][sdk] prompt completed in %s\n", promptDuration)
			respJSON, _ := json.MarshalIndent(resp, "", "  ")
			fmt.Printf("[spike][sdk] response:\n%s\n", respJSON)

			// Extract text parts
			for _, p := range resp.Parts {
				if tp, ok := p.AsUnion().(opencode.TextPart); ok {
					fmt.Printf("[spike][sdk] response text: %s\n", tp.Text)
				}
			}
		}
	}

	// ── Step 5: List events (check streaming) ────────────────────────────
	fmt.Println("\n[spike][sdk] checking event stream...")
	eventCtx, eventCancel := context.WithTimeout(ctx, 3*time.Second)
	defer eventCancel()
	stream := client.Event.ListStreaming(eventCtx, opencode.EventListParams{})
	count := 0
	for stream.Next() {
		evt := stream.Current()
		evtJSON, _ := json.Marshal(evt)
		fmt.Printf("[spike][sdk] event: %s\n", evtJSON)
		count++
		if count >= 5 {
			break
		}
	}
	if err := stream.Err(); err != nil && err != context.DeadlineExceeded {
		fmt.Printf("[spike][sdk] event stream error: %v\n", err)
	}
	fmt.Printf("[spike][sdk] received %d events\n", count)

	fmt.Println("\n[spike] done!")
}

// waitForHealth polls a health endpoint until it returns 200 or the timeout expires.
func waitForHealth(ctx context.Context, url string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 2 * time.Second}

	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		resp, err := client.Get(url)
		if err == nil {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == 200 {
				fmt.Printf("[spike] health response (%s): %s\n", url, string(body))
				return nil
			}
			fmt.Printf("[spike] health %d: %s\n", resp.StatusCode, string(body))
		}

		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %s", url)
}

// dumpHTTP makes an HTTP request and prints the response. Returns the response body.
func dumpHTTP(ctx context.Context, method, url string, body interface{}) []byte {
	var bodyReader io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		bodyReader = bytes.NewReader(b)
	}

	req, err := http.NewRequestWithContext(ctx, method, url, bodyReader)
	if err != nil {
		fmt.Printf("  error creating request: %v\n", err)
		return nil
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}

	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("  error: %v\n", err)
		return nil
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)
	fmt.Printf("  status: %d\n", resp.StatusCode)

	// Pretty print JSON if possible
	var pretty bytes.Buffer
	if json.Indent(&pretty, respBody, "  ", "  ") == nil {
		fmt.Printf("  body:\n  %s\n\n", pretty.String())
	} else {
		fmt.Printf("  body: %s\n\n", string(respBody))
	}

	return respBody
}
