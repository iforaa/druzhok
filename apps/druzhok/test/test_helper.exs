ExUnit.start()
{:ok, _} = Application.ensure_all_started(:bypass)

# The application's own ManagerBot re-reads `manager_bot_token` every 60 s.
# Tests drive their own named instances against a stub Telegram API, so keep
# the global one from waking up and polling the stub too.
:ok = Supervisor.terminate_child(Druzhok.Supervisor, Druzhok.ManagerBot)
