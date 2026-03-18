package db

import (
	"testing"
)

// testDB opens an in-memory SQLite database and registers cleanup.
func testDB(t *testing.T) *DB {
	t.Helper()
	d, err := Open(":memory:")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close() })
	return d
}

// --- Migrations --------------------------------------------------------------

func TestMigrations(t *testing.T) {
	d := testDB(t)

	// Running Migrate a second time must not return an error (idempotent).
	if err := d.Migrate(); err != nil {
		t.Fatalf("second Migrate() returned error: %v", err)
	}
}

// --- Users -------------------------------------------------------------------

func TestCreateAndGetUser(t *testing.T) {
	d := testDB(t)

	// First user must be admin.
	alice, err := d.CreateUser(101, "Alice")
	if err != nil {
		t.Fatalf("CreateUser Alice: %v", err)
	}
	if alice == nil {
		t.Fatal("CreateUser returned nil user")
	}
	if !alice.IsAdmin {
		t.Error("first user should be admin")
	}
	if alice.TgUserID != 101 {
		t.Errorf("TgUserID: got %d, want 101", alice.TgUserID)
	}
	if alice.Name != "Alice" {
		t.Errorf("Name: got %q, want %q", alice.Name, "Alice")
	}

	// Second user must NOT be admin.
	bob, err := d.CreateUser(202, "Bob")
	if err != nil {
		t.Fatalf("CreateUser Bob: %v", err)
	}
	if bob.IsAdmin {
		t.Error("second user should not be admin")
	}

	// GetUserByTgID must return the correct user.
	fetched, err := d.GetUserByTgID(101)
	if err != nil {
		t.Fatalf("GetUserByTgID: %v", err)
	}
	if fetched == nil {
		t.Fatal("GetUserByTgID returned nil for existing user")
	}
	if fetched.ID != alice.ID {
		t.Errorf("ID mismatch: got %s, want %s", fetched.ID, alice.ID)
	}

	// Non-existent user must return nil, nil.
	missing, err := d.GetUserByTgID(9999)
	if err != nil {
		t.Fatalf("GetUserByTgID non-existent: %v", err)
	}
	if missing != nil {
		t.Error("expected nil for non-existent user")
	}
}

// --- Chats -------------------------------------------------------------------

func TestCreateAndGetChat(t *testing.T) {
	d := testDB(t)

	user, err := d.CreateUser(101, "Alice")
	if err != nil {
		t.Fatalf("CreateUser: %v", err)
	}

	chat, err := d.CreateChat(user.ID, 555, "test-chat")
	if err != nil {
		t.Fatalf("CreateChat: %v", err)
	}
	if chat == nil {
		t.Fatal("CreateChat returned nil")
	}
	if chat.TgChatID != 555 {
		t.Errorf("TgChatID: got %d, want 555", chat.TgChatID)
	}
	if chat.Status != "active" {
		t.Errorf("Status: got %q, want %q", chat.Status, "active")
	}

	// GetChatByTgID
	fetched, err := d.GetChatByTgID(555)
	if err != nil {
		t.Fatalf("GetChatByTgID: %v", err)
	}
	if fetched == nil {
		t.Fatal("GetChatByTgID returned nil for existing chat")
	}
	if fetched.ID != chat.ID {
		t.Errorf("ID mismatch: got %s, want %s", fetched.ID, chat.ID)
	}

	// Non-existent chat returns nil, nil.
	missing, err := d.GetChatByTgID(9999)
	if err != nil {
		t.Fatalf("GetChatByTgID non-existent: %v", err)
	}
	if missing != nil {
		t.Error("expected nil for non-existent chat")
	}
}

func TestGetChatByID(t *testing.T) {
	d := testDB(t)

	user, _ := d.CreateUser(101, "Alice")
	chat, _ := d.CreateChat(user.ID, 555, "test-chat")

	fetched, err := d.GetChatByID(chat.ID)
	if err != nil {
		t.Fatalf("GetChatByID: %v", err)
	}
	if fetched == nil {
		t.Fatal("GetChatByID returned nil for existing chat")
	}
	if fetched.ID != chat.ID {
		t.Errorf("ID mismatch: got %s, want %s", fetched.ID, chat.ID)
	}

	missing, err := d.GetChatByID("no-such-id")
	if err != nil {
		t.Fatalf("GetChatByID non-existent: %v", err)
	}
	if missing != nil {
		t.Error("expected nil for non-existent chat ID")
	}
}

func TestUpdateSystemPrompt(t *testing.T) {
	d := testDB(t)

	user, _ := d.CreateUser(101, "Alice")
	chat, _ := d.CreateChat(user.ID, 555, "chat")

	if err := d.UpdateSystemPrompt(chat.ID, "Be helpful."); err != nil {
		t.Fatalf("UpdateSystemPrompt: %v", err)
	}

	updated, _ := d.GetChatByID(chat.ID)
	if updated.SystemPrompt != "Be helpful." {
		t.Errorf("SystemPrompt: got %q, want %q", updated.SystemPrompt, "Be helpful.")
	}
}

func TestUpdateSessionID(t *testing.T) {
	d := testDB(t)

	user, _ := d.CreateUser(101, "Alice")
	chat, _ := d.CreateChat(user.ID, 555, "chat")

	if err := d.UpdateSessionID(chat.ID, "sess-abc-123"); err != nil {
		t.Fatalf("UpdateSessionID: %v", err)
	}

	updated, _ := d.GetChatByID(chat.ID)
	if updated.OcSessionID != "sess-abc-123" {
		t.Errorf("OcSessionID: got %q, want %q", updated.OcSessionID, "sess-abc-123")
	}
}

// --- Messages ----------------------------------------------------------------

func TestMessageLifecycle(t *testing.T) {
	d := testDB(t)

	user, _ := d.CreateUser(101, "Alice")
	chat, _ := d.CreateChat(user.ID, 555, "chat")

	msg, err := d.SaveMessage(chat.ID, 1001, "user", "Hello!")
	if err != nil {
		t.Fatalf("SaveMessage: %v", err)
	}
	if msg == nil {
		t.Fatal("SaveMessage returned nil")
	}
	if msg.Status != "pending" {
		t.Errorf("initial status: got %q, want %q", msg.Status, "pending")
	}

	// Transition: pending → processing
	if err := d.UpdateMessageStatus(msg.ID, "processing"); err != nil {
		t.Fatalf("UpdateMessageStatus processing: %v", err)
	}
	// Transition: processing → completed
	if err := d.UpdateMessageStatus(msg.ID, "completed"); err != nil {
		t.Fatalf("UpdateMessageStatus completed: %v", err)
	}

	// Verify final state via GetPendingMessages (should not appear).
	pending, err := d.GetPendingMessages()
	if err != nil {
		t.Fatalf("GetPendingMessages: %v", err)
	}
	for _, m := range pending {
		if m.ID == msg.ID {
			t.Error("completed message should not appear in pending list")
		}
	}
}

func TestGetPendingMessages(t *testing.T) {
	d := testDB(t)

	user, _ := d.CreateUser(101, "Alice")

	// Active chat.
	activeChat, _ := d.CreateChat(user.ID, 111, "active-chat")

	// Inactive chat.
	inactiveChat, _ := d.CreateChat(user.ID, 222, "inactive-chat")
	_ = d.UpdateChatStatus(inactiveChat.ID, "inactive")

	// User message in active chat → should appear.
	pendingMsg, _ := d.SaveMessage(activeChat.ID, 1, "user", "hi from active")

	// Assistant message in active chat → should NOT appear (wrong role).
	_, _ = d.SaveMessage(activeChat.ID, 2, "assistant", "response")

	// User message in inactive chat → should NOT appear.
	_, _ = d.SaveMessage(inactiveChat.ID, 3, "user", "hi from inactive")

	msgs, err := d.GetPendingMessages()
	if err != nil {
		t.Fatalf("GetPendingMessages: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 pending message, got %d", len(msgs))
	}
	if msgs[0].ID != pendingMsg.ID {
		t.Errorf("wrong message returned: got %s, want %s", msgs[0].ID, pendingMsg.ID)
	}
}

func TestDuplicateChat(t *testing.T) {
	d := testDB(t)

	user, _ := d.CreateUser(101, "Alice")
	_, err := d.CreateChat(user.ID, 555, "chat-one")
	if err != nil {
		t.Fatalf("first CreateChat: %v", err)
	}

	// Creating a second chat with the same tg_chat_id must fail.
	_, err = d.CreateChat(user.ID, 555, "chat-two")
	if err == nil {
		t.Fatal("expected UNIQUE constraint error for duplicate tg_chat_id, got nil")
	}
}
