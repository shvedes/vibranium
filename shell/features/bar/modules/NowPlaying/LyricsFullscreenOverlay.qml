pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.common
import qs.services as Core
import "../../../../common/NowPlaying.js" as NP
import "../../../../common/process/CommandSpec.js" as CommandSpec
import "../../../../common/math/Range.js" as Range

// Lyrics window for the Now Playing island: a left click on the island's
// cover while its transcript is up asks the module to open this window, which
// outlives the island and is handed the client rather than a binding to it.
//
// The composition is ratio-driven rather than pixel-driven, so 16:9, 16:10
// and 3:2 outputs all read the same: a cover column on the left with the track
// and artist on their own centred lines under it, then the seek lane and the
// transport pads, and the synced transcript running
// the full height of the window on the right, its top and bottom edges blurred.
// The cover box is
// derived from the cover's own aspect ratio, drawn at 97.75% of the fit its
// column allows, and centred in the column, so a portrait or wide cover is
// neither cropped nor left in a letterbox. Three chrome buttons sit at the top
// left: fullscreen, backdrop transparency and the idle hold.
//
// F toggles fullscreen, Esc returns to tiled, Q closes the window. Clicking
// the enlarged artwork leaves that view.
//
// A regular toplevel, not a layer surface, like the audio mixer and the image
// viewer. The transcript is an app-like view: it seeks, it takes keys and can
// be sent fullscreen, so a window the compositor lists is one the user can
// reach from a switcher and leave with the same verbs as any other window.
// Idle inhibition belongs to fullscreen or to the explicit caffeine button,
// never to a plain window. Quickshell 0.3.2 has no toplevel of its own -
// `PanelWindow` always maps `wlr_layer_shell_v1` and `PopupWindow` needs a
// parent - so the window
// below is a plain QtQuick `Window`. The root is a holder because a `Window`
// created inside a QQuickItem renders into that item instead of reaching the
// compositor (see AudioMixerWindow.qml for the measured case).
QtObject {
  id: root

  // Filled by the island at open time. The MPRIS object outlives both the
  // island and this window, which is why a reference is enough.
  property var player: null
  property bool opened: false
  property ShellScreen targetScreen: null

  // Window mode is read from the Window's own visibility, never a shadow flag:
  // a compositor can leave fullscreen on its own, and the button has to agree
  // with whatever the surface is actually doing.
  readonly property bool fullscreen: root.win !== null
    && root.win.visibility === Window.FullScreen
  // Inhibition follows fullscreen until the user overrides it: -1 forces it
  // off (including in fullscreen), 1 forces it on in a plain window, 0 is the
  // automatic state. One button flips to the opposite of what is in force.
  property int inhibitChoice: 0
  readonly property bool inhibitWanted: root.opened
    && (root.inhibitChoice === 1
      || (root.inhibitChoice === 0 && root.fullscreen))

  readonly property bool animOn: MotionPolicy.enabled
  readonly property string artUrl: root.player !== null ? root.player.trackArtUrl ?? "" : ""
  // One normalized reading per field: a client that puts newlines or repeated
  // spaces in its metadata must not push the centred lines into the transport
  // row or wrap the tooltip. All three consumers read these, not the raw tags.
  readonly property string title: root.player !== null ? NP.displayText(root.player.trackTitle) : ""
  readonly property string artist: root.player !== null ? NP.displayText(root.player.trackArtist) : ""
  readonly property string album: root.player !== null ? NP.displayText(root.player.trackAlbum) : ""
  readonly property bool playing: root.player !== null
    && root.player.playbackState === MprisPlaybackState.Playing
  readonly property real lengthSec: NP.playerLength(root.player)
  readonly property bool canSeekPosition: NP.canSetPlayerPosition(root.player)
  // Transport, gated per client exactly as the island's pads are: a
  // capability the client publishes false refuses the write and dims its pad.
  readonly property bool hasTrack: root.title !== ""
  readonly property bool canTogglePlaying: root.player !== null
    && root.player.canTogglePlaying !== false
  // One displayed position, derived from the live player. A seek preview is
  // the only imperative writer, and only while the finger owns the lane;
  // outside a scrub there is no copy to fall stale. The clock's frame edge
  // re-evaluates this binding, so the strip, the clock readout and the lyric
  // cue all read the same value.
  property real previewPosition: 0
  readonly property real shownPosition: root._seeking ? root.previewPosition : NP.reanchorPosition(root.player, root.lengthSec)
  readonly property real progressRatio: root.lengthSec > 0
    ? Math.min(1, root.shownPosition / root.lengthSec) : 0
  // Click seeks ease, sustained drags snap: the pointer must travel past 6px
  // while pressed before the lane belongs to the drag. Same contract as the
  // island's lane.
  property bool _seeking: false
  property real _pressX: 0

  // The transcript's presence during a track swap: 1 shown, 0 cleared while
  // the new sheet lands. The swap animation owns this one scalar; the four
  // effect copies derive their opacity from lyricsSide.opacity below, which is
  // a pure function of it. Nothing leaves a raw 0 on the item, so closing
  // mid-swap and reopening the SAME track (no new trackKey edge) cannot bring
  // the transcript back dim.
  property real swapK: 1

  // Backdrop density. The surface paints the theme background solid under the
  // transcript; the transparency button swaps it for the same color at 80%
  // opacity, which lets the desktop read faintly behind the lyrics while they
  // stay legible. A view preference rather than a setting, so it lives in the
  // shell cache ($VIBRANIUM_CACHE/shell.json, "lyrics" section) instead of the
  // settings catalog.
  //
  // The fill is a Rectangle inside the window, not the window's own `color`:
  // a surface color reaches the compositor with the surface, so a live change
  // to it only shows up the next time the surface is mapped - the backdrop
  // stayed opaque until the overlay was reopened. A Rectangle is ordinary
  // scene graph and repaints on the tick the cache write lands, which is also
  // what lets the compositor's window blur follow the alpha.
  readonly property real dimBackdropAlpha: 0.8

  // Read from the cache when the surface is built and again when it opens, so
  // a restart and a second overlay (one per bar) both land on the saved value;
  // toggleBackdrop is the only writer. Anything outside (0, 1) - absent,
  // hand-edited, a future value this switch does not own - reads as the solid
  // backdrop rather than as a half-painted surface.
  //
  // A plain property, NOT a binding. The first cache read creates the slot,
  // which bumps AppState.rev, so a binding that reads the cache depends on rev
  // while its own evaluation is what changes it - Qt reports that as a binding
  // loop on this property. The constructor and the open handler read the same
  // cache outside any binding and cost nothing while the surface is closed.
  property real backdropAlpha: 1

  function _readBackdrop() {
    const a = ShellCache.number("lyrics", "backdropAlpha", 1)
    root.backdropAlpha = a > 0 && a < 1 ? a : 1
  }

  Component.onCompleted: root._readBackdrop()

  readonly property color backdropColor: Ui.tint("background_0", root.backdropAlpha)
  // The empty-state fills sit on top of the surface backdrop. Painting the
  // same translucent color there would stack a second layer and read as
  // solid, so a dimmed backdrop leaves them transparent instead.
  readonly property color emptyStateColor: root.backdropAlpha < 1
    ? "transparent" : root.backdropColor

  function toggleBackdrop() {
    const next = root.backdropAlpha >= 1 ? root.dimBackdropAlpha : 1
    ShellCache.updateSection("lyrics", { backdropAlpha: next })
    root.backdropAlpha = next
  }

  // The compositor owns the fullscreen mode; visibility is the request and
  // the state at once, as in the image viewer. No visibility is assigned at
  // construction - a non-windowed state maps the Window at shell startup.
  function toggleFullscreen() {
    if (root.win === null) return
    root.win.visibility = root.fullscreen ? Window.Windowed : Window.FullScreen
  }

  function toggleInhibit() {
    root.inhibitChoice = root.inhibitWanted ? -1 : 1
  }

  // No client is a state, not an error: the menu can open the surface in
  // standby and the first MPRIS player that appears is adopted below.
  readonly property bool standby: root.opened
    && (root.player === null || root.player === undefined)

  function open(p) {
    root.player = p !== undefined ? p : null
    root.opened = true
    // LYR-2: focus is claimed on the window's real activation edge below, not
    // here. A speculative claim at open time fires before the toplevel is
    // active and was a second writer of the same focus fact.
  }

  function close() {
    root.artExpanded = false
    // A hidden fullscreen window would reopen fullscreen and inhibit before
    // anyone asked; leaving fullscreen keeps the next open in window mode.
    if (root.fullscreen) root.win.visibility = Window.Windowed
    root.opened = false
  }

  // The one position-commit path. Every seek on this surface - lane click,
  // drag release, wheel step and the transcript's own seek requests - funnels
  // through here: one gate, one clamp, one write of the player's position, one
  // notify, one release of the drag. The lane is derived from the player, so
  // the write moves it at once; the daemon's notify corrects it a moment later.
  // `scrubTo` owns the preview, and only until the drag ends.
  function commitSeek(seconds) {
    if (!root.canSeekPosition || root.player === null) return
    const t = Range.clamp(Number(seconds) || 0, 0, root.lengthSec)
    root.player.position = t
    root._seeking = false
    root.player.positionChanged()
  }

  function seekAt(x, w) {
    if (w <= 0) return
    root.commitSeek(NP.scrubPosition(x, w, root.lengthSec))
  }

  // Scrub preview: moves the preview the lane derives from, writes no player
  // state. A per-move position write queues up in the player and replays after
  // release, so a drag commits once, on release.
  function scrubTo(x, w) {
    if (!root.canSeekPosition || w <= 0) return
    root.previewPosition = NP.scrubPosition(x, w, root.lengthSec)
  }

  function seekTo(seconds) {
    root.commitSeek(seconds)
  }

  function togglePlaying() {
    if (!root.canTogglePlaying) return
    root.player.togglePlaying()
  }

  function previousTrack() {
    if (!root.hasTrack || root.player?.canGoPrevious === false) return
    NP.noteManual("previous")
    root.player?.previous()
  }

  function nextTrack() {
    if (!root.hasTrack || root.player?.canGoNext === false) return
    NP.noteManual("next")
    root.player?.next()
  }

  // The artwork click opens an enlarged copy of the cover over the whole
  // surface. Close it on teardown so a later open starts on the transcript.
  property bool artExpanded: false

  function toggleArtExpanded() {
    if (root.artUrl === "") return
    root.artExpanded = !root.artExpanded
  }

  onOpenedChanged: {
    root._seeking = false
    if (root.opened) {
      // A toggle made in another bar's overlay is a cache write, and this is
      // the only read that follows it: the property itself is not a binding.
      root._readBackdrop()
    } else {
      // Teardown is an edge too: retire any staged fade so a later reopen of
      // the same track starts from a fully shown transcript.
      trackSwap.stop()
      root.swapK = 1
    }
  }
  // One edge owns both inhibitors: fullscreen, or the manual caffeine button
  // while the surface is open. A plain window never holds the session awake.
  onInhibitWantedChanged: {
    if (root.inhibitWanted) root._holdStart()
    else root._holdStop()
  }
  Component.onDestruction: root._holdStop()
  onPlayerChanged: {
    root._seeking = false
    // A client leaving the bus drops the surface into standby; the window
    // stays up so the next player can be adopted without another menu trip.
  }
  onStandbyChanged: if (root.standby) root.artExpanded = false
  // --- logind hold ---------------------------------------------------------
  //
  // The Wayland inhibitor below is what stops the compositor idling, but logind
  // has no record of it, so `systemd-inhibit --list` and the lock screen's
  // blocker notice (which reads logind's ListInhibitors) cannot see it. This is
  // the same hold as a real logind lock: an idle block owned by a
  // systemd-inhibit child for as long as inhibition is wanted - fullscreen or
  // the manual button, never a plain window. Idle only, the policy the
  // caffeine lock already follows - an explicit suspend stays an explicit
  // suspend.
  property var _holdJob: null

  function _holdStart() {
    if (root._holdJob !== null || !root.inhibitWanted) return
    const spec = CommandSpec.argv([
      "systemd-inhibit", "--what=idle", "--who=Vibranium",
      "--why=Lyrics fullscreen or caffeine is active", "--mode=block",
      "sleep", "infinity"
    ])
    if (spec.ok !== true) return
    const ended = () => {
      root._holdJob = null
      // A hold that died under a wanted state is retried; one released by
      // leaving fullscreen or turning the button off is not.
      if (root.inhibitWanted) holdRetry.restart()
    }
    let job = null
    try {
      job = ProcessRegistry.start(spec, "lyrics:inhibit", {
        timeoutMs: 0,
        maxAttempts: 1,
        spawnWatchdogMs: 3000,
        onFinished: ended,
        onFailed: ended
      })
    } catch (ignored) {
      job = null
    }
    if (job === null) {
      holdRetry.restart()
      return
    }
    root._holdJob = job
  }

  function _holdStop() {
    holdRetry.stop()
    const job = root._holdJob
    root._holdJob = null
    if (job === null) return
    try {
      if (String(job.state) !== "settled") job.cancel("released")
    } catch (ignored) {}
  }

  onArtUrlChanged: {
    artFade.stop()
    artNext.opacity = 0
    if (root.artUrl === "") {
      artNext.source = ""
      art.opacity = 0
      return
    }
    // The incoming layer is set unconditionally: the settled layer keeps the
    // previous pixmap up while the new one decodes, so every switch has a
    // frame to fade over, and the first cover on a fresh surface simply fades
    // in. Waiting for the settled layer to read Ready here is wrong - by the
    // time this handler runs it may already be loading the new url.
    artNext.source = root.artUrl
  }

  // The window, held rather than declared as the component root: this file is
  // instantiated as a child of the Now Playing module, which is an Item, and a
  // `Window` created inside a QQuickItem renders into it instead of reaching
  // the compositor. Everything above this line is the holder's state; every
  // child below it belongs to the window.
  property Window win: Window {
    visible: root.opened
    title: "Player view"
    // `WindowScreen` is the name-matching bridge between Quickshell's screen
    // objects and the QtQuick Screen a `Window` takes; a name that does not
    // meet leaves the window on the compositor's choice rather than on none.
    screen: WindowScreen.forScreen(root.targetScreen)
    // A regular window: no `visibility` is assigned here. Setting a
    // non-windowed state makes a `Window` visible by itself, which is what
    // spawned this surface at shell startup before anything had opened it.
    // The size is a request the compositor may answer with a tile of its own;
    // the composition reads `content.width/height`, so any size lays out.
    width: Math.max(720, Math.round((screen ? screen.width : 1280) * 0.8))
    height: Math.max(480, Math.round((screen ? screen.height : 800) * 0.8))
    // Alpha belongs to the backdrop Rectangle inside, so the compositor sees a
    // translucent surface and the double-click density can change without a
    // remap.
    color: "transparent"

    // The hold retry is the window's child, not the holder's: `QtObject` has no
    // default property to put it in.
    Timer {
      id: holdRetry

      interval: 5000
      repeat: false
      onTriggered: if (root.inhibitWanted) root._holdStart()
    }

    // Fullscreen, or the manual caffeine button, stops the compositor marking
    // the session idle, which is what the idle daemon's lock and suspend rows
    // wait on. A plain window has no hold; the window association is what makes
    // a compositor respect the one that is active.
    IdleInhibitor {
      enabled: root.inhibitWanted
      window: root.win
    }

    // A toplevel is mapped unfocused and the keyboard is the compositor's to
    // give: `requestActivate` asks on the map and this moves the keys into the
    // transcript once they land. A layer surface got this from its
    // `keyboardFocus`; a window gets it from being the active one.
    // LYR-2: this is the ONE writer of active focus. `requestActivate` is the
    // activation request; the claim waits for the real active edge and is
    // re-checked inside the deferred lambda. `open()` makes no focus claim.
    onVisibleChanged: if (visible) Qt.callLater(function() { requestActivate() })
    onActiveChanged: {
      if (!active) return
      Qt.callLater(function() { if (root.opened) content.forceActiveFocus() })
    }

    // A platform close (titlebar X / Alt+F4) hides the Window without touching
    // `opened`. The next open() would then assign true to an already-true
    // property, so the `visible` binding never re-evaluates and the overlay
    // could only ever be shown once per shell process. Translate the close
    // into our own state change so the binding stays in charge of visibility.
    onClosing: root.close()

  // The transcript follows the shared playback clock the way the island does:
  // one tick while the client plays, plus the daemon's own notify. The pane
  // holds the clock only while it is open on a playing client, so a sheet left
  // closed runs no driver at all.
  PlaybackClockHold {
    wanted: root.opened && root.playing && !root._seeking && root.player !== null
  }

  Connections {
    target: PlaybackClock
    function onTick() { if (root.player) root.player.positionChanged() }
  }

  Connections {
    target: root.player
    // Some clients answer "Previous" on the first track by restarting it
    // without a new track identity. The stop/play edge re-reads the position
    // so the fill and the lyric cue go back to the head with the audio. No
    // local copy is written: shownPosition is still a binding on the player.
    function onPlaybackStateChanged() { if (root.player) root.player.positionChanged() }
    function onTrackChanged() { if (root.player) root.player.positionChanged() }
  }

  // Standby adopts the first usable client rather than waiting for another
  // menu trip. The menu path already hands in the active one when present.
  Connections {
    target: Core.MediaState

    function onActivePlayerChanged() {
      const p = Core.MediaState.activePlayer
      if (root.opened && root.standby && p !== null && p !== undefined) {
        root.player = p
      }
    }
  }



  Item {
    id: content

    anchors.fill: parent
    focus: root.opened

    // F toggles fullscreen, Esc returns a fullscreen window to tiled, Q
    // closes the window, Space toggles playback, Ctrl plus an arrow skips a
    // track and Shift plus an arrow steps a seek. Modifiers are masked so a
    // combined chord cannot be read as a plain key.
    Keys.onPressed: event => {
      const key = event.key
      const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier
        | Qt.AltModifier | Qt.MetaModifier)
      if (mods === Qt.NoModifier) {
        if (key === Qt.Key_Escape) {
          // Esc only leaves fullscreen; a tiled window stays as it is. Q is
          // the close verb, so no key can be read as both an exit and a mode
          // change by accident.
          if (root.fullscreen) root.toggleFullscreen()
          event.accepted = true
          return
        }
        if (key === Qt.Key_F) {
          root.toggleFullscreen()
          event.accepted = true
          return
        }
        if (key === Qt.Key_Q) {
          root.close()
          event.accepted = true
          return
        }
      }
      if (key === Qt.Key_Space) {
        if (mods !== Qt.NoModifier) return
        root.togglePlaying()
        event.accepted = true
        return
      }
      if (key !== Qt.Key_Left && key !== Qt.Key_Right) return

      if (mods === Qt.ShiftModifier) {
        root.commitSeek(root.shownPosition + (key === Qt.Key_Right ? 5 : -5))
        event.accepted = true
        return
      }
      if (mods !== Qt.ControlModifier || event.isAutoRepeat) return
      if (key === Qt.Key_Right) root.nextTrack()
      else root.previousTrack()
      event.accepted = true
    }

    // The surface's own backdrop, under everything else. See backdropColor for
    // why this is a Rectangle rather than the window's color.
    Rectangle {
      id: backdrop

      anchors.fill: parent
      color: root.backdropColor
    }

    // The window's own chrome, pinned to the top-left corner rather than the
    // content inset so it never crowds the artwork. All three hand keys back
    // after a click so Space keeps toggling playback instead of reactivating
    // a focused pad.
    Row {
      x: Ui.s
      y: Ui.s
      spacing: Ui.s / 2
      // Above standby, below the enlarged artwork: standby keeps the chrome
      // usable, while the artwork view dims it with the rest of the surface.
      z: 9

      IconButton {
        name: root.fullscreen ? "minimize" : "maximize"
        colorKey: root.fullscreen ? "accent" : "foreground_1"
        slotSize: content.chromeSlot
        iconSize: Math.max(16, Math.round(content.chromeSlot / 3))
        flat: true
        cornerRadius: RoundingPolicy.radius
        animationsEnabled: root.animOn
        onClicked: {
          root.toggleFullscreen()
          content.forceActiveFocus()
        }
      }

      IconButton {
        name: "hypr-blur"
        colorKey: root.backdropAlpha < 1 ? "accent" : "foreground_1"
        slotSize: content.chromeSlot
        iconSize: Math.max(16, Math.round(content.chromeSlot / 3))
        flat: true
        cornerRadius: RoundingPolicy.radius
        animationsEnabled: root.animOn
        onClicked: {
          root.toggleBackdrop()
          content.forceActiveFocus()
        }
      }

      IconButton {
        name: "caffeine"
        // The manual hold exists to hold back the idle daemon's timers; with
        // the daemon off there is nothing to hold back.
        enabled: Settings.idleEnabled
        colorKey: root.inhibitWanted ? "accent" : "foreground_1"
        slotSize: content.chromeSlot
        iconSize: Math.max(16, Math.round(content.chromeSlot / 3))
        flat: true
        cornerRadius: RoundingPolicy.radius
        animationsEnabled: root.animOn
        onClicked: {
          root.toggleInhibit()
          content.forceActiveFocus()
        }
      }
    }

    // Screen-relative margins: a 1080p output and a 3:2 laptop get the same
    // composition instead of the same pixel inset.
    readonly property real pad: Math.round(Range.clamp(
      Math.min(width, height) * 0.055, 16, 48))
    readonly property real gap: Math.round(Range.clamp(width * 0.035, 20, 64))
    readonly property real availW: Math.max(0, width - 2 * pad)
    readonly property real availH: Math.max(0, height - 2 * pad)
    // Cover column share. Capped by the available height so a short, wide
    // output does not hand the transcript a sliver.
    readonly property real coverW: Range.clamp(availH * 0.95, 120, availW * 0.42)
    // Transport pads fill the space between the cover and the lane, sized
    // from the cover column so the whole left group keeps one scale.
    readonly property real padSlot: Math.round(Range.clamp(coverW * 0.115, 48, 88))
    readonly property real padIcon: Math.round(padSlot * 0.5)
    // The top-left chrome is smaller than the transport pads so three slots
    // fit without cutting into the cover column.
    readonly property real chromeSlot: Math.round(Range.clamp(padSlot * 0.7, 32, 56))
    readonly property real timePx: Math.max(Ui.fontS, Math.round(Ui.fontS * 1.45))
    readonly property real progressH: Math.round(timePx * 1.6)
    readonly property real stackGap: Math.round(gap * 0.35)
    // The cover's own shape, so the box is exactly the painted image rather
    // than a square the artwork has to letterbox inside. A cover that has not
    // landed yet is treated as square, which is what the shipped art is.
    readonly property real artAspect: art.status === Image.Ready && art.implicitHeight > 0
      ? art.implicitWidth / art.implicitHeight : 1
    // The height available before the name block is deducted. It depends only
    // on fixed tokens, so type and pads can scale from the artwork's width
    // without feeding back into the cover's own size.
    readonly property real artBudgetH: Math.max(80,
      availH - chromeSlot - padSlot - progressH - 3 * stackGap)
    readonly property real artRefW: Range.clamp(artBudgetH * artAspect, 0, coverW)
      * artScale
    // Track and artist own one centred line each between the cover and the
    // lane; their type and the transport pads follow the artwork's width.
    readonly property real trackPx: Math.max(14,
      Math.min(Math.round(timePx * 1.45), Math.round(artRefW * 0.12)))
    readonly property real artistPx: Math.max(11,
      Math.min(timePx, Math.round(artRefW * 0.085)))
    readonly property real metaH: Math.round(trackPx * 1.3 + artistPx * 1.3 + 2)
    readonly property real artMaxH: Math.max(80, artBudgetH - metaH)
    // Presentation type: the pane's own base sizes multiplied, bounded so a
    // 4K output does not turn one cue into a headline.
    readonly property real lyricsScale: Range.clamp(availH / 460, 1.5, 3.2)
    readonly property real lyricsX: pad + coverW + gap
    readonly property real lyricsW: Math.max(0, width - lyricsX - pad)
    readonly property real emptyIcon: Math.round(Math.max(64,
      Math.min(lyricsW, availH) * 0.24))
    // The cover sits at 97.75% of the fit its column and height allow, which
    // is the size the transport and the seek lane are measured from.
    readonly property real artScale: 0.9775
    readonly property real coverBoxW: Range.clamp(artMaxH * artAspect, 0, coverW) * artScale
    readonly property real coverBoxH: artAspect > 0 ? coverBoxW / artAspect : coverBoxW
    readonly property real artBoxX: pad + Math.round((coverW - coverBoxW) / 2)
    // Five pads share the artwork's width, so they grow and shrink with it.
    readonly property int transportSlot: Math.round(Range.clamp(artRefW * 0.16, 32, padSlot))
    // Cover, names, lane and transport are one group centred in the column:
    // a short wide cover leaves no gap above the pads, and a tall one does not
    // push them off the bottom.
    readonly property real stackH: coverBoxH + metaH + progressH
      + transportSlot + 3 * stackGap
    readonly property real stackY: pad + chromeSlot
      + Math.max(0, Math.round((availH - chromeSlot - stackH) / 2))
    // The blur bands run from each screen edge past the artwork's top and
    // bottom edges, so they are taller than the cover's own level on the
    // transcript side. Fractions of the surface height, because the masks
    // below span the whole surface; the caps keep a sharp centre of at least
    // 20%.
    readonly property real blurTop: Math.min(0.40,
      content.stackY / Math.max(1, height) + 0.10)
    readonly property real blurBottom: Math.max(0.60,
      (content.stackY + content.coverBoxH) / Math.max(1, height) - 0.10)

    // One switch hides the whole player composition in standby. The surface
    // then only paints its backdrop and the standby answer, so a translucent
    // preference shows the desktop instead of a dead cover and transport.
    Item {
      anchors.fill: parent
      visible: !root.standby

      // Faint all-direction halo, declared before the frame so it paints behind
      // the cover instead of being clipped by it. The shadow tracks the cover's
      // own ratio-driven geometry through the shared host contract.
      SoftShadow {
        host: artFrame
        radius: 0
      }

      Rectangle {
        id: artFrame

        x: content.artBoxX
        y: content.stackY
        width: content.coverBoxW
        height: content.coverBoxH
        color: Ui.solid("background_1")
        border.width: 1
        border.color: Ui.tint("foreground_1", 0.25)
        clip: true

        // Settled cover: follows the url on its own, and retainWhileLoading
        // keeps the previous pixmap painted while the next one decodes, so a
        // track switch never blanks the frame.
        Image {
          id: art

          anchors.fill: parent
          visible: opacity > 0.01
          opacity: 0
          asynchronous: true
          cache: true
          retainWhileLoading: true
          fillMode: Image.PreserveAspectFit
          // One decode wide enough for the box. The height is left to the
          // loader so the source keeps its own aspect ratio.
          sourceSize.width: 1024

          // The settled layer takes a cover only when the incoming layer has
          // faded in over it (see artFade), never by following the url. A base
          // that followed the track would swap the frame the new cover decodes,
          // leaving the crossfade to fade an identical image over itself.
          onStatusChanged: {
            if (status === Image.Ready && root.artUrl !== "") {
              art.opacity = 1
              if (String(art.source) === root.artUrl) artNext.opacity = 0
            } else if (status === Image.Error) {
              art.opacity = 0
            }
          }
        }

        // Incoming cover: crossfades over the settled layer on a track change
        // instead of swapping the frame.
        Image {
          id: artNext

          anchors.fill: parent
          visible: opacity > 0.01
          opacity: 0
          asynchronous: true
          cache: true
          fillMode: Image.PreserveAspectFit
          sourceSize.width: 1024

          onStatusChanged: {
            if (status === Image.Ready && String(artNext.source) === root.artUrl
              && root.artUrl !== "") artFade.restart()
          }
        }

        NumberAnimation {
          id: artFade

          target: artNext
          property: "opacity"
          from: 0
          to: 1
          duration: MotionPolicy.duration(Ui.slowMs)
          easing.type: Easing.InOutCubic
          onFinished: {
            if (String(artNext.source) !== root.artUrl) return
            // Commit the cover to the settled layer now, but keep the incoming
            // layer up until the base reports it ready: hiding it here would
            // expose the retained old pixmap for the frames the base decodes.
            art.source = root.artUrl
          }
        }

        // No cover for this client: the same glyph the island's empty frame
        // uses, scaled to the box.
        Icon {
          anchors.centerIn: parent
          visible: art.opacity <= 0.01 && artNext.opacity <= 0.01
          name: "eighth-note"
          colorKey: "foreground_1"
          size: Math.round(Math.min(artFrame.width, artFrame.height) * 0.4)
        }

        // The cover is the entrance to the enlarged view. Kept over both image
        // layers so a click reaches it regardless of which one is settled.
        MouseArea {
          anchors.fill: parent
          cursorShape: root.artUrl !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: root.toggleArtExpanded()
        }
      }

      // The recording's own name, one centred line each, directly under the
      // cover. An empty field keeps its line so the lane below never jumps.
      Column {
        x: content.artBoxX
        y: content.stackY + content.coverBoxH + content.stackGap
        width: content.coverBoxW
        spacing: 2

        // The same marquee the bar island uses: a title that overflows its
        // column eases out and back instead of losing its tail. Its own gate is
        // the window's visibility, never MotionPolicy - the reading aid has to
        // keep working when shell motion is switched off.
        ScrollLabel {
          width: parent.width
          height: implicitHeight
          scrolling: root.opened
          startPauseMs: 0
          text: root.title
          color: Ui.tint("foreground_0", 0.95)
          fontSize: content.trackPx
          fontFamily: Ui.fontFamily
          fontBold: true
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          opticalCenter: false
        }

        ScrollLabel {
          width: parent.width
          height: implicitHeight
          scrolling: root.opened
          startPauseMs: 0
          text: root.artist
          color: Ui.tint("foreground_1", 0.7)
          fontSize: content.artistPx
          fontFamily: Ui.fontFamily
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          opticalCenter: false
        }
      }

      // Transport: previous, play/pause, next - centred under the cover at a
      // size that belongs on this surface rather than in the bar.
      Row {

        x: content.artBoxX + Math.round((content.coverBoxW - width) / 2)
        y: content.stackY + content.coverBoxH + content.stackGap
          + content.metaH + content.stackGap + content.progressH + content.stackGap
        width: 5 * content.transportSlot
          + 4 * Math.round(content.transportSlot * 0.22)
        height: content.transportSlot
        spacing: Math.round(content.transportSlot * 0.22)

        Core.PlayerModePad {
          player: root.player
          mode: "shuffle"
          slotSize: content.transportSlot
          iconSize: Math.round(content.transportSlot * 0.5)
          animationsEnabled: root.animOn
          onActivated: content.forceActiveFocus()
        }

        IconButton {
          name: "skip-back"
          iconSize: Math.round(content.transportSlot * 0.5)
          slotSize: content.transportSlot
          flat: true
          cornerRadius: RoundingPolicy.radius
          animationsEnabled: root.animOn
          actionable: root.hasTrack && root.player?.canGoPrevious !== false
          opacity: root.hasTrack ? 1 : 0.4
          onClicked: {
            root.previousTrack()
            // A clicked button keeps focus and would consume Space itself;
            // hand keys back so Space still toggles playback.
            content.forceActiveFocus()
          }
        }

        IconButton {
          // The glyph lives in the CrossfadeIcon below; the button keeps its
          // native chrome and interaction with no icon of its own.
          slotSize: content.transportSlot
          flat: true
          cornerRadius: RoundingPolicy.radius
          animationsEnabled: root.animOn
          actionable: root.canTogglePlaying
          opacity: root.canTogglePlaying ? 1 : 0.4
          onClicked: {
            root.togglePlaying()
            content.forceActiveFocus()
          }

          // Same transport slide-fade as the bar module: play arrives from the
          // right, pause from the left, and each glyph leaves the way its
          // counterpart came from. The slot is clipped so the travel stays
          // inside the pad.
          Item {
            anchors.fill: parent
            clip: true

            CrossfadeIcon {
              anchors.centerIn: parent
              name: root.playing ? "pause" : "play"
              colorKey: "foreground_0"
              size: Math.round(content.transportSlot * 0.5)
              slideX: Ui.s
              durationMs: Ui.slowMs
              fadeEasing: Easing.OutCubic
              directionFor: glyph => glyph === "play" ? 1 : -1
            }
          }
        }

        IconButton {
          name: "skip-forward"
          iconSize: Math.round(content.transportSlot * 0.5)
          slotSize: content.transportSlot
          flat: true
          cornerRadius: RoundingPolicy.radius
          animationsEnabled: root.animOn
          actionable: root.hasTrack && root.player?.canGoNext !== false
          opacity: root.hasTrack ? 1 : 0.4
          onClicked: {
            root.nextTrack()
            content.forceActiveFocus()
          }
        }

        Core.PlayerModePad {
          player: root.player
          mode: "loop"
          slotSize: content.transportSlot
          iconSize: Math.round(content.transportSlot * 0.5)
          animationsEnabled: root.animOn
          onActivated: content.forceActiveFocus()
        }
      }

      // Elapsed, seek lane, total: the island's lane contract under the two
      // name lines,
      // at presentation scale. The block is 70% of the artwork's width and
      // centred on it, which leaves ~15% of free space on each side.
      Item {
        id: progressBlock

        x: content.artBoxX + Math.round((content.coverBoxW - width) / 2)
        y: content.stackY + content.coverBoxH + content.stackGap
          + content.metaH + content.stackGap
        width: Math.round(content.coverBoxW * 0.7)
        height: content.progressH

        TextMetrics {
          id: timeMetrics

          font.family: Ui.fontFamily
          font.pixelSize: content.timePx
          text: root.lengthSec > 0 ? NP.fmtTime(root.lengthSec, root.lengthSec) : "--:--"
        }

        readonly property real timeW: Math.ceil(timeMetrics.advanceWidth)

        Row {
          id: laneRow

          width: parent.width
          height: Math.round(content.timePx * 1.4)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Ui.s

          Text {
            width: progressBlock.timeW
            anchors.verticalCenter: parent.verticalCenter
            text: root.lengthSec > 0 ? NP.fmtTime(root.shownPosition, root.lengthSec) : "--:--"
            color: Ui.tint("foreground_1", 0.7)
            font.pixelSize: content.timePx
            font.family: Ui.fontFamily
            textFormat: Text.PlainText
            elide: Text.ElideRight
          }

          Item {

            width: Math.max(0, progressBlock.width - 2 * progressBlock.timeW - 2 * laneRow.spacing)
            height: laneRow.height
            anchors.verticalCenter: parent.verticalCenter
            opacity: root.canSeekPosition ? 1 : 0.5

            Behavior on opacity {
              enabled: root.animOn
              NumberAnimation {
                duration: Ui.fastMs
                easing.type: Easing.OutCubic
              }
            }

            Rectangle {
              width: parent.width
              height: 8
              anchors.verticalCenter: parent.verticalCenter
              color: Ui.tint("foreground_1", 0.25)

              Rectangle {
                width: parent.width * root.progressRatio
                height: parent.height
                // Paused, the fill steps back to a tint: the elapsed share is
                // still legible, but it no longer reads as time advancing.
                color: root.playing ? Ui.solid("accent") : Ui.tint("accent", 0.55)

                Behavior on color {
                  enabled: root.animOn
                  ColorAnimation {
                    duration: Ui.normalMs
                    easing.type: Easing.OutCubic
                  }
                }

                // The width follows the clock directly. A Behavior here
                // restarted its tween on every position tick and could never
                // reach the target, leaving the fill empty.
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: root.canSeekPosition ? Qt.PointingHandCursor : Qt.ForbiddenCursor
              onPressed: mouse => {
                if (!root.canSeekPosition) return
                root._pressX = mouse.x
              }
              onPositionChanged: mouse => {
                if (!root.canSeekPosition || !pressed) return
                if (Math.abs(mouse.x - root._pressX) > 6) {
                  root._seeking = true
                  root.scrubTo(mouse.x, width)
                }
              }
              onReleased: mouse => {
                if (root._seeking) root.commitSeek(root.shownPosition)
                else root.seekAt(mouse.x, width)
                root._seeking = false
              }
              onCanceled: root._seeking = false
            }

            WheelHandler {
              acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
              onWheel: event => {
                if (event.angleDelta.y === 0) return
                if (!root.canSeekPosition) return
                const d = event.angleDelta.y > 0 ? 5 : -5
                root.commitSeek(root.shownPosition + d)
                event.accepted = true
              }
            }
          }

          Text {
            width: progressBlock.timeW
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignRight
            text: root.lengthSec > 0 ? NP.fmtTime(root.lengthSec, root.lengthSec) : "--:--"
            color: Ui.tint("foreground_1", 0.7)
            font.pixelSize: content.timePx
            font.family: Ui.fontFamily
            textFormat: Text.PlainText
            elide: Text.ElideRight
          }
        }
      }

      // The transcript is not a box beside the cover: it runs the full height of
      // the screen, so the cue under the playhead stays centred while the lines
      // above and below it reach the edges.
      Item {
        id: lyricsSide

        x: content.lyricsX
        y: 0
        width: content.lyricsW
        height: content.height
        // Track-switch entrance: the transcript fades in place while the cover
        // crossfades, so a switch reads as one new track rather than one
        // element swapping. Derived from the swap scalar, not written by the
        // animation: the four effect copies below read this one live value, and
        // an interrupted swap can never leave it stuck at zero.
        opacity: root.opened ? root.swapK : 0

        LyricsPane {
          id: pane

          anchors.fill: parent
          // The pane answers "no lyrics" in one small line of its own; an empty
          // state above it says the same thing at presentation scale. With a
          // translucent backdrop that line would read through the cover, so the
          // pane steps out of the way while a cover is over it.
          //
          // A ready transcript is painted by the effect passes below: the pane
          // is their capture source, kept at zero opacity so the sharp and
          // blurred copies are the only transcript on screen. Zero (not
          // invisible): the item still renders for the capture, with its input
          // handlers off. Loading and error text stay on the pane itself.
          opacity: pane.ready ? 0 : (pane.status === "none" || !root.hasTrack ? 0 : 1)
          // The placeholder carries its own fade, but this host hides the whole
          // pane on an answer: without a tween here "Getting lyrics..." leaves
          // on the frame the sheet arrives instead of fading with it.
          Behavior on opacity {
            enabled: root.animOn
            NumberAnimation {
              duration: Ui.fastMs
              easing.type: Easing.OutCubic
            }
          }
          player: root.player
          position: root.shownPosition
          active: root.opened
          playing: root.playing
          // A presentation surface is autonomous: the clock owns the
          // transcript and the one gate takes every reader gesture away from
          // it. Seeking stays on the transport lane, not on the words.
          interactive: false
          textScale: content.lyricsScale
          onSeekRequested: seconds => root.seekTo(seconds)
        }

        // The pane's own empty state is one line of text. The surface says it
        // at presentation scale instead; the pane stays
        // underneath so its fetch and cache states are unchanged. An idle
        // client has its own surface-level answer below, and its "none" status
        // is not an answer about lyrics, so this block stays out of the way
        // there rather than stacking two centred messages on one spot.
        Rectangle {
          anchors.fill: parent
          visible: root.hasTrack && pane.status === "none"
          color: root.emptyStateColor

          Column {
            anchors.centerIn: parent
            width: parent.width
            spacing: Ui.l

            Icon {
              anchors.horizontalCenter: parent.horizontalCenter
              name: "eighth-note"
              colorKey: "foreground_1"
              size: content.emptyIcon
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "No lyrics available"
              color: Ui.tint("foreground_1", 0.7)
              font.pixelSize: Math.round(Ui.fontM * Math.min(2, content.lyricsScale))
              font.family: Ui.fontFamily
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
            }
          }
        }

        // Nothing queued at all: the client is alive with an empty playlist or
        // stopped on nothing. It outranks the lyrics answer, which reads "none"
        // for a track that no longer exists.
        Rectangle {
          anchors.fill: parent
          visible: !root.hasTrack
          color: root.emptyStateColor

          Column {
            anchors.centerIn: parent
            width: parent.width
            spacing: Ui.l

            Icon {
              anchors.horizontalCenter: parent.horizontalCenter
              name: "eighth-note"
              colorKey: "foreground_1"
              size: content.emptyIcon
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Nothing playing"
              color: Ui.tint("foreground_1", 0.7)
              font.pixelSize: Math.round(Ui.fontM * Math.min(2, content.lyricsScale))
              font.family: Ui.fontFamily
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
            }
          }
        }

        Connections {
          target: pane

          function onTrackKeyChanged() {
            if (root.opened) trackSwap.restart()
          }
        }
      }

      // Edge blur: the transcript is painted from the pane (its capture source,
      // see its opacity) in four passes. The sharp copy fills the centre; the
      // three blurred copies stack toward each screen edge with a different
      // radius, each masked to a shorter band than the one below it. The result
      // is a gradient of blur strength: light where the transcript meets the
      // sharp centre, heavy at the edge, with no sharp text left underneath.
      // The masks are the house MultiEffect idiom: hidden rectangles whose
      // alpha ramps, softened by the threshold spread.
      MultiEffect {

        anchors.fill: lyricsSide
        visible: root.opened && pane.ready
        opacity: lyricsSide.opacity
        source: pane
        autoPaddingEnabled: false
        maskEnabled: true
        maskSource: lyricsSharpMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.5
      }

      MultiEffect {

        anchors.fill: lyricsSide
        visible: root.opened && pane.ready
        opacity: lyricsSide.opacity
        source: pane
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 0.3
        blurMax: 32
        maskEnabled: true
        maskSource: lyricsBlurLightMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.5
      }

      MultiEffect {

        anchors.fill: lyricsSide
        visible: root.opened && pane.ready
        opacity: lyricsSide.opacity
        source: pane
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 0.6
        blurMax: 32
        maskEnabled: true
        maskSource: lyricsBlurMediumMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.5
      }

      MultiEffect {

        anchors.fill: lyricsSide
        visible: root.opened && pane.ready
        opacity: lyricsSide.opacity
        source: pane
        autoPaddingEnabled: false
        blurEnabled: true
        blur: 0.95
        blurMax: 32
        maskEnabled: true
        maskSource: lyricsBlurHeavyMask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 0.5
      }

      // Sharp centre: full between the bands, gone where the light blur takes
      // over.
      Rectangle {
        id: lyricsSharpMask

        anchors.fill: lyricsSide
        visible: false
        layer.enabled: true
        layer.smooth: true

        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurTop * 0.7; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurTop; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurBottom; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurBottom + (1 - content.blurBottom) * 0.3; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
        }
      }

      // Light blur: the whole band, handing over from the sharp copy.
      Rectangle {
        id: lyricsBlurLightMask

        anchors.fill: lyricsSide
        visible: false
        layer.enabled: true
        layer.smooth: true

        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurTop * 0.7; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurTop; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurBottom; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurBottom + (1 - content.blurBottom) * 0.3; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 1) }
        }
      }

      // Medium blur: the outer two-thirds of the band.
      Rectangle {
        id: lyricsBlurMediumMask

        anchors.fill: lyricsSide
        visible: false
        layer.enabled: true
        layer.smooth: true

        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurTop * 0.3; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurTop * 0.65; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurBottom + (1 - content.blurBottom) * 0.35; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurBottom + (1 - content.blurBottom) * 0.7; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 1) }
        }
      }

      // Heavy blur: the outer edge, where the transcript leaves the screen.
      Rectangle {
        id: lyricsBlurHeavyMask

        anchors.fill: lyricsSide
        visible: false
        layer.enabled: true
        layer.smooth: true

        gradient: Gradient {
          GradientStop { position: 0; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurTop * 0.12; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: content.blurTop * 0.45; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurBottom + (1 - content.blurBottom) * 0.55; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: content.blurBottom + (1 - content.blurBottom) * 0.88; color: Qt.rgba(1, 1, 1, 1) }
          GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 1) }
        }
      }

      // The fade itself. The script leg clears the transcript in place; the
      // short hold makes it read as a fade rather than a frame that happened to
      // be dim. Both legs write the one swapK scalar, and lyricsSide.opacity is
      // derived from it, so an interrupted animation leaves no stale value on
      // the item. With motion off nothing is staged and the tween is
      // zero-length, so the swap is a single frame.
      SequentialAnimation {
        id: trackSwap

        ScriptAction {
          script: {
            if (!root.animOn) return
            root.swapK = 0
          }
        }
        PauseAnimation {
          duration: root.animOn ? 60 : 0
        }
        NumberAnimation {
          target: root
          property: "swapK"
          to: 1
          duration: MotionPolicy.duration(Ui.slowMs)
          easing.type: Easing.InOutCubic
        }
      }

    }

    // Artwork-only view: a cover click fades this over the whole surface. The
    // image keeps its own aspect ratio and fits inside the window with the
    // same screen-relative padding as the composition, so a portrait or wide
    // cover scales up without cropping. A click goes back to the transcript.
    // The overlay is the last child so it paints over the lyrics,
    // their effect passes and the transport.
    Rectangle {
      id: artView

      anchors.fill: parent
      color: root.backdropColor
      opacity: root.artExpanded ? 1 : 0
      visible: opacity > 0.01
      z: 10

      Behavior on opacity {
        enabled: root.animOn
        NumberAnimation {
          duration: Ui.normalMs
          easing.type: Easing.InOutCubic
        }
      }

      Image {
        anchors.fill: parent
        anchors.margins: content.pad
        source: root.artUrl
        asynchronous: true
        cache: true
        retainWhileLoading: true
        fillMode: Image.PreserveAspectFit
        sourceSize.width: 2048
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.artExpanded = false
      }
    }

    // Standby: no MPRIS client at all. A full-surface answer rather than the
    // right-half "Nothing playing" block, so no dead cover, lane or transport
    // is left behind. The corner chrome stays above it.
    Rectangle {
      anchors.fill: parent
      // The composition is hidden in standby, so this only has to repeat the
      // surface backdrop: transparent when the dim preference is on.
      color: root.emptyStateColor
      visible: root.standby
      z: 8

      Column {
        anchors.centerIn: parent
        width: parent.width
        spacing: Ui.l

        Icon {
          anchors.horizontalCenter: parent.horizontalCenter
          name: "eighth-note"
          colorKey: "foreground_1"
          size: content.emptyIcon
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "Waiting for a player"
          color: Ui.tint("foreground_1", 0.7)
          font.pixelSize: Math.round(Ui.fontM * Math.min(2, content.lyricsScale))
          font.family: Ui.fontFamily
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
        }
      }
    }
  }
  }
}
