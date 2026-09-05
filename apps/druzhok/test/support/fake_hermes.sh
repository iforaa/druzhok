#!/usr/bin/env bash
# Stand-in for `hermes gateway run` in tests. Prints its env, then idles.
echo "fake-hermes started args=$* HERMES_HOME=$HERMES_HOME TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN"
if [ -n "$FAKE_HERMES_EXIT" ]; then exit "$FAKE_HERMES_EXIT"; fi
while true; do sleep 1; done
