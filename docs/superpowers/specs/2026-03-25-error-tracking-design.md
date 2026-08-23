# Dashboard Error Tracking

## Motivation

Elixir supervisors silently restart crashed processes. Errors and crashes go unnoticed unless you're watching `journalctl`. We need a way to capture and review errors from the dashboard.

## Backend

### Logger Backend (`Druzhok.ErrorLogger`)

Custom Elixir Logger backend that intercepts `:error` level messages and OTP crash reports. Stores them in SQLite.

### Schema: `crash_logs`

| Column | Type | Description |
|--------|------|-------------|
| id | integer | Primary key |
| level | string | "error" or "warning" |
| message | text | Error message, truncated to 4KB |
| source | string | Module/process info if available |
| instance_name | string | Instance name if identifiable, nullable |
| inserted_at | utc_datetime | When the error occurred |

Auto-cleanup: delete entries older than 7 days (checked every 100th insert).

### What gets captured

- OTP crash reports (GenServer terminating, process crashes)
- Logger.error calls
- Task failures
- Ecto query errors

## Frontend

### Global Errors Page (`/errors`)

Accessible from sidebar (link near Settings/Logout). Shows all errors across all instances.

- Table: timestamp, level, source, instance, message (truncated)
- Click row to expand full message
- Clear all button
- Auto-refresh every 10 seconds

### Instance "Errors" Tab

5th tab on instance detail view. Same display but filtered by `instance_name`.

## Files

- Create: `apps/druzhok/lib/druzhok/crash_log.ex` — Ecto schema
- Create: `apps/druzhok/lib/druzhok/error_logger.ex` — Logger backend
- Create: migration for `crash_logs` table
- Create: `apps/druzhok_web/lib/druzhok_web_web/live/errors_live.ex` — global page
- Create: `apps/druzhok_web/lib/druzhok_web_web/live/components/errors_tab.ex` — instance tab
- Modify: `apps/druzhok/lib/druzhok/application.ex` — add Logger backend
- Modify: `dashboard_live.ex` — add 5th tab
- Modify: router — add `/errors` route
