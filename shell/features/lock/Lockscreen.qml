pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Mpris
import Quickshell.Services.Pam
import qs.common
import qs.services
import qs.features.osd
import qs.features.wallpaper

// Session lock. A lock request engages synchronously - no stabilization
// timers - while auth state lives here so every screen's surface stays in
// sync. The lock is cleared either by a PAM completion reporting Success or
// by input inside the optional grace window; no unlock verb is published and
// the neutral request contract can only engage one. Backdrop frames come from
// ScreencopyView inside the surface; a throwaway view below warms the capture
// backend at boot because compositors refuse the first request made from an
// already-locked session.
// Keyboard state (caps, layout) lives in the shared Keyboard singleton.
// An optional grace window (Settings.lockscreenGraceSeconds) releases a fresh
// lock on the first real input inside that window, so a user already back is
// not asked for a password. A sleep boundary closes the window whether the
// lock was fresh or already held: the wall clock alone would let a short sleep
// fit inside the window. Locks that belong to a sleep never arm grace at all,
// so a failed sleep still leaves the session held.
Singleton {
  id: root

  readonly property string tag: "lockscreen"

  property bool requested: false
  // The session lock stays engaged while these surfaces fade their content
  // out. One driver in the owner (not one per surface) means every screen
  // reaches zero together and teardown waits on a single animation edge.
  // releaseAnim owns releaseFade while a fade runs; lock() only arms it for
  // the next session. The two writes cannot overlap because lock() refuses
  // to engage while `locked` still holds.
  property bool releasing: false
  property real releaseFade: 1

  // WlSessionLock in Quickshell 0.3.2 never emits lockStateChanged on unlock,
  // so a binding reading `locked` keeps its last true value after the first
  // release and every later lock request is refused as already_locked. The
  // compositor's `secure` does notify on unlock and reads false there, so
  // requested || secure clears on release and a later lock can engage again.
  readonly property bool locked: requested || sessionLock.secure

  property bool authenticating: false
  property int failedAttempts: 0

  // Canonical field text shared by all screens; surfaces mirror it.
  property string password: ""
  property string submitted: ""

  // Wallpaper path snapshot for the running lock session. Taken when lock()
  // begins so a wallpaper swap mid-authentication cannot replace the
  // security backdrop; cleared again on release.
  property string backdropPath: ""

  // DBus names of players paused on lock; restored on unlock. A bus name
  // carries an instance suffix, so the list is held and never shown.
  property var _pausedDbusNames: []

  function _pauseMusic() {
    if (!Settings.lockscreenPauseMusic) return
    const players = Mpris.players ? (Mpris.players.values ?? []) : []
    const toPause = []
    for (let i = 0; i < players.length; i++) {
      const p = players[i]
      if (!p) continue
      if (p.playbackState === MprisPlaybackState.Playing && p.canPause) toPause.push(p)
    }
    if (toPause.length === 0) return
    const names = []
    for (let i = 0; i < toPause.length; i++) {
      const p = toPause[i]
      if (p.dbusName) names.push(p.dbusName)
      p.pause()
    }
    root._pausedDbusNames = names
  }

  function _resumeMusic() {
    if (root._pausedDbusNames.length === 0) return
    const names = root._pausedDbusNames
    root._pausedDbusNames = []
    const players = Mpris.players ? (Mpris.players.values ?? []) : []
    for (let n = 0; n < names.length; n++) {
      const dbus = names[n]
      let p = null
      for (let i = 0; i < players.length; i++) {
        if (players[i] && players[i].dbusName === dbus) {
          p = players[i]
          break
        }
      }
      // A client that quit while the session sat locked has nothing to resume.
      if (!p) continue
      if (p.canPlay && p.playbackState !== MprisPlaybackState.Playing) p.play()
    }
  }

  // `from` names the caller that engaged the lock, and `requestReason` the
  // neutral contract's own reason for the request. The IPC verb and the
  // request contract are the only two callers.
  function lock(from, requestReason) {
    if (root.locked) return
    root.resetAuth("new-lock")
    // A finished release left the fade driver at zero; arm it for this session
    // before any surface can bind to it. `releasing` is already false here:
    // finishRelease() clears it, and a new lock cannot engage while held.
    root.releaseFade = 1
    // Freeze the backdrop source for this session up front: background mode
    // pins the wallpaper path here so a swap while locked cannot replace the
    // security backdrop the user is authenticating against. A disabled
    // wallpaper pins nothing, so the surface stays on the theme color.
    root.backdropPath = (Settings.lockscreenBackgroundMode === "background" && Settings.wallpaperEnabled) ? Wallpaper.current : ""
    Keyboard.sync()
    root.requested = true
    root._pauseMusic()
    root._armGrace(requestReason)
  }

  // Wall-clock deadline for the armed grace window, 0 when unarmed. A suspend
  // advances this clock but freezes a QML timer, so the deadline bounds a
  // window that no sleep has interrupted.
  property double _graceDeadlineMs: 0

  // The sleep boundary is authoritative for grace. A reason gate only covers
  // a fresh lock: one already held keeps the window it armed, and a sleep
  // shorter than that window would not advance the wall clock past it.
  readonly property var _sleepState: Bus.latest("session.sleep")

  on_SleepStateChanged: {
    if (root._sleepState && root._sleepState.preparing === true) root._endGrace()
  }

  // A lock that belongs to a sleep or a session end never releases on input.
  // The gate is deliberately narrow: a caller with a new reason must opt in.
  function _graceMayArm(reason) {
    return reason !== "suspend" && reason !== "sleep"
      && reason !== "logout" && reason !== "reboot" && reason !== "poweroff"
  }

  function _armGrace(reason) {
    root._endGrace()
    if (!root._graceMayArm(reason)) return
    if (Settings.lockscreenGraceSeconds <= 0) return
    root._graceDeadlineMs = Date.now() + Settings.lockscreenGraceSeconds * 1000
  }

  function _endGrace() {
    root._graceDeadlineMs = 0
  }

  // Called by every lock surface on real mouse or keyboard input. Only the
  // first input inside the armed window releases; once the wall-clock window
  // is past this is inert, so grace can never bypass a password after a
  // suspend even while a monotonic countdown would still have time left.
  // True means this input unlocked through grace, so a keyboard surface can
  // swallow the keystroke instead of letting it land in the password field.
  function graceActivity() {
    if (root.releasing) return false
    if (root._graceDeadlineMs === 0) return false
    const armed = root._graceDeadlineMs
    root._endGrace()
    // Turning the setting off while a window is armed consumes it, and a
    // deadline in the past means the window elapsed - no password bypass.
    if (Settings.lockscreenGraceSeconds <= 0) return false
    if (Date.now() >= armed) return false
    root.beginRelease()
    return true
  }

  // Stable identity for the neutral request contract: adopt() and release()
  // compare the handler, so a closure built at each call site could never be
  // released.
  readonly property var lockRequestHandler: request => root.answerLockRequest(request)

  // The surface answer: a request can engage the lock and nothing else, and a
  // lock already held needs no second engage.
  function answerLockRequest(request) {
    if (root.locked) return "already_locked"
    root.lock("request", request ? request.reason : undefined)
    const engaged = root.requested
    SessionActions.reportLock(request.id, engaged ? "locked" : "refused")
    return engaged
  }

  onRequestedChanged: {
    // Every release routes through finishRelease(), after the exit fade has
    // drawn its last frame, so this is the single resume point. Pause is
    // handled in lock() to keep the lock request synchronous; resume runs
    // when requested flips false.
    if (!root.requested) {
      root._resumeMusic()
    }
  }

  // While any lock flavor holds, the desktop OSD surface stays
  // unmapped so an unlock never greets a stale flash; the lock
  // mirror (or nothing, when its pill is on) covers feedback.
  function _publishState() {
    Bus.publish("lockscreen.state", { locked: root.locked })
  }

  onLockedChanged: {
    // The far end of the transition lock() opened. `requested` is the only
    // input that can move `locked` back down; finishRelease is its only
    // writer, reached from the release fade's finished edge after both PAM
    // success and grace input enter beginRelease, so never from here.
    OSD.desktopSuppressed = root.locked
    root._publishState()
  }

  Component.onCompleted: {
    root._publishState()
    SessionActions.adopt(root.lockRequestHandler)
    Registry.register("lockscreen", root)
  }

  // PamContext documents no destruction cleanup, so an exchange still active
  // when this owner is torn down is aborted here; the guard keeps a context
  // that holds no session from being aborted.
  Component.onDestruction: {
    Registry.unregister("lockscreen")
    SessionActions.release(root.lockRequestHandler)
    if (pam.active) pam.abort()
  }

  // `reason` names why the auth state is being thrown away, which is the only
  // thing that tells a discarded exchange from a settled one: both call
  // pam.abort() and both clear the field.
  function resetAuth(reason) {
    const wasActive = pam.active
    root.authenticating = false
    root.failedAttempts = 0
    root.password = ""
    root.submitted = ""
    if (wasActive) pam.abort()
  }

  // --- typed gateway --------------------------------------------------------

  function _ok(data, format) {
    const frame = { v: 1, ok: true }
    if (data !== undefined) frame.data = data
    if (format) frame.format = format
    return frame
  }
  function _record() { return { kind: "record" } }

  function _ipcLock() {
    root.lock("verb")
    // Distinguish the request from the compositor's actual hold.
    return _ok({ requested: root.requested, secure: sessionLock.secure }, _record())
  }

  function _ipcIsLocked() {
    return _ok(root.requested || sessionLock.secure, { kind: "bool" })
  }

  function _ipcStatus() {
    return _ok({
      locked: root.locked,
      requested: root.requested,
      secure: sessionLock.secure,
      releasing: root.releasing,
      authenticating: root.authenticating,
      failedAttempts: root.failedAttempts,
      capsLock: Keyboard.capsOn,
      layout: Keyboard.layout,
      animations: MotionPolicy.enabled,
      backgroundMode: Settings.lockscreenBackgroundMode,
      vignette: Settings.lockscreenVignette,
      blurBackground: Settings.blurBackground,
      dim: Settings.lockscreenDim,
      nowPlaying: Settings.lockscreenNowPlaying,
      blurPower: Settings.lockscreenBlurPower,
      pauseMusic: Settings.lockscreenPauseMusic,
      grace: Settings.lockscreenGraceSeconds,
      graceArmed: root._graceDeadlineMs > 0 && Date.now() < root._graceDeadlineMs
    }, _record())
  }

  // Field text flows input -> here -> sibling inputs; guards break the loop.
  // The only function in the component that receives what the user typed, so
  // it stores the value and returns.
  function setPassword(text) {
    if (root.password === text) return
    root.password = text
  }

  // Auth is single-flight without an exchange counter: `authenticating` is the
  // one seat (set in tryUnlock, cleared only in finishAuth/resetAuth) and
  // `submitted` is one-shot (cleared immediately before pam.respond), so a
  // submitted password is consumed once per attempt and a second tryUnlock is
  // refused until that attempt settles. PamContext's signals carry no
  // per-exchange identity that a generation could be checked against, so a
  // write-only counter would be a guard that only looks like one; the former
  // `_exchange` counter was removed rather than left dead. (LOCK-2)
  function tryUnlock() {
    if (!root.requested) return
    if (root.releasing) return
    if (root.authenticating) return
    if (root.password === "") return
    root.authenticating = true
    // Field keeps its dots through the check and the release fade; wiping
    // here would flash the empty prompt before the screen unlocks.
    root.submitted = root.password
    if (!pam.start()) {
      root.finishAuth(false)
      return
    }
    Qt.callLater(root.pumpResponse)
  }

  function pumpResponse() {
    if (!root.authenticating || !pam.active || !pam.responseRequired || root.submitted === "") return
    // The one call in the component that hands the field to PAM.
    pam.respond(root.submitted)
    root.submitted = ""
  }

  function finishAuth(ok) {
    // Spurious error/completed signals must not fabricate attempt counts.
    if (!root.authenticating) return
    root.authenticating = false
    root.submitted = ""
    if (!root.requested) return
    if (ok) {
      root.beginRelease()
    } else {
      root.failedAttempts += 1
      // Surfaces flash their own field on this via fail(); the wipe here
      // only clears the dots.
      root.password = ""
    }
  }

  // Every unlock enters here, from a PAM success or a grace-window input
  // edge. `requested` stays true until the fade ends, so the compositor keeps
  // the lock (and its input grab) for the whole exit instead of unmapping a
  // surface mid-frame. With motion off the fade is skipped entirely.
  function beginRelease() {
    if (root.releasing || !root.requested) return
    root._endGrace()
    root.releasing = true
    if (MotionPolicy.enabled) {
      releaseAnim.restart()
      return
    }
    root.finishRelease()
  }

  // The single release point, reached from beginRelease once the exit fade
  // has drawn its last frame. Runs after the surfaces are gone, so resetting
  // here never paints through.
  function finishRelease() {
    root.releasing = false
    root._endGrace()
    root.requested = false
    root.backdropPath = ""
    root.resetAuth("release")
    // Input delivered to a lock surface need not move the compositor's
    // activity monitor, so the idle daemon cannot rely on that edge to
    // re-arm a timer the lock already spent.
    IdleDaemon.rearmAfterRelease()
  }

  // One clock for every screen. onFinished is the real edge that releases
  // the session lock; no timer guesses how long the fade took.
  NumberAnimation {
    id: releaseAnim

    target: root
    property: "releaseFade"
    from: 1
    to: 0
    // Shared duration token, not a second clock: the whole exit reads the
    // one driver this animation owns.
    duration: Ui.slowMs
    easing.type: Easing.InCubic
    onFinished: root.finishRelease()
  }

  // The gate is sampled once when beginRelease starts the tween. A global
  // switch flipped off mid-fade must not leave the driver easing to zero
  // under an already-torn-down session.
  Connections {
    target: MotionPolicy

    function onEnabledChanged() {
      if (MotionPolicy.enabled || !root.releasing) return
      releaseAnim.stop()
      root.finishRelease()
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: root.requested

    LockscreenSurfaceView {}
  }

  PamContext {
    id: pam

    onResponseRequiredChanged: root.pumpResponse()
    onPamMessage: root.pumpResponse()

    onCompleted: result => root.finishAuth(result === PamResult.Success)
    onError: root.finishAuth(false)
  }

  // Capture backend warmup: loads one screencopy per screen async, drops
  // them once ready, because compositors refuse the first request made from
  // an already-locked session. Always needed - both blurred and dimmed-only
  // backdrops use screencopy now.
  Loader {
    asynchronous: true
    active: true
    onLoaded: active = false

    sourceComponent: Item {
      Repeater {
        // Placeholder screens that appear on wakeup when the compositor
        // briefly has no outputs ("There are no outputs - creating
        // placeholder screen") carry empty names and would warn "Not
        // creating lock surface..." and "Capture source set to non
        // captureable object." Ui.validScreens filters them out.
        model: Ui.validScreens

        delegate: ScreencopyView {
          required property ShellScreen modelData

          captureSource: modelData
          live: false
        }
      }
    }
  }

}
