# Worker tests need their Python venvs (see docs/superpowers/specs/2026-09-05-web-fetch-service-design.md
# and docs/superpowers/specs/2026-09-06-mnemosyne-memory-design.md).
worker_bin = Application.get_env(:druzhok, :fetch_worker_bin)
embed_bin = Application.get_env(:druzhok, :embed_worker_bin)
embed_model = Application.get_env(:druzhok, :embed_model_dir)

exclude =
  if(worker_bin && File.exists?(worker_bin), do: [], else: [:fetch_worker]) ++
    if(embed_bin && File.exists?(embed_bin) && embed_model && File.exists?(Path.join(embed_model, "model.onnx")),
      do: [],
      else: [:embed_worker]
    )

if :fetch_worker in exclude, do: IO.puts("fetch worker venv not found at #{inspect(worker_bin)}; skipping :fetch_worker tests")
if :embed_worker in exclude, do: IO.puts("embed worker venv/model not found; skipping :embed_worker tests")
ExUnit.start(exclude: exclude)
{:ok, _} = Application.ensure_all_started(:bypass)

# The application's own ManagerBot re-reads `manager_bot_token` every 60 s.
# Tests drive their own named instances against a stub Telegram API, so keep
# the global one from waking up and polling the stub too.
:ok = Supervisor.terminate_child(Druzhok.Supervisor, Druzhok.ManagerBot)
