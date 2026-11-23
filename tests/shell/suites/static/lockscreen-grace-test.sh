#!/bin/bash
# Suite: lockscreen-grace - grace covers every fresh lock but suspend, on the wall clock.
#
# The grace window lets a fresh lock release on the first real input, so a user
# already back is not asked for a password - the setting promises activity after
# locking, whatever asked for the lock. The flaw this suite pins: a
# suspend-triggered lock could carry an armed window into sleep, and a QML
# timer's monotonic clock freezes during suspend, so the first input on wake
# unlocked the session without a password. Arming is refused for the suspend
# reason and the window is measured on the wall clock, which a suspend advances.
#
# This is a SOURCE suite: Lockscreen is a Singleton with a PAM context and a
# WlSessionLock and cannot be constructed headlessly, so the three grace
# functions are lifted out of the QML and evaluated against stubs - the same
# approach idle-wizard-test.sh uses for its flow literal. The stubs are the
# whole world those functions touch: Settings, a controllable Date.now(), and
# a root with the deadline field plus the two calls it makes.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "lockscreen-grace" "grace arms on every fresh lock but suspend, and a suspend consumes its window"

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

const code = ["_graceMayArm", "_armGrace", "_endGrace", "graceActivity"].map(lift).join("\n")

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
  code + "\nroot._graceMayArm = _graceMayArm\nreturn { _armGrace, _endGrace, graceActivity }")(root, Settings, Clock)

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

// A manual lock still arms grace: the setting promises activity after any
// lock, not only one the idle daemon asked for.
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

t_section "every fresh lock but suspend arms grace"
t_eq "a suspend lock arms no window" "false" "${R[suspendArmed]}"
t_eq "wake input after a suspend lock does not release" "0" "${R[suspendReleased]}"
t_eq "a manual lock arms the window" "true" "${R[manualArmed]}"
t_eq "input after a manual lock releases" "1" "${R[manualReleased]}"

t_section "a suspend consumes an already-armed idle grace"
t_eq "the idle window was armed before sleep" "true" "${R[sleepArmedBefore]}"
t_eq "wake input after sleep does not release" "0" "${R[sleepReleased]}"
t_eq "the stale window is consumed" "true" "${R[sleepConsumed]}"

t_section "a disabled grace setting arms nothing"
t_eq "an idle lock with grace off arms no window" "false" "${R[offArmed]}"
t_eq "input with grace off does not release" "0" "${R[offReleased]}"

t_note "The deadline is wall-clock, not a QML timer: monotonic timers freeze during suspend, so the old timer-based window survived sleep and the wake input unlocked the session. Date.now() advances across suspend, so a window armed before sleep is expired on wake."

# --- every pre-sleep lock uses the suspend reason ---------------------------
# Grace is keyed on the lock reason, so a lock taken just before logind sleeps
# must carry the same reason as one Session.suspend() takes. The lid-switch
# bind used the plain lockscreen verb, which armed grace: a wake inside the
# window released the session without a password. A dedicated sleep-lock verb
# gives both paths one authority that does not request the sleep itself.

BINDS="$VIBRANIUM_DIR/default/hypr/binds.lua"
SESSION="$SHELL_DIR/services/session/Session.qml"
t_file "the lid-switch bind lives in the hypr binds" "$BINDS"
t_file "the sleep-lock verb lives in the session service" "$SESSION"

LID_BIND="$(grep -F 'switch:on:Lid Switch' "$BINDS" || true)"
t_contains "the lid bind locks through the session service" \
  "vb-shell session lockForSleep" "$LID_BIND"
t_not_contains "the lid bind does not use the plain lock verb" \
  "vb-shell lockscreen lock" "$LID_BIND"

SLEEP_LOCK="$(SESSION="$SESSION" node - <<'NODE'
const fs = require("fs")
const src = fs.readFileSync(process.env.SESSION, "utf8")

// A function by name, balanced to its closing brace, read from the real
// source so a change to the verb is what this suite measures.
function lift(name) {
  const m = new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{").exec(src)
  if (!m) throw new Error("no function " + name + " in Session.qml")
  let depth = 0
  let end = m.index + m[0].length - 1
  for (; end < src.length; end++) {
    const c = src[end]
    if (c === "{") depth++
    else if (c === "}") { depth--; if (depth === 0) { end++; break } }
  }
  return src.slice(m.index, end)
}

const calls = []
const root = {
  _via(via) { return "via:" + via },
  lock(reason, via) { calls.push("lock:" + reason + ":" + via); return "ok" },
  lockForSleep(via) { calls.push("sleepLock:" + root._via(via)); return "ok" },
  _suspendViaSystemctl() { calls.push("systemctl"); return "ok" }
}
const Bus = { publish(topic, payload) { calls.push("publish:" + topic + ":" + String(payload.preparing)) } }
const sleepFn = new Function("root", "Bus", lift("lockForSleep") + "\nreturn lockForSleep")(root, Bus)
const suspendFn = new Function("root", lift("suspend") + "\nreturn suspend")(root)

const verdict = sleepFn("surface")
const sleepCalls = calls.join(",")
calls.length = 0
const suspendVerdict = suspendFn("surface")

process.stdout.write("verdict=" + verdict + "\n")
process.stdout.write("sleepCalls=" + sleepCalls + "\n")
process.stdout.write("suspendCalls=" + calls.join(",") + "\n")
process.stdout.write("suspendVerdict=" + suspendVerdict + "\n")
NODE
)" || { t_block "node could not evaluate the sleep-lock verb"; }

declare -A S
while IFS='=' read -r key value; do
  [[ -n $key ]] && S["$key"]="$value"
done <<<"$SLEEP_LOCK"

t_section "the pre-sleep lock carries the suspend reason"
t_eq "the sleep-lock verb reports the lock verdict" "ok" "${S[verdict]}"
t_eq "the sleep-lock verb closes the window and locks with suspend" \
  "publish:session.sleep:true,lock:suspend:via:surface" "${S[sleepCalls]}"
t_eq "suspend shares the sleep-lock verb rather than locking again" \
  "sleepLock:via:surface,systemctl" "${S[suspendCalls]}"
t_eq "suspend still reports the sleep handoff" "ok" "${S[suspendVerdict]}"

# --- a released lock can engage again --------------------------------------
# Quickshell 0.3.2's WlSessionLock never notifies `locked` on unlock, so a
# binding that reads it stays true after the first release. lock() and
# answerLockRequest() both early-return on that stale value: an idle lock
# after a grace unlock is refused, and the later suspend sleeps unlocked.
# `secure` notifies on unlock, so the lock state must read request + secure.

LOCKED_LINE="$(grep -F 'property bool locked:' "$LOCKSCREEN")"
t_contains "lock state follows the request and the compositor's secure state" \
  "requested || sessionLock.secure" "$LOCKED_LINE"
t_not_contains "lock state does not read the stale locked property" \
  "sessionLock.locked" "$LOCKED_LINE"

# --- a release re-arms the idle timers --------------------------------------
# A spent lock row stays spent until an activity edge. Input on a lock
# surface need not move the compositor's activity monitor, so without an
# explicit rearm on release the next idle period skips its lock and the
# suspend timer locks only at the last moment.

IDLE="$SHELL_DIR/services/session/IdleDaemon.qml"
t_file "the idle daemon owns the timer rearm" "$IDLE"

REARM="$(LOCKSCREEN="$LOCKSCREEN" IDLE="$IDLE" node - <<'NODE'
const fs = require("fs")
const lockSrc = fs.readFileSync(process.env.LOCKSCREEN, "utf8")
const idleSrc = fs.readFileSync(process.env.IDLE, "utf8")

function lift(src, name) {
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

const calls = []
const lockRoot = {
  requested: true,
  backdropPath: "wallpaper",
  _endGrace() { calls.push("endGrace") },
  resetAuth() { calls.push("resetAuth") }
}
const IdleDaemon = { rearmAfterRelease() { calls.push("rearm") } }
const finish = new Function("root", "IdleDaemon",
  lift(lockSrc, "finishRelease") + "\nreturn finishRelease")(lockRoot, IdleDaemon)
finish()

const idleRoot = {
  enabled: true,
  epoch: 5,
  fired: { 0: 5 },
  _onActivity() { calls.push("onActivity") },
  _setRows() { calls.push("setRows") }
}
const rearm = new Function("root",
  lift(idleSrc, "rearmAfterRelease") + "\nreturn rearmAfterRelease")(idleRoot)
const activity = new Function("root",
  lift(idleSrc, "_onActivity") + "\nreturn _onActivity")(idleRoot)
calls.length = 0
rearm()
const rearmCalls = calls.join(",")
calls.length = 0
activity()

const out = {}
out.releaseRearmsIdle = rearmCalls === "onActivity"
out.releaseDropsRequest = lockRoot.requested === false
out.epochBumped = idleRoot.epoch === 6
out.firedCleared = Object.keys(idleRoot.fired).length === 0
out.rowsRebuilt = calls.join(",") === "setRows"
for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not evaluate the release rearm"; }

declare -A RE
while IFS='=' read -r key value; do
  [[ -n $key ]] && RE["$key"]="$value"
done <<<"$REARM"

t_section "a lock release re-arms the idle timers"
t_eq "finishRelease asks the idle daemon to rearm" "true" "${RE[releaseRearmsIdle]}"
t_eq "finishRelease still drops the lock request" "true" "${RE[releaseDropsRequest]}"
t_eq "the rearm path bumps the epoch" "true" "${RE[epochBumped]}"
t_eq "the rearm path clears spent rows" "true" "${RE[firedCleared]}"
t_eq "the rearm path rebuilds the monitors" "true" "${RE[rowsRebuilt]}"

# --- LCK-5: a policy flip mid-tween must stop the tween and snap its driver ---
# appearAnim, fitAnim and progressAppearAnim each sample the animation gate once
# when they start. A global switch flipped off mid-reveal left the tween running
# to completion, so every derived reader kept moving after motion was off. The
# fix is a handler on the gate edge that stops the active tween and snaps its
# driver to the settled value.
#
# SOURCE suite: a WlSessionLockSurface and a NowPlaying with MPRIS/LyricsPane
# cannot be built headlessly, so lift the three gate handler bodies out of the
# real QML and evaluate them against stubs, as the grace block does above.

SURFACE="$SHELL_DIR/features/lock/LockscreenSurfaceView.qml"
NP="$SHELL_DIR/features/lock/NowPlaying.qml"
t_file "the lock surface source exists" "$SURFACE"
t_file "the lock now-playing source exists" "$NP"

GATE="$(SURFACE="$SURFACE" NP="$NP" node - <<'NODE'
const fs = require("fs")
const surface = fs.readFileSync(process.env.SURFACE, "utf8")
const nowPlaying = fs.readFileSync(process.env.NP, "utf8")

// Body of a handler, balanced to its closing brace, located by its signature
// in the real source. A change to the logic is what this suite measures.
function body(src, signature) {
  const at = src.indexOf(signature)
  // A missing handler is an empty body: every behavior assertion below then
  // fails on the current tree, which is the RED this finding pins.
  if (at < 0) return "\n"
  const open = src.indexOf("{", at + signature.length)
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(open + 1, i) }
  }
  throw new Error("unbalanced handler " + signature)
}

const appearBody = body(surface, "onAnimsChanged:")
const fitBody = body(surface, "function onAnimsChanged()")
const progressBody = body(nowPlaying, "function onEnabledChanged()")

// Drive one handler against stubs. When the gate is on it must be a no-op; when
// off it must stop its tween and snap its driver to the settled value.
function drive(bodyText, on) {
  const calls = []
  const panel = {}
  const surfaceStub = { anims: on }
  const backdropImage = {}
  const root = {}
  const stubs = {
    calls,
    anims: on,
    appearAnim: { stop: () => calls.push("appear") },
    fitAnim: { stop: () => calls.push("fit") },
    progressAppearAnim: { stop: () => calls.push("progress") },
    panel,
    surface: surfaceStub,
    backdropImage,
    root,
    MotionPolicy: { enabled: on },
  }
  const names = Object.keys(stubs)
  const fn = new Function(...names, bodyText)
  fn(...names.map(n => stubs[n]))
  // The gate-on branch returns early, so read the mutated stubs rather than a
  // return value injected into the body.
  return { calls, panel, surface: surfaceStub, backdropImage, root }
}

const out = {}
const appearOff = drive(appearBody, false)
out.appearStopped = appearOff.calls.includes("appear")
out.appearKSnapped = appearOff.panel.appearK === 1
out.appearFadeSnapped = appearOff.surface.appearFade === 1

const appearOn = drive(appearBody, true)
out.appearOnNoop = appearOn.calls.length === 0
  && appearOn.panel.appearK === undefined
  && appearOn.surface.appearFade === undefined

const fitOff = drive(fitBody, false)
out.fitStopped = fitOff.calls.includes("fit")
out.fitScaleSnapped = fitOff.backdropImage.scale === 1

const fitOn = drive(fitBody, true)
out.fitOnNoop = fitOn.calls.length === 0 && fitOn.backdropImage.scale === undefined

const progressOff = drive(progressBody, false)
out.progressStopped = progressOff.calls.includes("progress")
out.progressSnapped = progressOff.root.progressAppear === 1

const progressOn = drive(progressBody, true)
out.progressOnNoop = progressOn.calls.length === 0
  && progressOn.root.progressAppear === undefined

for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not evaluate the animation gate handlers"; }

declare -A G
while IFS='=' read -r key value; do
  [[ -n $key ]] && G["$key"]="$value"
done <<<"$GATE"

t_section "the entry fade handler snaps both drivers when motion flips off"
t_eq "the gate edge stops appearAnim" "true" "${G[appearStopped]}"
t_eq "the gate edge snaps panel.appearK to 1" "true" "${G[appearKSnapped]}"
t_eq "the gate edge snaps surface.appearFade to 1" "true" "${G[appearFadeSnapped]}"
t_eq "the gate edge does nothing when motion stays on" "true" "${G[appearOnNoop]}"

t_section "the backdrop fit handler snaps its scale when motion flips off"
t_eq "the gate edge stops fitAnim" "true" "${G[fitStopped]}"
t_eq "the gate edge snaps backdropImage.scale to 1" "true" "${G[fitScaleSnapped]}"
t_eq "the fit gate does nothing when motion stays on" "true" "${G[fitOnNoop]}"

t_section "the progress handler snaps its driver when motion flips off"
t_eq "the gate edge stops progressAppearAnim" "true" "${G[progressStopped]}"
t_eq "the gate edge snaps root.progressAppear to 1" "true" "${G[progressSnapped]}"
t_eq "the progress gate does nothing when motion stays on" "true" "${G[progressOnNoop]}"

# --- LCK-6/LCK-9: one owner per reveal countdown -----------------------------
# LCK-6: the autohide timer's self-restart on `authenticating` duplicates the
# auth edge that re-arms it on exit. The timer must not read auth at all; the
# edge stops the countdown on entry and grabFocus() re-arms it on exit.
# LCK-9: the progress reveal must not also be reset on the visible edge;
# `hasTrack` owns that reset, and `visible` only re-anchors the position.
#
# Both handlers are lifted from the real QML and driven against stubs, as the
# gate handlers above are. A handler that still owns the duplicate shows up as
# an extra `restart` in the call log.

OWNER="$(SURFACE="$SURFACE" NP="$NP" node - <<'NODE'
const fs = require("fs")
const surface = fs.readFileSync(process.env.SURFACE, "utf8")
const nowPlaying = fs.readFileSync(process.env.NP, "utf8")

function body(src, signature) {
  const at = src.indexOf(signature)
  if (at < 0) return "\n"
  const open = src.indexOf("{", at + signature.length)
  let depth = 0
  for (let i = open; i < src.length; i++) {
    if (src[i] === "{") depth++
    else if (src[i] === "}") { depth--; if (depth === 0) return src.slice(open + 1, i) }
  }
  throw new Error("unbalanced handler " + signature)
}

const triggerBody = body(surface, "onTriggered:")
const authBody = body(surface, "function onAuthenticatingChanged()")
const visibleBody = body(nowPlaying, "onVisibleChanged:")
const hasTrackBody = body(nowPlaying, "onHasTrackChanged:")

function drive(bodyText, makeStubs) {
  const calls = []
  const all = Object.assign({ calls }, makeStubs(calls))
  const names = Object.keys(all)
  new Function(...names, bodyText)(...names.map(n => all[n]))
  return calls
}

// The auth edge and the timer fire at different times, so they are driven
// separately: an auth-start stop means the timer cannot fire during the turn.
function autohideStubs(calls, authenticating) {
  return {
    surface: {
      autohideEnabled: true, visible: true,
      setIdleFade: v => calls.push("fade:" + v),
      grabFocus: () => calls.push("grabFocus")
    },
    autohideTimer: {
      restart: () => calls.push("restart"),
      stop: () => calls.push("stop")
    },
    Lockscreen: { authenticating, requested: true }
  }
}

function reveal(bodyText, visible, hasTrack) {
  const root = { visible, hasTrack, progressAppear: 7 }
  const calls = drive(bodyText, c => {
    root.reanchor = () => c.push("reanchor")
    return {
      root,
      progressAppearAnim: {
        restart: () => c.push("restart"),
        stop: () => c.push("stop")
      }
    }
  })
  return { calls, root }
}

const out = {}
// The timer body must not rearm on auth; the edge must stop on entry and
// grab focus on exit.
const fireAuth = drive(triggerBody, c => autohideStubs(c, true))
out.timerNoSelfRearm = !fireAuth.includes("restart")
const authStart = drive(authBody, c => autohideStubs(c, true))
out.authStopsCountdown = authStart.includes("stop")
out.authKeepsField = !authStart.includes("fade:true")
const authEnd = drive(authBody, c => autohideStubs(c, false))
out.authEndGrabsFocus = authEnd.includes("grabFocus")
const fireIdle = drive(triggerBody, c => autohideStubs(c, false))
out.idleTimerFades = fireIdle.includes("fade:true")
out.idleTimerNoRearm = !fireIdle.includes("restart")

// LCK-9: visible only reanchors; hasTrack owns the reset in both directions.
const shown = reveal(visibleBody, true, true)
out.visibleOnlyReanchors = shown.calls.length === 1 && shown.calls[0] === "reanchor"
out.visibleKeepsDriver = shown.root.progressAppear === 7
const trackOn = reveal(hasTrackBody, true, true)
out.trackRestartsReveal = trackOn.calls.includes("restart")
  && trackOn.root.progressAppear === 0
const trackOff = reveal(hasTrackBody, true, false)
out.trackStopsReveal = trackOff.calls.includes("stop")
  && trackOff.root.progressAppear === 0

for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not evaluate the reveal-owner handlers"; }

declare -A O
while IFS='=' read -r key value; do
  [[ -n $key ]] && O["$key"]="$value"
done <<<"$OWNER"

t_section "LCK-6: the auth edge, not the timer, owns the autohide countdown"
t_eq "the timer does not restart itself on auth" "true" "${O[timerNoSelfRearm]}"
t_eq "the auth edge stops the countdown on entry" "true" "${O[authStopsCountdown]}"
t_eq "auth entry leaves the field revealed" "true" "${O[authKeepsField]}"
t_eq "the auth edge reclaims focus on exit" "true" "${O[authEndGrabsFocus]}"
t_eq "the idle timer still fades the field" "true" "${O[idleTimerFades]}"
t_eq "the idle timer never restarts itself" "true" "${O[idleTimerNoRearm]}"

t_section "LCK-9: the has-track edge alone resets the progress reveal"
t_eq "the visible edge only reanchors" "true" "${O[visibleOnlyReanchors]}"
t_eq "the visible edge leaves the reveal driver alone" "true" "${O[visibleKeepsDriver]}"
t_eq "a new track restarts the reveal" "true" "${O[trackRestartsReveal]}"
t_eq "losing the track stops the reveal" "true" "${O[trackStopsReveal]}"

t_summary
