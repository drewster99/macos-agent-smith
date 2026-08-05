#!/usr/bin/env bash
#
# Watches the AgentSmith GUI and captures a stack sample WHILE it is beachballing.
#
# A hang reported after the fact cannot be diagnosed: by the time anyone runs `sample`, the main
# thread is back to idling in mach_msg and the sample shows a healthy app. This leaves a watcher
# running so the next stall is caught with the stack that caused it.
#
#   ./scripts/catch_hang.sh              # watch, print nothing until something stalls
#   ./scripts/catch_hang.sh 3            # call it a hang after 3 consecutive busy checks (~3s)
#
# Detection: one-second samples, checking whether the main thread is parked in mach_msg2_trap (the
# run loop waiting for events). Parked = idle, whatever the CPU meter says. Busy for N consecutive
# checks = a stall the user would see as a beachball, and the full sample is kept.
#
# Deliberately does NOT use `spindump`: it needs sudo, and its whole-system report buries the one
# process being investigated.

set -uo pipefail

threshold="${1:-3}"
#: Seconds between checks. Each check samples the target for a second, which is not free — polling
#: hard would add load to the very app being watched for sluggishness. Six seconds keeps the duty
#: cycle low; the cost is detection latency, spelled out below rather than left to be worked out.
interval=6
outdir="${TMPDIR:-/tmp}AgentSmith-hangs"
mkdir -p "$outdir"

# The GUI process, NOT a headless --eval-capabilities run: those legitimately peg a thread for
# minutes and would trip the detector on every probe sweep.
find_gui() {
  for candidate in $(pgrep -x AgentSmith 2>/dev/null); do
    if ! ps -o args= -p "$candidate" 2>/dev/null | grep -q -- "--eval-capabilities\|--list-models"; then
      echo "$candidate"; return
    fi
  done
}

# Each cycle is one 1s sample plus the interval, so the trip point is roughly this.
trips_after=$(( threshold * (interval + 1) ))
echo "watching for hangs — checking every ${interval}s; ${threshold} consecutive busy checks trips it"
echo "  so a stall is caught after roughly ${trips_after}s (pass a smaller threshold to catch sooner)"
echo "  samples land in ${outdir}"
echo "(ctrl-c to stop)"

busy=0
while true; do
  pid="$(find_gui)"
  if [[ -z "${pid}" ]]; then busy=0; sleep "${interval}"; continue; fi

  snapshot="$(sample "${pid}" 1 -mayDie -file /dev/stdout 2>/dev/null)"
  # The main thread's own line, and whether it bottoms out in the event-wait trap.
  if grep -q "mach_msg2_trap" <<<"$(awk '/com.apple.main-thread/,/^$/' <<<"${snapshot}")"; then
    if (( busy > 0 )); then echo "  recovered (was busy for ${busy} check(s))"; fi
    busy=0
  else
    busy=$(( busy + 1 ))
    echo "  main thread busy (${busy}/${threshold})"
    if (( busy == threshold )); then
      stamp="$(date +%Y%m%d-%H%M%S)"
      file="${outdir}/hang-${stamp}.txt"
      echo "  HANG — capturing 5s to ${file}"
      sample "${pid}" 5 -file "${file}" >/dev/null 2>&1
      # The deepest frames of OUR code are what identifies the culprit; the SwiftUI/AppKit
      # scaffolding above them is the same in every capture.
      echo "  --- our frames, deepest last ---"
      grep "AgentSmith.debug.dylib\|AgentSmithKit" "${file}" | tail -12 | sed 's/^/    /'
      busy=0
    fi
  fi
  sleep "${interval}"
done
