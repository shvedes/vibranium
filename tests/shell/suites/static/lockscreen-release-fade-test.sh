#!/bin/bash
# Suite: lockscreen-release-fade - the exit fade owns the session lock teardown.
#
# Unlocking used to drop `requested` in the same frame PAM succeeded, so the
# compositor unmapped every lock surface before a fade could draw. The release
# now arms a shared driver and only the animation's finished edge calls
# finishRelease(). This suite lifts the two functions and drives them against
# stubs - Lockscreen owns a WlSessionLock and a PAM context and cannot be built
# headlessly. It also checks that every visual layer in the surface reads the
# driver, so no layer can pop away while the rest fade.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "lockscreen-release-fade" "the exit fade releases the lock, and every surface layer follows it"

require_tools node

LOCK="$SHELL_DIR/features/lock/Lockscreen.qml"
SURFACE="$SHELL_DIR/features/lock/LockscreenSurfaceView.qml"
for f in "$LOCK" "$SURFACE"; do
  t_file "the lock release source exists: ${f##*/}" "$f"
done

RESULTS="$(LOCK="$LOCK" SURFACE="$SURFACE" node - <<'NODE'
const fs = require("fs")
const lockSrc = fs.readFileSync(process.env.LOCK, "utf8")
const surfaceSrc = fs.readFileSync(process.env.SURFACE, "utf8")

function lift(name) {
  const m = new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{").exec(lockSrc)
  if (!m) throw new Error("no function " + name)
  let depth = 0
  let end = m.index + m[0].length - 1
  for (; end < lockSrc.length; end++) {
    const c = lockSrc[end]
    if (c === "{") depth++
    else if (c === "}") { depth--; if (depth === 0) { end++; break } }
  }
  return lockSrc.slice(m.index, end)
}

function machine(motion) {
  const calls = []
  const root = {
    requested: true,
    releasing: false,
    releaseFade: 1,
    backdropPath: "wallpaper",
    authenticating: true,
    submitted: "dots",
    failedAttempts: 0,
    password: "dots",
    _graceDeadlineMs: 0,
    _endGrace() { root._graceDeadlineMs = 0; calls.push("endGrace") },
    resetAuth() { calls.push("resetAuth") }
  }
  const MotionPolicy = { enabled: motion }
  const releaseAnim = {
    restart() { calls.push("restart") },
    stop() { calls.push("stop") }
  }
  const IdleDaemon = { rearmAfterRelease() { calls.push("rearm") } }
  const Settings = { lockscreenGraceSeconds: 5 }
  const fns = new Function("root", "MotionPolicy", "releaseAnim", "IdleDaemon", "Settings", [
    lift("beginRelease"), lift("finishRelease"), lift("graceActivity"), lift("finishAuth")
  ].join("\n") + "\nreturn { beginRelease, finishRelease, graceActivity, finishAuth }")(
    root, MotionPolicy, releaseAnim, IdleDaemon, Settings)
  root.beginRelease = fns.beginRelease
  root.finishRelease = fns.finishRelease
  return { root, calls, fns }
}

const out = {}

// Motion on: the session stays locked while the driver runs to zero. A second
// unlock edge cannot start a competing fade, and input cannot ride a grace
// window that beginRelease consumed.
{
  const s = machine(true)
  s.root._graceDeadlineMs = 1234
  s.fns.beginRelease()
  out.motionReleasing = s.root.releasing === true
  out.motionStillLocked = s.root.requested === true
  out.motionFadeStarted = s.calls.filter(c => c === "restart").length === 1
  out.motionGraceConsumed = s.root._graceDeadlineMs === 0
  s.fns.beginRelease()
  out.motionReentrant = s.calls.filter(c => c === "restart").length === 1
  s.root._graceDeadlineMs = 5000
  s.fns.graceActivity()
  out.motionGraceInert = s.root.requested === true && s.root._graceDeadlineMs === 5000
  s.root.releaseFade = 0
  s.fns.finishRelease()
  out.motionReleased = s.root.requested === false && s.root.releasing === false
  out.motionRearmed = s.calls.filter(c => c === "rearm").length === 1
}

// Motion off: no animation, so teardown happens in the same call.
{
  const s = machine(false)
  s.fns.beginRelease()
  out.snapReleased = s.root.requested === false && s.root.releasing === false
  out.snapNoAnimation = !s.calls.includes("restart")
}

// A grace release enters the fade instead of dropping the request.
{
  const s = machine(true)
  s.root._graceDeadlineMs = Date.now() + 5000
  s.fns.graceActivity()
  out.graceStartsFade = s.root.releasing === true && s.root.requested === true
}

// PAM success takes the same path as grace input; a rejection takes neither.
{
  const s = machine(true)
  s.fns.finishAuth(true)
  out.pamStartsFade = s.root.releasing === true && s.root.requested === true
}
{
  const s = machine(true)
  s.fns.finishAuth(false)
  out.pamRejectionKeepsLock = s.root.releasing === false && s.root.requested === true
}

// Every layer that paints over the surface must follow the shared driver:
// backdrop, vignette, clock, card, pill, hint and the field's own enabled gate.
out.backdropFades = /opacity:\s*Lockscreen\.releaseFade/.test(surfaceSrc)
out.vignetteFades = /progress:\s*surface\.appearFade \* Lockscreen\.releaseFade/.test(surfaceSrc)
out.clockFades = /opacity:\s*panel\.appearK \* surface\.clockIdleK \* Lockscreen\.releaseFade/.test(surfaceSrc)
out.cardFades = /opacity:\s*appearK \* surface\.autohideK \* Lockscreen\.releaseFade/.test(surfaceSrc)
out.pillFades = /opacity:\s*panel\.appearK \* Lockscreen\.releaseFade/.test(surfaceSrc)
out.fieldGated = /enabled:\s*!Lockscreen\.authenticating && !Lockscreen\.releasing/.test(surfaceSrc)

for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not evaluate the release functions"; }

declare -A R
while IFS='=' read -r key value; do
  [[ -n $key ]] && R["$key"]="$value"
done <<<"$RESULTS"

t_section "the fade keeps the session locked until its last frame"
t_eq "beginRelease marks the release in flight" "true" "${R[motionReleasing]}"
t_eq "the lock request survives the fade" "true" "${R[motionStillLocked]}"
t_eq "the fade animation starts once" "true" "${R[motionFadeStarted]}"
t_eq "a second unlock edge does not restart it" "true" "${R[motionReentrant]}"
t_eq "grace is consumed at the release edge" "true" "${R[motionGraceConsumed]}"
t_eq "input during the fade cannot extend grace" "true" "${R[motionGraceInert]}"
t_eq "finishRelease drops the request" "true" "${R[motionReleased]}"
t_eq "the idle daemon is rearmed once" "true" "${R[motionRearmed]}"

t_section "motion off skips the fade"
t_eq "the release still drops the request" "true" "${R[snapReleased]}"
t_eq "no animation is started" "true" "${R[snapNoAnimation]}"

t_section "both unlock triggers enter one path"
t_eq "a grace release arms the fade, not teardown" "true" "${R[graceStartsFade]}"
t_eq "PAM success takes the same fade" "true" "${R[pamStartsFade]}"
t_eq "a rejected password keeps the session locked" "true" "${R[pamRejectionKeepsLock]}"

t_section "every surface layer follows the driver"
t_eq "the backdrop fades" "true" "${R[backdropFades]}"
t_eq "the vignette fades" "true" "${R[vignetteFades]}"
t_eq "the clock fades" "true" "${R[clockFades]}"
t_eq "the card fades" "true" "${R[cardFades]}"
t_eq "the pill and hint fade" "true" "${R[pillFades]}"
t_eq "the field stops taking input during the fade" "true" "${R[fieldGated]}"
