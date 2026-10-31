pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.common
// qs.services exports a Timer singleton, and an unaliased import would
// shadow the QtQuick one the hide/exit/progress timers below use, so the
// media state owner and the art warmer are named through the alias.
import qs.services as Core
import "../../common/NowPlaying.js" as NP
import "../../common/text/UnitIpc.js" as UnitIpc
import "../../common/theme/DeviceIcons.js" as DeviceIcons

// OSD service: transient screen progress. Holds the visible payload
// (kind/value/label/icon/muted), the configurable bottom offset
// and the lock suppression flag, drives the
// auto-hide Timer, and publishes the `qs ipc call osd flash <json>`
// surface. View is in OSDView.qml; this file owns only state and policy.
//
// Media is the one payload that arrives from somewhere else: MediaEvents
// classifies what the MPRIS backend did, MediaState owns the normalized
// state, and this file subscribes to the event stream and decides what to
// do about it. The nowplaying switch, the suppression rules and the
// show/hide decision all live here for that reason, and the service that
// observes the backend knows none of them.
Singleton {
  id: root

  readonly property string tag: "osd"

  // How long the surface stays mapped after the last show().
  readonly property int visibleMs: 1500
  // Nowplaying flash: 2000ms total.
  readonly property int mediaMs: 2000

  property bool visible: false
  property bool dismissing: false
  // Written by the lockscreen: session-lock surfaces render above all
  // layer-shell windows, so the desktop surface stays unmapped while
  // locked and an unlock never greets a stale flash. Read through
  // surfaceVisible and mediaCanPresent below, so the rule is written once.
  property bool desktopSuppressed: false
  onDesktopSuppressedChanged: {
    if (!root.desktopSuppressed) return
    hideTimer.stop()
    exitTimer.stop()
    root._clearLiveSource()
    root.visible = false
    root.dismissing = false
  }
  property var _mediaIslands: []
  readonly property bool mediaIslandOpen: root._mediaIslands.length > 0
  // A payload is up while it is mapped or fading out. The desktop surface
  // maps only when that is true and the lock is not suppressing it.
  readonly property bool payloadVisible: root.visible || root.dismissing
  readonly property bool surfaceVisible: root.payloadVisible && !root.desktopSuppressed
  // Payload shown while visible. `value` is 0..100, `muted` when set
  // forces the muted glyph/label and dims the meter.
  property string kind: "volume"
  property real value: 0
  property string label: ""
  property string iconName: "volume-max"
  property bool muted: false
  // Track-change payload (kind "nowplaying" only): cover url plus up
  // to three text rows (track/artist/album). Ignored by meter kinds.
  property string artUrl: ""
  property var lines: []

  // Track progress (kind "nowplaying" only): position/length in
  // seconds drive the bar and the inline elapsed time below.
  // transportPaused dims the bar and freezes the art spin plus the
  // live tick. No volume state: the OSD never carried player volume.
  property real positionSec: 0
  property real lengthSec: 0
  property var _nowPlayingPlayer: null
  property string _nowPlayingSourceKey: ""
  property bool transportPaused: false
  property bool longFlash: false

  readonly property real progressPct: NP.progressPercent(root.positionSec, root.lengthSec)
  readonly property string elapsedText: root.lengthSec > 0 ? NP.fmtDuration(root.positionSec) : ""
  readonly property string totalText: root.lengthSec > 0 ? NP.fmtDuration(root.lengthSec) : ""

  // Placement is fixed: always at the bottom side of the screen,
  // `offset` px above the bottom edge (mirrors OSDs that hover above a
  // bottom bar without overlapping it). Validated against the same check
  // the view uses so malformed persisted values never crash the shell -
  // they fall back to the default and the store keeps the bad value until
  // the user fixes it via Settings/IPC.
  // The OSD offers no top/bottom switch: `position` is a constant, kept for
  // IPC compatibility with a caller that still asks for one.
  readonly property string position: "bottom"
  readonly property int offset: {
    root.revDep
    const v = Settings.value("shell.osd.offset")
    return typeof v === "number" && v >= 0 && v <= 400 ? Math.round(v) : 80
  }
  // Standalone now-playing placement (Media Controls): its own
  // top/bottom switch plus offset. Meter kinds keep the global
  // bottom + offset above. Same validation: malformed values
  // fall back, never crash.
  readonly property string nowPlayingPosition: {
    root.revDep
    const v = Settings.value("shell.osd.nowPlayingPosition")
    return v === "top" || v === "bottom" ? v : "bottom"
  }
  readonly property int nowPlayingOffset: {
    root.revDep
    const v = Settings.value("shell.osd.nowPlayingOffset")
    return typeof v === "number" && v >= 0 && v <= 400 ? Math.round(v) : 80
  }
  // Boot settle: bindings pass through fallback values while the
  // store lands, which would otherwise fake a placement change and
  // pop a preview on every boot. Starts closed: a change firing
  // before Component.onCompleted (still -1) is a boot artifact, not
  // a user edit. Same _bootAt idiom as the bar pill. The window is
  // construction-relative, so a store that lands after it is not
  // covered by it; both guards below also read Settings.ready, and
  // the two are independent: the window holds off the first real
  // write once the store IS ready, the flag holds off a slow one.
  property double _bootAt: -1
  // Placement preview: editing position/offset re-maps the live
  // card (or a dummy one when nothing played yet) so the new spot
  // reads at once. Change signals fire only on real edits, never
  // on boot or on unrelated settings flushes.
  onOffsetChanged: root.previewMeterPlacement()
  onNowPlayingPositionChanged: root.previewPlacement()
  onNowPlayingOffsetChanged: root.previewPlacement()
  function previewPlacement() {
    if (root._bootAt <= 0 || Date.now() - root._bootAt < 3000) return
    if (!Settings.ready) return
    if (Settings.value("shell.osd.nowPlaying") !== true) return
    if (root.kind === "nowplaying" && (root.lines.length > 0 || root.label !== "")) {
      root.visible = true
      hideTimer.restart()
      return
    }
    // Dummy payload when nothing played yet.
    root.show("nowplaying", 0, "Never Gonna Give You Up", "music-album", false, {
      artUrl: "",
      lines: [
        { icon: "music-track", text: "Never Gonna Give You Up" },
        { icon: "music-artist", text: "Rick Astley" },
        { icon: "music-album", text: "Whenever You Need Somebody" }
      ],
      position: 60,
      length: 213,
      paused: false,
      long: false
    })
  }
  function previewMeterPlacement() {
    if (root._bootAt <= 0 || Date.now() - root._bootAt < 3000) return
    if (!Settings.ready) return
    if (root.visible && root.kind !== "nowplaying") {
      hideTimer.restart()
      return
    }
    root.show("volume", 50, "", "volume-max", false)
  }
  // Settings.rev bump gate so position/offset bindings re-evaluate on
  // every settings flush without the singleton subscribing to every key.
  readonly property int revDep: Settings.rev

  // Global animation gate (hypr.animations.enabled), wired at lib level
  // like PanelCard/Island/OverlayWindow so consumers need not bind it.
  readonly property bool animationsEnabled: MotionPolicy.enabled

  // Session-wide fullscreen, so a payload shown over a fullscreen app is
  // suppressed. The walk and the strict `=== true` live in
  // FullscreenProbe.
  readonly property bool fullscreenActive: FullscreenProbe.anyActive

  // Show the OSD with the given payload. Restarts the hide timer.
  // `value` is clamped: brightness allows -90..100 (negative = gamma
  // dimming, used to tint the bar background dim red), volume/mic 0..100.
  // `label` is kept verbatim (empty means the view hides the text line -
  // used for icon+bar-only displays).
  function show(kind, value, label, icon, muted, extra) {
    const k = String(kind || "volume").toLowerCase()
    const allowed = { volume: 1, microphone: 1, brightness: 1, nowplaying: 1 }
    if (!allowed[k]) return false
    if (k === "nowplaying") {
      if (root.mediaIslandOpen) return false
      const data = extra || {}
      const art = data.artUrl ? String(data.artUrl) : ""
      const rawLines = data.lines ? data.lines : []
      const lin = Array.isArray(rawLines) ? rawLines.slice(0, 3) : []
      const lb = String(label || "")
      const nic2 = String(icon || "music-album").trim()
      const nic = nic2 !== "" ? nic2 : "music-album"
      const player = data.player && typeof data.player === "object" ? data.player : null
      const sourceKey = player ? NP.playerKey(player) : String(data.sourceKey || "")
      const rawLen = Number(data.length)
      const len = player ? NP.playerLength(player) : (isFinite(rawLen) ? Math.max(0, rawLen) : 0)
      const pos = NP.normalizePosition(Number(data.position), len)
      const paused = player
        ? player.playbackState !== MprisPlaybackState.Playing
        : data.paused === true
      const long = data.long === true
      root._commitNowPlaying(k, art, lin, lb, nic, pos, len, paused, long, player, sourceKey)
      return true
    }
    let v = Number(value)
    if (isNaN(v)) v = 0
    v = Math.round(v)
    if (k === "brightness") v = Math.max(-90, Math.min(100, v))
    else v = Math.max(0, Math.min(100, v))
    const lb = String(label || "")
    const ic = String(icon || "").trim()
    root._clearLiveSource()
    root.artUrl = ""
    root.lines = []
    root.positionSec = 0
    root.lengthSec = 0
    root.transportPaused = false
    root.longFlash = false
    exitTimer.stop()
    root.dismissing = false
    root.kind = k
    root.value = v
    root.muted = muted === true
    root.label = lb
    root.iconName = ic !== "" ? ic : root._iconFor(k, v, root.muted)
    root.visible = true
    hideTimer.restart()
    return true
  }

  function _iconFor(kind, v, muted) {
    if (muted) return "volume-off"
    if (kind === "brightness") return "brightness"
    if (kind === "microphone") return v <= 0 ? "mic-off" : "mic-on"
    // Percent-scale volume leg, canonicalized in
    // common/theme/DeviceIcons.js (fraction scale there, percent here -
    // the OSD stays decoupled from the Audio service; both follow thirds).
    return DeviceIcons.volumeIconFor(Number(v) / 100, false)
  }

  // Wave groups kept opaque on the tiered volume-max glyph (same thirds
  // as _iconFor above, mirrored from Audio.volumeDimTiersFor). The view
  // binds this next to the icon name; non-tiered glyphs ignore it.
  function _dimTiersFor(kind, v, muted) {
    if (kind === "brightness" || kind === "microphone" || muted) return 0
    const n = Number(v)
    if (isNaN(n) || n <= 0) return 0
    if (n < 33) return 1
    if (n < 67) return 2
    return 3
  }

  function hide() {
    hideTimer.stop()
    root._clearLiveSource()
    if (!root.visible) {
      root.dismissing = false
      return
    }
    if (!root.animationsEnabled) {
      root.visible = false
      root.dismissing = false
      return
    }
    root.dismissing = true
    root.visible = false
    exitTimer.restart()
  }

  function retainMediaIsland(owner) {
    if (!owner || root._mediaIslands.indexOf(owner) >= 0) return
    root._mediaIslands = root._mediaIslands.concat([owner])
    if (root._mediaIslands.length === 1 && root.kind === "nowplaying") root.hide()
  }

  function releaseMediaIsland(owner) {
    const index = root._mediaIslands.indexOf(owner)
    if (index < 0) return
    root._mediaIslands = root._mediaIslands.slice(0, index).concat(root._mediaIslands.slice(index + 1))
  }

  function hideMedia(player) {
    if (root.kind !== "nowplaying") return
    if (player && root._nowPlayingPlayer && player !== root._nowPlayingPlayer) return
    root.hide()
  }

  // --- media presentation -------------------------------------------------
  //
  // The service publishes an event; this is the whole of what happens
  // next. The three switches below are the OSD's own (they read
  // shell.osd.* keys, they are about this surface), and the media observer
  // publishes a classification without reading any of them: the surface
  // decides what it shows.

  // shell.osd.nowPlaying: whether a media flash exists at all. The card
  // still up when the switch goes off is stale feedback, so it goes too.
  readonly property bool nowPlayingEnabled: {
    root.revDep
    return Settings.value("shell.osd.nowPlaying") === true
  }
  // shell.osd.nowPlayingArt: the cover is optional in the card.
  readonly property bool nowPlayingArt: {
    root.revDep
    return Settings.value("shell.osd.nowPlayingArt") === true
  }
  // The whole flash gate in one predicate: the switch, the lock's desktop
  // suppression, and the open-island rule. A flash needs all three; a
  // hide needs none of them, which is why the stop and swap paths below
  // do not consult it.
  function mediaCanPresent() {
    return root.nowPlayingEnabled && !root.desktopSuppressed && !root.mediaIslandOpen
  }
  onNowPlayingEnabledChanged: {
    if (root.nowPlayingEnabled) return
    root.hideMedia()
  }

  // Subscribed, not called: the service has no reference to this
  // surface, and one event reads as one change.
  Connections {
    target: Core.MediaState

    function onEventChanged() { root.applyMediaEvent(Core.MediaState.event) }
  }

  function applyMediaEvent(event) {
    if (!event) return false
    if (event.kind === "player") {
      // The tracked player left or was replaced, so a card still showing
      // it is stale. A card with no tracked player behind it - the
      // placement preview - is not tied to the swap and is left alone.
      if (event.player === null || event.previous !== null) root.hideMedia(event.previous)
      return false
    }
    if (event.kind === "stopped") {
      root.hideMedia(event.player)
      return false
    }
    if (event.kind !== "track" && event.kind !== "transport") return false
    if (!root.mediaCanPresent()) return false
    return root.show("nowplaying", 0, event.title, event.icon, false, {
      player: event.player,
      artUrl: root.nowPlayingArt ? event.artUrl : "",
      lines: [
        { icon: "music-track", text: event.title !== "" ? event.title : "--" },
        { icon: "music-artist", text: event.artist !== "" ? event.artist : "--" },
        { icon: "music-album", text: event.album !== "" ? event.album : "--" }
      ],
      position: event.position,
      length: event.length,
      paused: event.paused,
      // A track change is the long flash; a transport change is not.
      long: event.kind === "track"
    })
  }

  // Art demand: the warmer holds a cover while this card is displaying it
  // and lets it go with the card, so nothing is decoded for a flash that
  // is not up. The OSD renders the cover from artUrl either way; the
  // demand is only about the shared pixmap cache being warm.
  function _clearArtDemand() {
    if (root.artUrl === "") return
    Core.MediaArt.release(root.artUrl)
  }

  function _clearLiveSource() {
    root._clearArtDemand()
    root._nowPlayingPlayer = null
    root._nowPlayingSourceKey = ""
  }

  function _commitNowPlaying(k, art, lin, lb, nic, pos, len, paused, long, player, sourceKey) {
    root.kind = k
    root.value = 0
    root.muted = false
    root.label = lb
    root.iconName = nic
    // The card swaps covers, so the previous demand goes with it.
    root._clearArtDemand()
    if (art !== "") Core.MediaArt.request(art)
    root.artUrl = art
    root.lines = lin
    root.positionSec = pos
    root.lengthSec = len
    root.transportPaused = paused
    root.longFlash = long
    root._nowPlayingPlayer = player
    root._nowPlayingSourceKey = sourceKey
    exitTimer.stop()
    root.dismissing = false
    root.visible = true
    hideTimer.restart()
  }

  function _syncLiveMedia() {
    const p = root._nowPlayingPlayer
    if (!p) return
    if (p.playbackState === MprisPlaybackState.Stopped) {
      root.hide()
      return
    }
    if (NP.playerKey(p) !== root._nowPlayingSourceKey) {
      root.hide()
      return
    }
    const len = NP.playerLength(p)
    root.lengthSec = len
    root.positionSec = NP.normalizePosition(NP.playerPosition(p), len)
    root.transportPaused = p.playbackState !== MprisPlaybackState.Playing
    root._syncLiveArt()
  }

  // A player fills `trackArtUrl` slightly *after* it announces the track:
  // the docs are explicit that trackArtUrl, unlike the name fields, often
  // lands late. The event payload was frozen when the card was built, so an
  // art read taken at that instant is routinely empty - which is why the
  // cover arrives late on a track change rather than never.
  //
  // Re-reading it here, and only here, is what lets the card pick the cover
  // up: this runs on postTrackChanged and on the art signal itself. The
  // demand moves with the url so the warmer's refcount stays balanced - a
  // replaced cover releases the one it held rather than pinning both.
  function _syncLiveArt() {
    if (!root.nowPlayingArt) return
    const want = root._nowPlayingPlayer !== null
      ? String(root._nowPlayingPlayer.trackArtUrl ?? "")
      : ""
    if (want === root.artUrl) return
    root._clearArtDemand()
    if (want !== "") Core.MediaArt.request(want)
    root.artUrl = want
  }

  Timer {
    id: hideTimer
    interval: root.kind === "nowplaying" ? (root.longFlash ? root.mediaMs * 2 : root.mediaMs) : root.visibleMs
    repeat: false
    onTriggered: root.hide()
  }

  Timer {
    id: exitTimer
    interval: Ui.fastMs
    repeat: false
    onTriggered: root.dismissing = false
  }

  // No position timer here on purpose. The card only ever holds a player
  // that came off a MediaState event, and MediaState publishes only about
  // the active player - which MediaEvents already ticks once a second for the
  // whole shell. A second tick on the same object would re-enter every
  // onPositionChanged handler for no gain. The placement preview passes no
  // player at all, so there is no second case to cover.

  Connections {
    target: root._nowPlayingPlayer

    function onPositionChanged() { root._syncLiveMedia() }
    function onPositionSupportedChanged() { root._syncLiveMedia() }
    function onLengthChanged() { root._syncLiveMedia() }
    function onLengthSupportedChanged() { root._syncLiveMedia() }
    function onPlaybackStateChanged() { root._syncLiveMedia() }
    function onPostTrackChanged() { root._syncLiveMedia() }
    function onMetadataChanged() { root._syncLiveMedia() }
    function onUniqueIdChanged() { root._syncLiveMedia() }
    // The cover lands after the announcement, on its own notify. Without
    // this the card waits for the next position tick to notice it, and the
    // warmer is asked for the cover a second late.
    function onTrackArtUrlChanged() { root._syncLiveArt() }
  }

  // Instantiate the surface once the singleton is boot-touched. The
  // view reads this singleton's properties directly, no prop threading.
  // LazyLoader moves that construction off the boot frame without gating it:
  // `loading: true` with no `active` builds once and stays resident, which is
  // what a bare OSDView {} did minus the boot-frame cost. Deliberately not
  // gated on surfaceVisible - that would unmap and re-map the window between
  // flashes, and a meter has to answer the first keypress instantly.
  LazyLoader {
    loading: true

    OSDView {}
  }

  Component.onCompleted: {
    Registry.offer("osd", {
      title: "OSD",
      description: "on-screen display overlays",
      verbNames: [
        "hide",
        "flash",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register(root.tag, root)
    root._bootAt = Date.now()
  }
  Component.onDestruction: Registry.unregister(root.tag)

  IpcHandler {
    target: "osd"
    function help(command: string): string {
      return UnitIpc.help("osd", "OSD", "on-screen display overlays", [
        { name: "hide", help: "hide the OSD" },
        { name: "flash", help: "(kind, value, label, icon, muted) flash the OSD" },
      ], command)
    }
    function ping(): string { return "pong" }

    // JSON payload: { kind, value, label, icon, muted }. Named `flash`
    // rather than `show` on purpose: the singleton owns a multi-param
    // show() for in-process callers, and a second `show` on the IPC
    // surface makes CLI dispatch refuse arguments on both. Empty-valued
    // keys are omitted by senders: `qs ipc call` hands the argument
    // through verbatim, and the parse below runs until the value stops
    // being a string, so either encoding lands on the object.
    function flash(json: string): string {
      let o = json
      for (let i = 0; i < 3 && typeof o === "string"; i++) {
        try {
          o = JSON.parse(o)
        } catch (e) {
          return "error: invalid JSON"
        }
      }
      if (o === null || typeof o !== "object" || Array.isArray(o)) return "error: invalid JSON"
      const ok = root.show(o.kind, o.value, o.label, o.icon, o.muted)
      return ok ? "ok" : "error"
    }

    function hide(): string { root.hide(); return "ok" }

    function status(): string {
      return JSON.stringify({
        visible: root.visible,
        dismissing: root.dismissing,
        kind: root.kind,
        value: root.value,
        label: root.label,
        icon: root.iconName,
        muted: root.muted,
        artUrl: root.artUrl,
        lines: root.lines,
        position: root.kind === "nowplaying" ? root.nowPlayingPosition : root.position,
        offset: root.kind === "nowplaying" ? root.nowPlayingOffset : root.offset,
        positionSec: root.positionSec,
        lengthSec: root.lengthSec,
        transportPaused: root.transportPaused,
        longFlash: root.longFlash,
        sourceKey: root._nowPlayingSourceKey,
        mediaIslandOpen: root.mediaIslandOpen,
        animationsEnabled: root.animationsEnabled,
        fullscreenActive: root.fullscreenActive
      })
    }
  }
}
