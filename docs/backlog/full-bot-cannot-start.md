---
worth: later
where: apps/druzhok/lib/druzhok/disk_check.ex:186
added: 2026-11-23
---
# a bot at its disk limit cannot start again

A bot that is running when it fills its disk limit stays up and logs `Disk quota exceeded`. Once it
stops or sleeps it cannot start: hermes dies at startup because sqlite cannot write (`disk I/O error`).
In queue mode every idle bot sleeps, so a full bot stays down until the operator raises its limit with
`ops/druzhok set <bot> disk_mb=<n>` and starts it. Tested on cleo-demo on 2026-11-21 with a 20 MB limit
on a test bot; raising the limit brought the bot back at once.

Open: whether a full bot should recover alone. The owner has not decided. One idea is a small reserve
above the limit that only startup may use. What a chat user sees when writing to a full bot was not
tested.
