# Worker tests need the Python venv (see docs/superpowers/specs/2026-09-05-web-fetch-service-design.md).
worker_bin = Application.get_env(:druzhok, :fetch_worker_bin)

exclude = if(worker_bin && File.exists?(worker_bin), do: [], else: [:fetch_worker])

# The panel's real lister needs GNU find (-printf); macOS's find is not.
find_bin = Application.get_env(:druzhok, :find_bin, "/usr/bin/find")

gnu_find? =
  try do
    match?({"find (GNU findutils)" <> _, 0}, System.cmd(find_bin, ["--version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

exclude = if gnu_find?, do: exclude, else: [:gnu_find | exclude]
if not gnu_find?, do: IO.puts("GNU find not found at #{inspect(find_bin)}; skipping :gnu_find tests")

if :fetch_worker in exclude, do: IO.puts("fetch worker venv not found at #{inspect(worker_bin)}; skipping :fetch_worker tests")
ExUnit.start(exclude: exclude)
{:ok, _} = Application.ensure_all_started(:bypass)

# The application's own ManagerBot re-reads `manager_bot_token` every 60 s.
# Tests drive their own named instances against a stub Telegram API, so keep
# the global one from waking up and polling the stub too.
:ok = Supervisor.terminate_child(Druzhok.Supervisor, Druzhok.ManagerBot)
