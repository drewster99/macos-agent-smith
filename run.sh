#!/usr/bin/env bash
#
# Finds the most recently built AgentSmith binary in Xcode's DerivedData and execs it,
# passing through any arguments. Handy for the headless capability eval, e.g.:
#
#   ./run.sh --list-models
#   ./run.sh --eval-capabilities --targets builtin.anthropic/claude-sonnet-5
#
# With no arguments it just launches the app.
#
# "Latest" is by binary mtime, so it always tracks your most recent build — including after a
# clean build changes the DerivedData hash. Build in Xcode (or via drews-xcode-mcp) first; this
# script only runs what's already built, it does not build.

set -euo pipefail

derived="${HOME}/Library/Developer/Xcode/DerivedData"

# Newest AgentSmith binary by modification time. -t sorts newest-first; the glob covers every
# DerivedData hash and both Debug/Release. `head -1` takes the freshest.
binary="$(
  ls -td "${derived}"/AgentSmith-*/Build/Products/*/AgentSmith.app/Contents/MacOS/AgentSmith 2>/dev/null \
    | head -1 || true
)"

if [[ -z "${binary}" || ! -x "${binary}" ]]; then
  echo "run.sh: no built AgentSmith binary found under ${derived}" >&2
  echo "        Build the app in Xcode (or via drews-xcode-mcp) first." >&2
  exit 1
fi

echo "run.sh: $(basename "$(dirname "$(dirname "$(dirname "$(dirname "${binary}")")")")") — $(stat -f '%Sm' -t '%Y-%m-%d %H:%M:%S' "${binary}")" >&2
exec "${binary}" "$@"
