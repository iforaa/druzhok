---
worth: yes
added: 2026-11-23
---
# leftovers on cleo-demo after the move to Elixir 1.19.7

The move to Elixir 1.19.7-otp-28 (#51, deployed 2026-11-21) left three things undone:

- **No real Telegram message was tested.** The service is up, there are no errors in the log, and the
  bots' `/mcp/cleohub` calls return 200, but nobody sent a bot a message and read the reply. Do this
  first; the two deletions below remove the rollback path.
- **`/data/druzhok-app/_build.ex118`** is the old build, kept for rollback together with the old
  `.tool-versions` and `mix.lock` in `/data/backups/sec-20261121-deps`. Delete it once the test passes.
  Elixir 1.18.4-otp-28 is also still installed in asdf.
- **`/data/druzhok-app/erl_crash.dump`** (6.6 MB, 2026-11-15, owner `druzhok`) is harmless: a one-off
  process killed during the OTP upgrade. It may hold environment secrets, so delete it rather than
  keep it. It also breaks an rsync of the tree run as `ubuntu`, which cannot read it.
