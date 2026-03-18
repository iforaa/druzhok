package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/igorkuznetsov/druzhok/internal/config"
	"github.com/igorkuznetsov/druzhok/internal/db"
	"github.com/igorkuznetsov/druzhok/internal/opencode"
	"github.com/igorkuznetsov/druzhok/internal/processor"
	"github.com/igorkuznetsov/druzhok/internal/skills"
	"github.com/igorkuznetsov/druzhok/internal/telegram"
)

// App holds all dependencies for the Druzhok bot.
type App struct {
	cfg      *config.Config
	db       *db.DB
	server   *opencode.Server
	client   *opencode.Client
	bot      *telegram.Bot
	proc     *processor.Processor
	skills   *skills.Registry
	wg       sync.WaitGroup
	commands map[string]bool
}

func main() {
	// 1. Load config.
	cfg, err := loadConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "config: %v\n", err)
		os.Exit(1)
	}

	// 2. Set up slog logger.
	setupLogger(cfg.LogLevel)

	// 3. Validate config.
	if err := cfg.Validate(); err != nil {
		slog.Error("invalid configuration", "error", err)
		os.Exit(1)
	}

	// 4. Create context with signal handler.
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	// 5. Ensure data directory exists and open SQLite database.
	if err := os.MkdirAll(cfg.DataDir, 0o755); err != nil {
		slog.Error("failed to create data directory", "path", cfg.DataDir, "error", err)
		os.Exit(1)
	}

	database, err := db.Open(filepath.Join(cfg.DataDir, "druzhok.db"))
	if err != nil {
		slog.Error("failed to open database", "error", err)
		os.Exit(1)
	}
	defer database.Close()

	// 6. Start OpenCode server.
	server := opencode.NewServer(opencode.ServerConfig{
		Port:    cfg.OpenCodePort,
		Host:    cfg.OpenCodeHost,
		BinPath: cfg.OpenCodeBin,
	})
	if err := server.Start(ctx); err != nil {
		slog.Error("failed to start opencode server", "error", err)
		os.Exit(1)
	}
	defer server.Stop()

	// 7. Create OpenCode client.
	client := opencode.NewClient(server.BaseURL())

	// 8. Load skills registry.
	registry, err := skills.NewRegistry("skills")
	if err != nil {
		slog.Warn("failed to load skills", "error", err)
		registry = &skills.Registry{}
	}

	// 9. Create processor.
	proc := processor.New(database, client, cfg.MaxConcurrentPrompts)

	// 10. Create App struct.
	app := &App{
		cfg:    cfg,
		db:     database,
		server: server,
		client: client,
		proc:   proc,
		skills: registry,
		commands: map[string]bool{
			"start":  true,
			"stop":   true,
			"reset":  true,
			"prompt": true,
			"model":  true,
		},
	}

	// 11. Create Telegram bot with app.handleMessage as handler.
	bot, err := telegram.NewBot(cfg.TelegramToken, app.handleMessage)
	if err != nil {
		slog.Error("failed to create telegram bot", "error", err)
		os.Exit(1)
	}

	// 12. Set app.bot.
	app.bot = bot

	// 13. Start health monitor goroutine.
	app.wg.Add(1)
	go func() {
		defer app.wg.Done()
		app.monitorHealth(ctx)
	}()

	// 14. Start retry loop goroutine.
	app.wg.Add(1)
	go func() {
		defer app.wg.Done()
		app.retryLoop(ctx)
	}()

	// 15. Start Telegram bot goroutine.
	app.wg.Add(1)
	go func() {
		defer app.wg.Done()
		bot.Start(ctx)
	}()

	// 16. Log "druzhok started".
	slog.Info("druzhok started")

	// 17. Wait for shutdown signal.
	<-ctx.Done()
	slog.Info("shutting down...")

	// 18. Cancel context (already cancelled by signal).
	cancel()

	// 19. Wait for WaitGroup with 30s timeout.
	done := make(chan struct{})
	go func() {
		app.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		// All goroutines exited cleanly.
	case <-time.After(30 * time.Second):
		slog.Warn("shutdown timed out after 30s")
	}

	// 20. Log "goodbye".
	slog.Info("goodbye")
}

// loadConfig tries the credentials file first, then falls back to env-only config.
func loadConfig() (*config.Config, error) {
	credPath := config.DefaultCredentialsPath()
	cfg, err := config.LoadFromFile(credPath)
	if err != nil {
		// File not found or unreadable — fall back to defaults + env.
		cfg, err = config.Load()
		if err != nil {
			return nil, err
		}
	} else {
		cfg.ApplyEnvOverrides()
	}
	return cfg, nil
}

// setupLogger configures the default slog logger based on the level string.
func setupLogger(level string) {
	var logLevel slog.Level
	switch strings.ToLower(level) {
	case "debug":
		logLevel = slog.LevelDebug
	case "warn", "warning":
		logLevel = slog.LevelWarn
	case "error":
		logLevel = slog.LevelError
	default:
		logLevel = slog.LevelInfo
	}

	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{
		Level: logLevel,
	})
	slog.SetDefault(slog.New(handler))
}

// handleMessage is the entry point for every incoming Telegram message.
func (a *App) handleMessage(ctx context.Context, chatID int64, userID int64, userName string, messageID int, text string) {
	log := slog.With("chat_id", chatID, "user_id", userID)

	// 1. Check built-in commands.
	kind, cmdName, cmdArgs := telegram.ClassifyMessage(text, a.commands)
	if kind == telegram.KindCommand {
		log.Debug("handling command", "command", cmdName)
		a.handleCommand(ctx, chatID, userID, userName, cmdName, cmdArgs)
		return
	}

	// 2. Check skills.
	if skill := a.skills.Match(text); skill != nil {
		log.Debug("skill matched", "skill", skill.Name)
		text = skill.BuildPrompt(text)
	}

	// 3. Get or create chat (auto-register on first message).
	chat, err := a.getOrCreateChat(ctx, chatID, userID, userName)
	if err != nil {
		log.Error("failed to get or create chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error. Please try again later.")
		return
	}

	// Check if chat is paused.
	if chat.Status == "paused" {
		_ = a.bot.SendMessage(ctx, chatID, "This chat is paused. Send /start to resume.")
		return
	}

	// 4. Save user message to DB.
	msg, err := a.db.SaveMessage(chat.ID, int64(messageID), "user", text)
	if err != nil {
		log.Error("failed to save message", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error. Please try again later.")
		return
	}

	// 5. Process in goroutine.
	a.wg.Add(1)
	go func() {
		defer a.wg.Done()

		response, err := a.proc.Process(ctx, *msg, chat)
		if err != nil {
			log.Error("failed to process message", "error", err)
			_ = a.db.UpdateMessageStatus(msg.ID, "failed")
			_ = a.bot.SendMessage(ctx, chatID, "Sorry, I could not process your message. Please try again.")
			return
		}

		if err := a.bot.SendMessage(ctx, chatID, response); err != nil {
			log.Error("failed to send response", "error", err)
		}
	}()
}

// getOrCreateChat ensures both the user and chat exist in the database.
func (a *App) getOrCreateChat(_ context.Context, chatID int64, userID int64, userName string) (*db.Chat, error) {
	// Ensure user exists.
	user, err := a.db.GetUserByTgID(userID)
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	if user == nil {
		user, err = a.db.CreateUser(userID, userName)
		if err != nil {
			return nil, fmt.Errorf("create user: %w", err)
		}
	}

	// Ensure chat exists.
	chat, err := a.db.GetChatByTgID(chatID)
	if err != nil {
		return nil, fmt.Errorf("get chat: %w", err)
	}
	if chat == nil {
		chat, err = a.db.CreateChat(user.ID, chatID, userName)
		if err != nil {
			return nil, fmt.Errorf("create chat: %w", err)
		}
	}

	return chat, nil
}

// handleCommand dispatches bot commands.
func (a *App) handleCommand(ctx context.Context, chatID int64, userID int64, userName string, cmd string, args string) {
	log := slog.With("chat_id", chatID, "command", cmd)

	switch cmd {
	case "start":
		a.cmdStart(ctx, chatID, userID, userName)
	case "stop":
		a.cmdStop(ctx, chatID, log)
	case "reset":
		a.cmdReset(ctx, chatID, log)
	case "prompt":
		a.cmdPrompt(ctx, chatID, userID, args, log)
	case "model":
		a.cmdModel(ctx, chatID, userID, args, log)
	default:
		_ = a.bot.SendMessage(ctx, chatID, "Unknown command.")
	}
}

func (a *App) cmdStart(ctx context.Context, chatID int64, userID int64, userName string) {
	chat, err := a.getOrCreateChat(ctx, chatID, userID, userName)
	if err != nil {
		slog.Error("start: failed to get or create chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}

	if chat.Status == "paused" {
		if err := a.db.UpdateChatStatus(chat.ID, "active"); err != nil {
			slog.Error("start: failed to reactivate chat", "error", err)
			_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
			return
		}
	}

	_ = a.bot.SendMessage(ctx, chatID, "Welcome to Druzhok! Send me a message and I'll respond.")
}

func (a *App) cmdStop(ctx context.Context, chatID int64, log *slog.Logger) {
	chat, err := a.db.GetChatByTgID(chatID)
	if err != nil {
		log.Error("stop: failed to get chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}
	if chat == nil {
		_ = a.bot.SendMessage(ctx, chatID, "No active chat found.")
		return
	}

	if err := a.db.UpdateChatStatus(chat.ID, "paused"); err != nil {
		log.Error("stop: failed to pause chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}

	_ = a.bot.SendMessage(ctx, chatID, "Chat paused. Send /start to resume.")
}

func (a *App) cmdReset(ctx context.Context, chatID int64, log *slog.Logger) {
	chat, err := a.db.GetChatByTgID(chatID)
	if err != nil {
		log.Error("reset: failed to get chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}
	if chat == nil {
		_ = a.bot.SendMessage(ctx, chatID, "No active chat found.")
		return
	}

	// Delete the OpenCode session if one exists.
	if chat.OcSessionID != "" {
		if err := a.client.DeleteSession(ctx, chat.OcSessionID); err != nil {
			log.Warn("reset: failed to delete opencode session", "error", err)
		}
		if err := a.db.UpdateSessionID(chat.ID, ""); err != nil {
			log.Error("reset: failed to clear session id", "error", err)
			_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
			return
		}
	}

	_ = a.bot.SendMessage(ctx, chatID, "Session reset. A new session will be created on your next message.")
}

func (a *App) cmdPrompt(ctx context.Context, chatID int64, userID int64, args string, log *slog.Logger) {
	chat, err := a.db.GetChatByTgID(chatID)
	if err != nil {
		log.Error("prompt: failed to get chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}
	if chat == nil {
		_ = a.bot.SendMessage(ctx, chatID, "No active chat found. Send /start first.")
		return
	}

	// No args: show current prompt.
	if args == "" {
		if chat.SystemPrompt == "" {
			_ = a.bot.SendMessage(ctx, chatID, "No system prompt is set.")
		} else {
			_ = a.bot.SendMessage(ctx, chatID, "Current system prompt:\n\n"+chat.SystemPrompt)
		}
		return
	}

	// With args: admin only.
	user, err := a.db.GetUserByTgID(userID)
	if err != nil {
		log.Error("prompt: failed to get user", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}
	if user == nil || !user.IsAdmin {
		_ = a.bot.SendMessage(ctx, chatID, "Only admins can change the system prompt.")
		return
	}

	if err := a.db.UpdateSystemPrompt(chat.ID, args); err != nil {
		log.Error("prompt: failed to update system prompt", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}

	_ = a.bot.SendMessage(ctx, chatID, "System prompt updated.")
}

func (a *App) cmdModel(ctx context.Context, chatID int64, userID int64, args string, log *slog.Logger) {
	if args == "" {
		_ = a.bot.SendMessage(ctx, chatID, "Usage: /model <model-id>")
		return
	}

	user, err := a.db.GetUserByTgID(userID)
	if err != nil {
		log.Error("model: failed to get user", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}
	if user == nil || !user.IsAdmin {
		_ = a.bot.SendMessage(ctx, chatID, "Only admins can change the model.")
		return
	}

	chat, err := a.db.GetChatByTgID(chatID)
	if err != nil {
		log.Error("model: failed to get chat", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}
	if chat == nil {
		_ = a.bot.SendMessage(ctx, chatID, "No active chat found. Send /start first.")
		return
	}

	if err := a.db.UpdateModel(chat.ID, args); err != nil {
		log.Error("model: failed to update model", "error", err)
		_ = a.bot.SendMessage(ctx, chatID, "Internal error.")
		return
	}

	_ = a.bot.SendMessage(ctx, chatID, fmt.Sprintf("Model updated to: %s", args))
}

// monitorHealth periodically checks the OpenCode server health and restarts it
// if necessary.
func (a *App) monitorHealth(ctx context.Context) {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()

	failures := 0
	const maxRetries = 3

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if a.server.IsHealthy() {
				failures = 0
				continue
			}

			failures++
			slog.Warn("opencode server unhealthy", "consecutive_failures", failures)

			if failures > maxRetries {
				slog.Error("opencode server failed health check too many times, giving up", "max_retries", maxRetries)
				continue
			}

			slog.Info("attempting to restart opencode server", "attempt", failures)
			if err := a.server.Stop(); err != nil {
				slog.Error("failed to stop opencode server", "error", err)
			}
			if err := a.server.Start(ctx); err != nil {
				slog.Error("failed to restart opencode server", "error", err)
			} else {
				slog.Info("opencode server restarted successfully")
				failures = 0
			}
		}
	}
}

// retryLoop periodically picks up pending messages from the database and
// processes them.
func (a *App) retryLoop(ctx context.Context) {
	ticker := time.NewTicker(a.cfg.PollInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			msgs, err := a.db.GetPendingMessages()
			if err != nil {
				slog.Error("retry loop: failed to get pending messages", "error", err)
				continue
			}

			for _, msg := range msgs {
				chat, err := a.db.GetChatByID(msg.ChatID)
				if err != nil {
					slog.Error("retry loop: failed to get chat", "chat_id", msg.ChatID, "error", err)
					continue
				}
				if chat == nil {
					slog.Warn("retry loop: chat not found for message", "chat_id", msg.ChatID, "msg_id", msg.ID)
					continue
				}

				m := msg // capture loop variable
				a.wg.Add(1)
				go func() {
					defer a.wg.Done()

					response, err := a.proc.Process(ctx, m, chat)
					if err != nil {
						slog.Error("retry loop: failed to process message", "msg_id", m.ID, "error", err)
						_ = a.db.UpdateMessageStatus(m.ID, "failed")
						return
					}

					if err := a.bot.SendMessage(ctx, chat.TgChatID, response); err != nil {
						slog.Error("retry loop: failed to send response", "chat_id", chat.TgChatID, "error", err)
					}
				}()
			}
		}
	}
}
