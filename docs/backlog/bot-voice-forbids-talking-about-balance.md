---
worth: later
where: apps/druzhok/lib/druzhok/runtime/hermes/voice.ex:326
added: 2026-11-27
---
# bots are still told never to mention «баланс»

`Voice` rules (also line 68) forbid the bot from talking about a balance or credits, written when bots only had plans. Since #56 an owner can top up, so an owner asking the bot how to add money gets a dodge instead of «в «Кабинете» → Счёт». Unknown that settles it: whether the bot should name the balance to the owner only (the rule is shared with group chatters, who cannot pay).
