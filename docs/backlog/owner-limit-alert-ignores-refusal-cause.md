---
worth: later
where: apps/druzhok/lib/druzhok/cabinet.ex:57
added: 2026-11-27
---
# owner's limit alert offers a top-up whatever the refusal was

`Cabinet @notice` now says «Пополнить баланс или сменить тариф можно в кабинете.» on every 402 / `usage_limit_reached`, including a windowed plan with overflow off, where a top-up would not be spent. Saying the right thing needs the refusal's cause passed into `out_of_money/1`. Unknown that settles it: whether any bot account ever has overflow off (no switch exists in the panel, so only the console can turn it off).
