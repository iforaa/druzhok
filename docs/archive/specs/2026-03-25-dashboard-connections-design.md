# Dashboard: Connections & File Browser Fix

## 1. Instance Creation — TG Token Optional

Remove `token` from required fields. Form becomes: name, model, sandbox. User configures Telegram/App connections after creation in the Security tab.

## 2. Security Tab — Connection Sections

### Telegram Section
- **No token:** text input + "Save" button
- **Token set:** masked display (first 4...last 4), "Update" and "Remove" buttons

### App Connection Section
- **No API key:** "Generate API Key" button
- **Key exists:** masked `dk_...` display, "Copy" and "Regenerate" buttons
- Show WebSocket URL: `ws://{host}:4000/socket/chat`

## 3. File Browser — Directory Navigation Bug

`view_file` handler doesn't distinguish directories from files. Clicking a directory should list its contents (navigate into it), not try to read it as a file.

Fix: check `is_dir` in the event, and if true, call `list_dir` with the subdirectory path instead of `read_file`.

## Files to Change

- `dashboard_live.ex` — instance creation (remove required token), view_file handler (directory navigation)
- `security_tab.ex` — add Telegram and App Connection sections
- `instance.ex` / `instance_manager.ex` — make telegram_token optional on create
- `file_browser.ex` — support current_path for subdirectory navigation, back button
