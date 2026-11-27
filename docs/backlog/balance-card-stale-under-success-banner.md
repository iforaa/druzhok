---
worth: yes
where: apps/druzhok_web/assets/app/src/billing.tsx:187
added: 2026-11-27
---
# Счёт keeps the old balance while «Баланс пополнен» is shown

Seen in the live test on 2026-11-27: after a late bank confirmation and «Проверить ещё раз», the banner said «Баланс пополнен на 100 ₽.» while the card still showed the old 468,57 ₽ and the spent «Перейти к оплате · 100 ₽» button; only «Хорошо» reloaded `me`. Reload `me` (and drop the opened link) when the watch reports paid, not when the banner is dismissed.
