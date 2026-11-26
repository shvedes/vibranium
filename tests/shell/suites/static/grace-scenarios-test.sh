#!/bin/bash
# Suite: grace-scenarios - the whole grace lifecycle against its real interactions.
#
# Grace is an authentication bypass, so the scenarios here cover the paths
# that can invalidated it: a fresh lock, a lock already holding a window, a
# sleep shorter and longer than the window, a sleep requested through the
# session verb, a logind signal, a settings flip while locked, and the idle
# rearm on release. The logic is lifted from the real sources and driven
# against stubs - Lockscreen owns a WlSessionLock and a PAM context, so it
# cannot be constructed headlessly.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "grace-scenarios" "grace across lock, sleep, settings and idle rearm"

require_tools node

LOCK="$SHELL_DIR/features/lock/Lockscreen.qml"
SESSION="$SHELL_DIR/services/session/Session.qml"
INHIBITOR="$SHELL_DIR/services/power/Inhibitor.qml"
LOGIN1="$SHELL_DIR/services/power/Login1Sleep.js"
IDLE="$SHELL_DIR/services/session/IdleDaemon.qml"
for f in "$LOCK" "$SESSION" "$INHIBITOR" "$LOGIN1" "$IDLE"; do
  t_file "the grace scenario source exists: ${f##*/}" "$f"
done

SCENARIOS="$(LOCK="$LOCK" SESSION="$SESSION" INHIBITOR="$INHIBITOR" LOGIN1="$LOGIN1" node - <<'NODE'
const fs = require("fs")
const src = {
  lock: fs.readFileSync(process.env.LOCK, "utf8"),
  session: fs.readFileSync(process.env.SESSION, "utf8"),
  inhibitor: fs.readFileSync(process.env.INHIBITOR, "utf8"),
  login1: fs.readFileSync(process.env.LOGIN1, "utf8")
}

function lift(source, name) {
  const m = new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{").exec(source)
  if (!m) throw new Error("no function " + name)
  let depth = 0
  let end = m.index + m[0].length - 1
  for (; end < source.length; end++) {
    const c = source[end]
    if (c === "{") depth++
    else if (c === "}") { depth--; if (depth === 0) { end++; break } }
  }
  return source.slice(m.index, end)
}

function body(source, signature) {
  const at = source.indexOf(signature)
  if (at < 0) throw new Error("no handler " + signature)
  const open = source.indexOf("{", at + signature.length)
  let depth = 0
  for (let i = open; i < source.length; i++) {
    if (source[i] === "{") depth++
    else if (source[i] === "}") { depth--; if (depth === 0) return source.slice(open + 1, i) }
  }
  throw new Error("unbalanced handler " + signature)
}

// The login1 line parser is a plain library once its QML pragma is dropped.
const parseSleep = new Function(
  src.login1.replace(/^\.pragma library\s*/, "") + "\nreturn preparingFromLine")()

let now = 1_000_000
const Clock = { now: () => now }
const Settings = { lockscreenGraceSeconds: 5 }
let releases = 0
let rearms = 0
const root = {
  _graceDeadlineMs: 0,
  requested: true,
  backdropPath: "",
  _sleepState: null,
  _endGrace() { root._graceDeadlineMs = 0 },
  resetAuth() {}
}
const IdleDaemon = { rearmAfterRelease() { rearms++ } }
const fns = new Function("root", "Settings", "Date", "IdleDaemon", [
  lift(src.lock, "_graceMayArm"),
  lift(src.lock, "_armGrace"),
  lift(src.lock, "_endGrace"),
  lift(src.lock, "graceActivity"),
  lift(src.lock, "finishRelease")
].join("\n") + "\nroot._graceMayArm = _graceMayArm\nroot._finishRelease = finishRelease\nreturn { _armGrace, graceActivity }")(root, Settings, Clock, IdleDaemon)
root.beginRelease = function () { releases++; root._finishRelease() }
const onSleep = new Function("root", "return function () {" + body(src.lock, "on_SleepStateChanged:") + "}")(root)

function reset() {
  root._graceDeadlineMs = 0
  root.requested = true
  root._sleepState = null
  releases = 0
  rearms = 0
  Settings.lockscreenGraceSeconds = 5
  now = 1_000_000
}

const out = {}

// A fresh idle or manual lock arms, and the first real input releases.
reset()
fns._armGrace("idle")
out.idleArmed = root._graceDeadlineMs > 0
now += 1000
fns.graceActivity()
out.idleReleased = releases
out.releaseRearmsIdle = rearms === 1

reset()
fns._armGrace("verb")
fns.graceActivity()
out.manualReleased = releases

// A sleep lock, and a session-end lock, never arm.
reset()
fns._armGrace("suspend")
out.sleepLockArmed = root._graceDeadlineMs > 0
fns.graceActivity()
out.sleepLockReleased = releases

reset()
fns._armGrace("logout")
out.logoutArmed = root._graceDeadlineMs > 0

// The session verb publishes the boundary and locks with the suspend reason.
reset()
fns._armGrace("idle")
const sessionCalls = []
const sessionRoot = {
  _via(via) { return "via:" + via },
  lock(reason, via) { sessionCalls.push("lock:" + reason + ":" + via); return "ok" }
}
const sessionBus = { publish(topic, payload) { sessionCalls.push("publish:" + topic + ":" + String(payload.preparing)) } }
const lockForSleep = new Function("root", "Bus",
  lift(src.session, "lockForSleep") + "\nreturn lockForSleep")(sessionRoot, sessionBus)
lockForSleep("surface")
out.sleepRequestPath = sessionCalls.join(",")
root._sleepState = { preparing: true }
onSleep()
out.heldGraceDisarmed = root._graceDeadlineMs === 0
fns.graceActivity()
out.wakeAfterSleepReleased = releases

// A logind signal closes a window even when the sleep is shorter than it.
reset()
fns._armGrace("idle")
const sleepLine = "/org/freedesktop/login1: org.freedesktop.login1.Manager PrepareForSleep (true,)"
const wakeLine = "/org/freedesktop/login1: org.freedesktop.login1.Manager PrepareForSleep (false,)"
out.parserTrue = parseSleep(sleepLine) === true
out.parserFalse = parseSleep(wakeLine) === false
out.parserIgnoresOtherSignal = parseSleep(
  "/org/freedesktop/login1: org.freedesktop.DBus.Properties.PropertiesChanged ('x', {}, @as [])") === null
out.parserIgnoresForeignPath = parseSleep("/org/other: org.freedesktop.login1.Manager PrepareForSleep (true,)") === null
root._sleepState = { preparing: parseSleep(sleepLine) }
onSleep()
now += 1000
fns.graceActivity()
out.shortSleepReleased = releases

// The monitor publishes the parsed boundary and nothing else.
const monitorCalls = []
const monitor = body(src.inhibitor, "onLine: data =>")
const monitorStubs = {
  data: sleepLine,
  _monitorStream: { noteAlive() { monitorCalls.push("alive") } },
  Login1Sleep: { preparingFromLine: parseSleep },
  Bus: { publish(topic, payload) { monitorCalls.push("publish:" + topic + ":" + String(payload.preparing)) } },
  _coalesceTimer: { restart() { monitorCalls.push("coalesce") } }
}
new Function("data", "_monitorStream", "Login1Sleep", "Bus", "_coalesceTimer", monitor)(
  monitorStubs.data, monitorStubs._monitorStream, monitorStubs.Login1Sleep,
  monitorStubs.Bus, monitorStubs._coalesceTimer)
out.monitorPath = monitorCalls.join(",")

// A long sleep is still blockable by the wall clock alone.
reset()
fns._armGrace("idle")
now += 6000
fns.graceActivity()
out.longSleepReleased = releases

// Turning grace off while a window is armed consumes it.
reset()
fns._armGrace("idle")
Settings.lockscreenGraceSeconds = 0
fns.graceActivity()
out.settingOffReleased = releases

for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not run the grace scenarios"; }

declare -A C
while IFS='=' read -r key value; do
  [[ -n $key ]] && C["$key"]="$value"
done <<<"$SCENARIOS"

t_section "a fresh lock arms grace and the first input releases"
t_eq "an idle lock arms the window" "true" "${C[idleArmed]}"
t_eq "first input releases the session" "1" "${C[idleReleased]}"
t_eq "the release re-arms the idle timers" "true" "${C[releaseRearmsIdle]}"
t_eq "a manual lock releases on input" "1" "${C[manualReleased]}"

t_section "sleep and session-end locks never arm grace"
t_eq "a suspend lock arms no window" "false" "${C[sleepLockArmed]}"
t_eq "wake input after a suspend lock does not release" "0" "${C[sleepLockReleased]}"
t_eq "a logout lock arms no window" "false" "${C[logoutArmed]}"

t_section "a sleep request closes a window the lock already holds"
t_eq "the session verb publishes the boundary before locking" \
  "publish:session.sleep:true,lock:suspend:via:surface" "${C[sleepRequestPath]}"
t_eq "the held window is disarmed" "true" "${C[heldGraceDisarmed]}"
t_eq "wake input after that sleep does not release" "0" "${C[wakeAfterSleepReleased]}"

t_section "logind's sleep signal closes a window even on a short sleep"
t_eq "PrepareForSleep(true) parses" "true" "${C[parserTrue]}"
t_eq "PrepareForSleep(false) parses as false" "true" "${C[parserFalse]}"
t_eq "an unrelated login1 signal is ignored" "true" "${C[parserIgnoresOtherSignal]}"
t_eq "a foreign path is ignored" "true" "${C[parserIgnoresForeignPath]}"
t_eq "input after a short sleep does not release" "0" "${C[shortSleepReleased]}"
t_eq "the monitor publishes the authoritative boundary and coalesces once" \
  "alive,publish:session.sleep:true,coalesce" "${C[monitorPath]}"

t_section "the wall clock and the setting still bound the window"
t_eq "a sleep longer than the window does not release" "0" "${C[longSleepReleased]}"
t_eq "disabling grace mid-window does not release" "0" "${C[settingOffReleased]}"

t_summary
