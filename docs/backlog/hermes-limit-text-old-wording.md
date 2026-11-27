---
worth: later
added: 2026-11-27
---
# Hermes's built-in limit text differs from druzhok's notice

Hermes's own limit and failure strings in druzhok's locale overlay (`Runtime.Hermes.Locale`, `priv/hermes_locale`) still use their earlier wording, so a group can see two different texts for a spent limit: `LlmProxy.BalanceNotice` on chat and Hermes's own on its auxiliary paths. Noted by the druzhok worker on #56. Unknown that settles it: whether those Hermes paths reach tenants at all in practice.
