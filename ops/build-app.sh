#!/usr/bin/env bash
# Builds the bot panel (apps/druzhok_web/assets/app) into
# apps/druzhok_web/priv/static/app, which is committed and rsynced with the
# rest of `apps`. Run before a deploy that changed the page.
set -euo pipefail
dir="$(cd "$(dirname "$0")/.." && pwd)/apps/druzhok_web/assets/app"
cd "$dir"
npm ci --no-audit --no-fund
npm run build
