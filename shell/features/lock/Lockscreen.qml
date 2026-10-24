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
import qs.services
import qs.common
import qs.features.osd
import qs.features.wallpaper
import "../../common/text/UnitIpc.js" as UnitIpc

// Session lock. The IPC handler answers "lockscreen" and
// the session lock engages synchronously in that call - no stabilization
// timers - while auth state lives here so every screen's surface stays in
// sync. A PAM completion reporting Success is the only path that clears the
// lock, so the unit publishes no unlock verb and the neutral request contract
// can only engage one. Backdrop frames come from ScreencopyView inside the
// surface; a throwaway view below warms the capture backend at boot because
// compositors refuse the first request made from an already-locked session.
// Keyboard state (caps, layout) lives in the shared Keyboard singleton.
Singleton {
  id: root

  readonly property string tag: "lockscreen"

  property bool requested: false
  readonly property bool locked: requested || sessionLock.locked || sessionLock.secure

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
    // Freeze the backdrop source for this session up front: background mode
    // pins the wallpaper path here so a swap while locked cannot replace the
    // security backdrop the user is authenticating against. A disabled
    // wallpaper pins nothing, so the surface stays on the theme color.
    root.backdropPath = (Settings.lockscreenBackgroundMode === "background" && Settings.wallpaperEnabled) ? Wallpaper.current : ""
    Keyboard.sync()
    root.requested = true
    root._pauseMusic()
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
    // requested falls only on a PAM completion reporting Success, so this is
    // the single resume point. Pause is handled in lock() to keep the
    // lock request synchronous; resume runs when requested flips false.
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
    // input that can move `locked` back down, and finishRelease is the only
    // caller, so the release is handled there and never here.
    OSD.desktopSuppressed = root.locked
    root._publishState()
  }

  Component.onCompleted: {
    root._publishState()
    SessionActions.adopt(root.lockRequestHandler)
    Registry.offer("lockscreen", {
      title: "Lockscreen",
      description: "session lock surface",
      verbNames: [
        "cycleBlurPower",
        "isLocked",
        "lock",
        "toggleAnimations",
        "toggleBlurBackground",
        "toggleNowPlaying",
        "togglePauseMusic",
        "status",
        "help",
        "ping",
      ]
    })
  }

  // PamContext documents no destruction cleanup, so an exchange still active
  // when this owner is torn down is aborted here; the guard keeps a context
  // that holds no session from being aborted.
  Component.onDestruction: {
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

  // Field text flows input -> here -> sibling inputs; guards break the loop.
  // The only function in the component that receives what the user typed, so
  // it stores the value and returns.
  function setPassword(text) {
    if (root.password === text) return
    root.password = text
  }

  property int _exchange: 0

  function tryUnlock() {
    if (!root.requested) return
    if (root.authenticating) return
    if (root.password === "") return
    root.authenticating = true
    // Field keeps its dots through the check and the release fade; wiping
    // here would flash the empty prompt before the screen unlocks.
    root.submitted = root.password
    root._exchange = 0
    if (!pam.start()) {
      root.finishAuth(false)
      return
    }
    Qt.callLater(root.pumpResponse)
  }

  function pumpResponse() {
    if (!root.authenticating || !pam.active || !pam.responseRequired || root.submitted === "") return
    // The one call in the component that hands the field to PAM.
    root._exchange += 1
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
      root.finishRelease()
    } else {
      root.failedAttempts += 1
      // Surfaces flash their own field on this via fail(); the wipe here
      // only clears the dots.
      root.password = ""
    }
  }

  // Reachable only from a PAM completion reporting Success, so a release is
  // always an authentication result. Runs after the surfaces are gone, so
  // resetting here never paints through.
  function finishRelease() {
    root.requested = false
    root.backdropPath = ""
    root.resetAuth("release")
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

  IpcHandler {
    target: "lockscreen"
    function help(command: string): string {
      return UnitIpc.help("lockscreen", "Lockscreen", "session lock surface", [
        { name: "cycleBlurPower", help: "cycle blur power state" },
        { name: "isLocked", help: "locked?" },
        { name: "lock", help: "lock the session" },
        { name: "toggleAnimations", help: "toggle lock animations" },
        { name: "toggleBlurBackground", help: "toggle blurred background" },
        { name: "toggleNowPlaying", help: "toggle now-playing widget" },
        { name: "togglePauseMusic", help: "pause music on lock" },
      ], command)
    }
    function ping(): string { return "pong" }

    function lock(): string {
      root.lock("verb")
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.requested,
        secure: sessionLock.secure,
        authenticating: root.authenticating,
        failedAttempts: root.failedAttempts,
        capsLock: Keyboard.capsOn,
        layout: Keyboard.layout,
        // Entrance motion follows the global animation switch.
        animations: MotionPolicy.enabled,
        backgroundMode: Settings.lockscreenBackgroundMode,
        vignette: Settings.lockscreenVignette,
        blurBackground: Settings.blurBackground,
        dim: Settings.lockscreenDim,
        dimBlurred: Settings.lockscreenDimBlurred,
        nowPlaying: Settings.lockscreenNowPlaying,
        blurPower: Settings.lockscreenBlurPower,
        pauseMusic: Settings.lockscreenPauseMusic
      })
    }

    // A user toggling an effect while the session sits locked is changing a
    // running effect, and the surfaces re-resolve on the next frame.
    function toggleAnimations(): string {
      // The lockscreen does not own an animation option; this toggle
      // flips the global switch instead.
      HyprlandSettings.toggleOption("hypr.animations.enabled")
      const now = HyprlandSettings.value("hypr.animations.enabled")
      return now ? "on" : "off"
    }

    function toggleNowPlaying(): string {
      Settings.toggleLockscreenNowPlaying()
      return Settings.lockscreenNowPlaying ? "on" : "off"
    }

    function togglePauseMusic(): string {
      Settings.toggleLockscreenPauseMusic()
      return Settings.lockscreenPauseMusic ? "on" : "off"
    }

    function toggleBlurBackground(): string {
      Settings.toggleBlurBackground()
      return Settings.blurBackground ? "on" : "off"
    }

    function cycleBlurPower(): string {
      Settings.cycleLockscreenBlurPower()
      return Settings.lockscreenBlurPower
    }
  }
}
