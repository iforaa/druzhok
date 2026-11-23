---
worth: yes
added: 2026-11-23
---
# fail2ban is not running on the gateway host

On alpha-eridanus (195.49.213.8) fail2ban is inactive, so repeated SSH login attempts are never banned.
SSH there accepts keys only, and `PermitRootLogin` is `without-password`, so this is hardening rather
than an open door. Seen in the 2026-11-21 lateral-movement check. Filed here because the gateway repo
was on a work branch that day; it is about the gateway host, not druzhok code.

Fix: find out why it stopped (it may never have been enabled), start and enable it with the sshd jail.
On cleo-demo a `systemctl reload nftables` drops fail2ban's table until its next ban; check whether the
gateway host has the same quirk. No gateway restart is needed.
