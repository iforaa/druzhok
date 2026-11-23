---
worth: later
added: 2026-11-23
---
# a bot's /tmp is outside its disk limit

The per-bot disk limit is an ext4 user quota on `/data`. A bot's `/tmp` is on the system disk, so files
written there do not count and one bot can fill the system disk. The first design bound a bot-owned
`tmp` folder from the tenant directory over `/tmp`; the spec review rejected it because the bot could
replace that folder with a link to a host path. Dropped from PR #52 by the owner's decision.

Open: a design that puts `/tmp` under a limit without giving the bot control of the mount source, for
example a size-limited tmpfs per unit. Until one exists the value call cannot be made.
