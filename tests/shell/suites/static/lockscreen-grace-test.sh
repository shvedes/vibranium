#!/bin/bash
# Suite: lockscreen-grace - grace is idle-only, expires on the wall clock.
#
# The grace window lets an idle-triggered lock release on the first real input,
# so a user already back after an idle timeout is not asked for a password. The
# flaw this suite pins: arming grace on every lock let a suspend-triggered lock
# carry an armed window into sleep, and a QML timer's monotonic clock freezes
# during suspend, so the first input on wake unlocked the session without a
# password. The fix gates arming on the idle reason and measures the window on
# the wall clock, which a suspend does advance.
#
# This is a SOURCE suite: Lockscreen is a Singleton with a PAM context and a
# WlSessionLock and cannot be constructed headlessly, so the three grace
# functions are lifted out of the QML and evaluated against stubs - the same
# approach idle-wizard-test.sh uses for its flow literal. The stubs are the
# whole world those functions touch: Settings, a controllable Date.now(), and
# a root with the deadline field plus the two calls it makes.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "lockscreen-grace" "grace arms only for idle locks and a suspend consumes its window"

require_tools node

LOCKSCREEN="$SHELL_DIR/features/lock/Lockscreen.qml"
t_file "the grace logic lives in the lockscreen singleton" "$LOCKSCREEN"

# --- lift and evaluate the three grace functions ----------------------------

RESULTS="$(LOCKSCREEN="$LOCKSCREEN" node - <<'NODE'
const fs = require("fs")
const src = fs.readFileSync(process.env.LOCKSCREEN, "utf8")

// A function by name, balanced to its closing brace. Reading it from the
// source rather than restating it here means a change to the logic is what
// this suite measures.
function lift(name) {
  const m = new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{").exec(src)
  if (!m) throw new Error("no function " + name)
  let depth = 0
  let end = m.index + m[0].length - 1
  for (; end < src.length; end++) {
    const c = src[end]
    if (c === "{") depth++
    else if (c === "}") { depth--; if (depth === 0) { end++; break } }
  }
  return src.slice(m.index, end)
}

const code = ["_armGrace", "_endGrace", "graceActivity"].map(lift).join("\n")

let now = 1_000_000
const state = { release: 0 }
const root = {
  _graceDeadlineMs: 0,
  _endGrace() { root._graceDeadlineMs = 0 },
  finishRelease() { state.release++ }
}
const Settings = { lockscreenGraceSeconds: 5 }
const Clock = { now: () => now }

const fns = new Function("root", "Settings", "Date",
  code + "\nreturn { _armGrace, _endGrace, graceActivity }")(root, Settings, Clock)

const out = {}
const armed = () => root._graceDeadlineMs > 0

// Idle lock: arms, releases on the first input inside the window, then inert.
fns._armGrace("idle")
out.idleArmed = armed()
now += 1000
fns.graceActivity()
out.idleReleased = state.release
out.idleConsumed = root._graceDeadlineMs === 0
fns.graceActivity()
out.idleSecondRelease = state.release

// A suspend lock never arms grace, so wake input cannot ride it.
state.release = 0
fns._armGrace("suspend")
out.suspendArmed = armed()
fns.graceActivity()
out.suspendReleased = state.release

// An explicit lock is held on purpose; no grace either.
fns._armGrace("verb")
out.manualArmed = armed()
fns.graceActivity()
out.manualReleased = state.release

// A suspend after an idle lock advances the wall clock past the deadline:
// the first input on wake must not release, and the stale grace is consumed.
state.release = 0
now = 1_000_000
fns._armGrace("idle")
const beforeSleep = armed()
now += 3_600_000
fns.graceActivity()
out.sleepArmedBefore = beforeSleep
out.sleepReleased = state.release
out.sleepConsumed = root._graceDeadlineMs === 0

// A disabled setting arms nothing even for an idle lock.
state.release = 0
Settings.lockscreenGraceSeconds = 0
fns._armGrace("idle")
out.offArmed = armed()
fns.graceActivity()
out.offReleased = state.release

for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not evaluate the grace functions"; }

declare -A R
while IFS='=' read -r key value; do
  [[ -n $key ]] && R["$key"]="$value"
done <<<"$RESULTS"

t_section "an idle lock arms grace and releases once inside the window"
t_eq "an idle lock arms the grace window" "true" "${R[idleArmed]}"
t_eq "first input inside the window releases" "1" "${R[idleReleased]}"
t_eq "the release consumes the window" "true" "${R[idleConsumed]}"
t_eq "a second input cannot release again" "1" "${R[idleSecondRelease]}"

t_section "only idle locks arm grace"
t_eq "a suspend lock arms no window" "false" "${R[suspendArmed]}"
t_eq "wake input after a suspend lock does not release" "0" "${R[suspendReleased]}"
t_eq "an explicit lock arms no window" "false" "${R[manualArmed]}"
t_eq "input after an explicit lock does not release" "0" "${R[manualReleased]}"

t_section "a suspend consumes an already-armed idle grace"
t_eq "the idle window was armed before sleep" "true" "${R[sleepArmedBefore]}"
t_eq "wake input after sleep does not release" "0" "${R[sleepReleased]}"
t_eq "the stale window is consumed" "true" "${R[sleepConsumed]}"

t_section "a disabled grace setting arms nothing"
t_eq "an idle lock with grace off arms no window" "false" "${R[offArmed]}"
t_eq "input with grace off does not release" "0" "${R[offReleased]}"

t_note "The deadline is wall-clock, not a QML timer: monotonic timers freeze during suspend, so the old timer-based window survived sleep and the wake input unlocked the session. Date.now() advances across suspend, so a window armed before sleep is expired on wake."
