---
worth: later
where: apps/druzhok/lib/druzhok/disk_check.ex:36
added: 2026-11-23
---
# superbot repeats two disk messages to the operator every hour

`DiskCheck` sends the operator two messages through the superbot at most once an hour each, for as long
as the condition holds: "bots without a limit" and "quotas lost". On 2026-11-21 the first one surprised
the owner while limits were applied to one bot only. The owner accepted the messages but did not choose
a frequency.

Open: the owner's choice between hourly, once a day, or once per episode.
