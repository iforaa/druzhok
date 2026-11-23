---
worth: yes
where: apps/druzhok/lib/druzhok/status.ex
added: 2026-11-23
---
# CleoHub console does not show bot disk usage

Druzhok status already reports `disk_used_mb`, `disk_limit_mb` and `disk_pct` for each bot and a
top-level `disk_quota` (PR #52). The CleoHub console page in ruoc-gateway does not show them, so the
operator sees disk usage only in `ops/druzhok list`. The work is in ruoc-gateway: a disk column next to
the memory column. Left out of PR #52 because it is a second repo.
