---
worth: yes
added: 2026-11-23
---
# bot server holds a Cloudflare token that can edit DNS on every zone

`/etc/caddy/env` on cleo-demo holds the Cloudflare token «Edit zone DNS» created 2026-08-24. It has DNS
Write on all 8 zones of the account, not only `oldey.dev`. Anyone who breaks out of a bot and reads that
file can repoint any of the domains. The gateway host (alpha-eridanus) very likely uses the same token for
its `oldey.dev` and `*.oldey.dev` certificates. Found in the 2026-11-21 lateral-movement check.

Fix, in this order, each step with the owner's go-ahead:

1. cleo-demo: remove the `tls { dns cloudflare ... }` block from `druzhok.oldey.dev` in
   `/etc/caddy/Caddyfile` and empty `/etc/caddy/env`. `demo.oldey.dev` on the same server already gets
   its certificate without a token (renewed 2026-10-25). Back up both files first.
2. Gateway host: create a new token limited to DNS Write on `oldey.dev`, locked to the gateway's IP
   (195.49.213.8), put it in the gateway's `/etc/caddy/env`. Test it with a read-only DNS call from the
   gateway before going on. A wrong token breaks nothing today but the wildcard certificate (issued
   2026-10-23) would fail to renew around late December and every bot site would show a certificate error.
3. Delete the all-zones token in Cloudflare. Check its "last used" first: it was 2026-10-31, which fits
   the two servers alone, but another machine (for example the old Yandex VM) could hold it.

Checked 2026-11-21, none of this breaks: cleotunnel uses its own token `cleotunnel-acme-dns`
(`cleoremote.dev` only, IP-locked), which the plan does not touch; Cleo Code web access goes through that
tunnel; bot sites need no Cloudflare call when created, they use the one `*.oldey.dev` record and the
gateway's wildcard certificate. The older «Edit zone DNS» token from 2026-04-17 (`oldey.dev` only, unused
since 2026-08-14) can be deleted in the same pass.
