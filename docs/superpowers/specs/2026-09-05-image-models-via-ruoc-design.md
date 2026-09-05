# Image models via ruoc-gateway

Date: 2026-09-05. Status: **built** (not yet deployed). Depends on ruoc-gateway
`docs/superpowers/specs/2026-09-05-image-generation-design.md`.

Image generation stops going from druzhok to OpenRouter directly. The list of
image models and their ruble prices come from ruoc-gateway, the bot's ruoc
key pays per image, and the tenant picks the model (or switches the tool
off) from the manager bot. Druzhok keeps no image price and no model list of
its own.

## Data

`instances.image_gen_enabled` (boolean) and `instances.image_gen_model`
(string) already exist and keep their meaning: `image_gen_model` now holds a
ruoc catalogue id (`ruoc-flux-klein`), nil meaning "ruoc's default". Existing
rows hold OpenRouter ids (`black-forest-labs/flux.2-klein-4b`); a migration
sets `image_gen_model` to nil where it is not nil, since every current value
is an OpenRouter id and ruoc's default is the same FLUX model.

The hardcoded `@image_gen_models` / `@default_image_gen_model` in the proxy
controller are deleted along with `ImageGen.image_gen_models/0` and
`default_image_gen_model/0`.

## ruoc client (`Druzhok.Ruoc`)

```elixir
@spec image_models() :: {:ok, [%{id: String.t(), name: String.t(),
                              description: String.t(),
                              rub_per_image: Decimal.t() | String.t(),
                              default: boolean()}]} | {:error, term()}
def image_models
```

Calls `GET /v1/images/models` with the catalogue key, like `models/0`.
Returned in ruoc's order. Callers treat `{:error, _}` as "no models right now"
and say so to the user; nothing is cached, the manager bot calls it when the
menu opens.

## Proxy (`LlmProxy.Ruoc.generate_image/3`)

`POST /v1/images/generations` (hermes's OpenAI image plugin) is served by
`LlmProxyController.images_generations/2`, which now calls
`LlmProxy.Ruoc.generate_image(conn, instance, prompt)`:

- posts `{"prompt": prompt, "model": instance.image_gen_model}` to ruoc
  `POST /v1/images` with the bot's key (`model` omitted when nil), receive
  timeout 190 s;
- 200 → OpenAI shape `{"created": unix, "data": [{"b64_json": b64}]}`, and
  a usage row `request_type: "image_gen"`, `model` = ruoc id from the reply,
  `cost_cents: 0`, ruoc request id in the log line, as chat and search do;
- 402 → 402 with an OpenAI error whose `message` is
  `BalanceNotice.text(instance)` (the existing localized "balance used up"
  text), so hermes's tool error reaches the tenant in the bot's language;
- 400 unknown model → 400 with ruoc's message (the model was removed on
  ruoc; the tenant re-picks in the manager bot);
- 5xx / connection error → 502 "Image generation provider unavailable" as
  today.

The request body's `model` from hermes stays ignored (hermes sends OpenAI
ids). `image_modalities/1`, `extract_images/1` and the OpenRouter call are
deleted with the old path; `image_gen_test.exs` is rewritten against
`RuocStub`.

## Manager bot

«Мои боты» gains a 🎨 button per bot, next to 💬 and 🗑, callback
`img:<instance id>`.

Tapping it edits the message into the picture menu built by
`Onboarding.image_menu(bot, models)`:

```
🎨 Картинки для @handle

Сейчас: выключено
```
or `Сейчас: FLUX 2 Klein · 2 ₽ за картинку`. Keyboard: one row
`🚫 Выкл` (callback `imgoff:<id>`), then one row per model
`✅ FLUX 2 Klein · 2 ₽` / `FLUX 2 Pro · 5 ₽` (callback
`imgset:<id>:<model id>`, ✅ on the current one; when the tool is on and
`image_gen_model` is nil the ✅ sits on ruoc's default), and a final row
`« Назад` (callback `imgback`) which redraws «Мои боты». Ruoc ids are short
ASCII, so callback data stays under Telegram's 64 bytes.

Ownership is checked exactly as for deletion (`owned_instance/2`); a foreign
id answers "Это не твой бот".

Actions (`ManagerBot`):

- `imgset` when the tool is off: `BotManager.update_image_gen(name, enabled?,
  model)` (new; a changeset update on the instance row, the same thing the
  settings tab's private `update_instance/2` does today, which moves into
  `BotManager` so both callers share it), then a restart with the message
  `⏳ Включаю картинки для @handle…` edited into
  `✅ Картинки включены: FLUX 2 Klein · 2 ₽ за картинку` (or the failure
  text from the restart).
- `imgset` when the tool is on: DB update only, the proxy reads the model per
  request; the menu is redrawn with the new ✅. No restart.
- `imgoff` when on: update `image_gen_enabled: false`, restart,
  `✅ Картинки выключены`. When already off: redraw the menu.
- If `Ruoc.image_models/0` fails, the menu says
  `Список моделей сейчас недоступен, попробуй позже` with only «Назад».

Restarts go through `BotManager.restart/1` so `sync_config` rewrites the
`image_gen` block, which is what turns the tool on or off in hermes. The
restart runs in a spawned task as provisioning does, with a monitor, so the
GenServer keeps answering other users meanwhile.

## Dashboard settings tab

The image select is fed from `Ruoc.image_models/0` (name plus ₽ per image),
with a "default" option for nil. Changing the model no longer restarts the
bot (the proxy reads it per request); toggling enabled still does. When the
list is unavailable the select is replaced by "ruoc catalogue unavailable".

## Testing

- `Druzhok.RuocTest`: `image_models/0` parses the list, keeps order,
  surfaces `{:error, _}` on non-200.
- `LlmProxy.Ruoc` image tests (`llm_proxy/ruoc/image_test.exs`, RuocStub):
  forwards prompt and model, omits model when nil, returns OpenAI shape,
  writes the usage row, 402 → localized notice, 400 passthrough, 5xx → 502.
- `OnboardingTest`: `image_menu/2` text and keyboard for off, on with model,
  on with nil model, failed list.
- `ManagerBotTest` (TelegramStub + RuocStub): 🎨 opens the menu; `imgset`
  from off updates the row and restarts; `imgset` while on updates without a
  restart; `imgoff` restarts; foreign id refused.
- `SettingsTabTest`: select options come from the stub; model change does not
  restart.

## Deploy

1. ruoc-gateway first (`deploy/deploy.sh`), then `ruocd image add` for the
   four models from the ruoc spec.
2. druzhok: migration, rsync deploy, `sudo systemctl restart druzhok`.
3. Verify: 🎨 menu on the operator's bot, generate one image through it,
   confirm the debit on the ruoc account page and a `image_gen` usage row
   with cost 0 in druzhok.

TTS and `/v1/responses` stay on OpenRouter until their own specs.
