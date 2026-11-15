# Sourced, not run: puts the Erlang and Elixir that .tool-versions names on
# PATH and sets the env druzhok runs with, for druzhok.service and the ops
# scripts alike.
#
# Druzhok runs as its own user `druzhok`, which has no sudo beyond druzhok-ctl
# and docs-convert and cannot write the code it runs. asdf's shims call
# ~ubuntu/.asdf/bin/asdf, inside a home `druzhok` cannot enter, so the installs
# are used directly.
DRUZHOK_APP=${DRUZHOK_APP:-/data/druzhok-app}
ASDF_INSTALLS=${ASDF_INSTALLS:-/data/home-ubuntu/.asdf/installs}

_erlang=$(awk '$1 == "erlang" { print $2 }' "$DRUZHOK_APP/.tool-versions")
_elixir=$(awk '$1 == "elixir" { print $2 }' "$DRUZHOK_APP/.tool-versions")
if [ ! -x "$ASDF_INSTALLS/erlang/$_erlang/bin/erl" ] || [ ! -x "$ASDF_INSTALLS/elixir/$_elixir/bin/mix" ]; then
  echo "runtime-env: erlang $_erlang or elixir $_elixir is not installed under $ASDF_INSTALLS" >&2
  return 1 2>/dev/null || exit 1
fi
export PATH="$ASDF_INSTALLS/erlang/$_erlang/bin:$ASDF_INSTALLS/elixir/$_elixir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME=/data/druzhok-home TMPDIR=/data/druzhok-home/tmp LANG=C.UTF-8
unset _erlang _elixir
