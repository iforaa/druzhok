package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/mdlayher/vsock"
)

const (
	listenAddr     = ":9999"
	workspaceDir   = "/workspace"
	execTimeout    = 5 * time.Minute
	maxScannerBuf  = 10 * 1024 * 1024 // 10 MB max message size
)

// Request represents an incoming JSON line command.
type Request struct {
	ID      string `json:"id"`
	Type    string `json:"type"`
	Secret  string `json:"secret,omitempty"`
	Command string `json:"command,omitempty"`
	Path    string `json:"path,omitempty"`
	Content string `json:"content,omitempty"`
}

// Response represents an outgoing JSON line.
type Response struct {
	ID      string `json:"id,omitempty"`
	Type    string `json:"type"`
	Data    string `json:"data,omitempty"`
	Code    *int   `json:"code,omitempty"`
	Message string `json:"message,omitempty"`
}

// DirEntry represents a directory listing entry.
type DirEntry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"is_dir"`
	Size  int64  `json:"size"`
}

// FileStat represents file stat info.
type FileStat struct {
	Size     int64  `json:"size"`
	IsDir    bool   `json:"is_dir"`
	Modified string `json:"modified"`
}

func main() {
	useVsock := flag.Bool("vsock", false, "Listen on vsock instead of TCP")
	flag.Parse()

	secret := os.Getenv("SANDBOX_SECRET")

	// Ensure workspace directory exists.
	if err := os.MkdirAll(workspaceDir, 0o755); err != nil {
		log.Printf("warning: could not create %s: %v", workspaceDir, err)
	}

	var listener net.Listener
	var err error

	if *useVsock {
		listener, err = vsock.Listen(9999, nil)
		log.Println("Listening on vsock port 9999")
	} else {
		listener, err = net.Listen("tcp", listenAddr)
		log.Println("Listening on TCP :9999")
	}
	if err != nil {
		log.Fatal(err)
	}

	// Accept only one connection.
	conn, err := listener.Accept()
	if err != nil {
		log.Fatalf("accept error: %v", err)
	}
	log.Printf("accepted connection from %s", conn.RemoteAddr())
	listener.Close() // Stop accepting new connections.

	handleConnection(conn, secret)
}

func handleConnection(conn net.Conn, secret string) {
	defer conn.Close()

	var mu sync.Mutex
	writeLine := func(resp Response) {
		data, err := json.Marshal(resp)
		if err != nil {
			log.Printf("marshal error: %v", err)
			return
		}
		mu.Lock()
		defer mu.Unlock()
		data = append(data, '\n')
		conn.Write(data)
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 0, maxScannerBuf), maxScannerBuf)

	// If no secret set, skip auth requirement (vsock mode, already isolated).
	authenticated := secret == ""
	if authenticated {
		log.Println("no SANDBOX_SECRET set, skipping auth")
	}

	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "" {
			continue
		}

		var req Request
		if err := json.Unmarshal([]byte(line), &req); err != nil {
			writeLine(Response{Type: "error", Message: "invalid JSON"})
			continue
		}

		// Authentication gate.
		if !authenticated {
			if req.Type != "auth" {
				writeLine(Response{Type: "error", Message: "not authenticated"})
				continue
			}
			if req.Secret != secret {
				log.Printf("auth failed, closing connection")
				return
			}
			authenticated = true
			writeLine(Response{Type: "auth_ok"})
			log.Printf("client authenticated")
			continue
		}

		// Dispatch commands.
		switch req.Type {
		case "exec":
			handleExec(req, writeLine)
		case "read":
			handleRead(req, writeLine)
		case "write":
			handleWrite(req, writeLine)
		case "mkdir":
			handleMkdir(req, writeLine)
		case "ls":
			handleLs(req, writeLine)
		case "stat":
			handleStat(req, writeLine)
		default:
			writeLine(Response{ID: req.ID, Type: "error", Message: fmt.Sprintf("unknown command: %s", req.Type)})
		}
	}

	if err := scanner.Err(); err != nil {
		log.Printf("scanner error: %v", err)
	}
	log.Printf("connection closed")
}

// guardPath resolves the path and ensures it is under /workspace.
func guardPath(path string) (string, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", fmt.Errorf("invalid path: %w", err)
	}

	// Try to resolve symlinks. If the path doesn't exist yet,
	// resolve the parent directory instead.
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		// Path doesn't exist — resolve parent.
		parent := filepath.Dir(abs)
		resolvedParent, err2 := filepath.EvalSymlinks(parent)
		if err2 != nil {
			return "", fmt.Errorf("path not accessible: %w", err2)
		}
		resolved = filepath.Join(resolvedParent, filepath.Base(abs))
	}

	if !strings.HasPrefix(resolved, workspaceDir) {
		return "", fmt.Errorf("path outside workspace: %s", path)
	}
	return resolved, nil
}

func handleExec(req Request, writeLine func(Response)) {
	ctx, cancel := context.WithTimeout(context.Background(), execTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "bash", "-c", req.Command)
	cmd.Dir = workspaceDir

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	if err := cmd.Start(); err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	var wg sync.WaitGroup
	streamPipe := func(pipe io.Reader, streamType string) {
		defer wg.Done()
		buf := make([]byte, 4096)
		for {
			n, err := pipe.Read(buf)
			if n > 0 {
				writeLine(Response{ID: req.ID, Type: streamType, Data: string(buf[:n])})
			}
			if err != nil {
				break
			}
		}
	}

	wg.Add(2)
	go streamPipe(stdout, "stdout")
	go streamPipe(stderr, "stderr")
	wg.Wait()

	exitCode := 0
	if err := cmd.Wait(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			exitCode = -1
		} else if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = -1
		}
	}

	writeLine(Response{ID: req.ID, Type: "exit", Code: &exitCode})
}

func handleRead(req Request, writeLine func(Response)) {
	resolved, err := guardPath(req.Path)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	data, err := os.ReadFile(resolved)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	writeLine(Response{ID: req.ID, Type: "result", Data: string(data)})
}

func handleWrite(req Request, writeLine func(Response)) {
	resolved, err := guardPath(req.Path)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	// Create parent directories.
	if err := os.MkdirAll(filepath.Dir(resolved), 0o755); err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	if err := os.WriteFile(resolved, []byte(req.Content), 0o644); err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	writeLine(Response{ID: req.ID, Type: "result", Data: "ok"})
}

func handleMkdir(req Request, writeLine func(Response)) {
	resolved, err := guardPath(req.Path)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	if err := os.MkdirAll(resolved, 0o755); err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	writeLine(Response{ID: req.ID, Type: "result", Data: "ok"})
}

func handleLs(req Request, writeLine func(Response)) {
	resolved, err := guardPath(req.Path)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	entries, err := os.ReadDir(resolved)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	var dirEntries []DirEntry
	for _, e := range entries {
		info, err := e.Info()
		if err != nil {
			continue
		}
		dirEntries = append(dirEntries, DirEntry{
			Name:  e.Name(),
			IsDir: e.IsDir(),
			Size:  info.Size(),
		})
	}

	jsonData, err := json.Marshal(dirEntries)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	writeLine(Response{ID: req.ID, Type: "result", Data: string(jsonData)})
}

func handleStat(req Request, writeLine func(Response)) {
	resolved, err := guardPath(req.Path)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	info, err := os.Stat(resolved)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	stat := FileStat{
		Size:     info.Size(),
		IsDir:    info.IsDir(),
		Modified: info.ModTime().UTC().Format(time.RFC3339),
	}

	jsonData, err := json.Marshal(stat)
	if err != nil {
		writeLine(Response{ID: req.ID, Type: "error", Message: err.Error()})
		return
	}

	writeLine(Response{ID: req.ID, Type: "result", Data: string(jsonData)})
}
