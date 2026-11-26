pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell.Services.Mpris
import qs.common
import qs.services as Core
import qs.features.bar
import "../../../../common/NowPlaying.js" as NP
import "../../../../common/capture/ShotLib.js" as ShotLib
import "../../../../common/text/Format.js" as Format
import qs.features.bar.control

// Now Playing bar module (opt-in, off by default). Shows the active
// MPRIS track title in the bar; left click opens the island, right click
// toggles play/pause, and middle click likes the current track when the
// active client has a like action (otherwise it toggles play/pause too).
// Player pick:
// a playing client keeps the slot, a silent one hands it to the head
// while anything is playing, and an all-paused set keeps the last-used
// player instead of falling back to slot 0.
CollapsibleSlot {
  id: root

  readonly property bool blockBrowsers: Settings.value("shell.osd.blockBrowsers") !== false
  // The MPRIS set, named once. `Mpris.players` is a model that is briefly
  // absent while the bus is still answering, and `values` is briefly absent
  // on the model itself; Ui.trackerValues owns that two-step fold so the
  // branch below cannot filter one set and sort another.
  readonly property var allPlayers: Ui.trackerValues(Mpris.players)
  readonly property var players: NP.sortPlayers(
    root.blockBrowsers ? NP.filterBrowsers(root.allPlayers) : root.allPlayers,
    p => p.playbackState === MprisPlaybackState.Playing)
  property int playerIndex: 0
  readonly property var player: root.players.length > 0
    ? root.players[Math.min(root.playerIndex, root.players.length - 1)] ?? null
    : null
  readonly property string title: root.player !== null ? NP.displayText(root.player.trackTitle) : ""
  readonly property string artist: root.player !== null ? NP.displayText(root.player.trackArtist) : ""
  readonly property string album: root.player !== null ? NP.displayText(root.player.trackAlbum) : ""
  // The module is here for a registered client, whatever that client is
  // doing: the pill is the click target for the island, and a paused or idle
  // player is precisely what the island is there to be resumed from.
  // `hasTrack` is the narrower question - is there a name worth showing - and
  // it picks placeholders and the title reveal, not whether the slot is up.
  readonly property bool hasClient: root.player !== null
  readonly property bool hasTrack: root.hasClient && root.title !== ""
  readonly property bool playing: root.player !== null && root.player.playbackState === MprisPlaybackState.Playing
  // Transport flash: on (un)pause the bar icon slide-fades from the
  // default album glyph to the direction it moved (play on resume, pause
  // on pause), holds 1s, then slide-fades back. A like reuses the same
  // flash with the heart (added) or heart-off (removed) glyph. The hold is
  // a dwell, not motion, so it is not gated by MotionPolicy.
  property string transportIcon: ""
  property bool _transportSeeded: false
  Timer {
    id: transportTimer

    interval: 1000
    repeat: false
    onTriggered: root._flashTransport("")
  }
  // One writer for the glyph and its dwell: a named icon opens the hold, an
  // empty one releases it. A handler that loses its client goes through the
  // same function instead of clearing the property and stopping the timer on
  // its own, so the two cannot disagree about who ended the flash.
  function _flashTransport(icon) {
    root.transportIcon = icon
    if (icon === "") transportTimer.stop()
    else transportTimer.restart()
  }
  onPlayingChanged: {
    if (!root._transportSeeded) return
    if (!root.hasClient) {
      root._flashTransport("")
      return
    }
    root._flashTransport(root.playing ? "play" : "pause")
  }
  onHasClientChanged: {
    if (!root.hasClient) root._flashTransport("")
  }
  // Whether the active player takes a volume write at all. MPRIS cannot
  // say, and a browser client declares Volume and drops the write, so the
  // media service round-trips it; see its volume section. Bound here as
  // well as in the island so the answer is already settled by the time the
  // island opens.
  readonly property bool canSetVolume: Core.MediaState.volumeCapable(root.player)
  // A like action is not part of MPRIS; it is a per-client capability. The
  // bar offers it only for the client whose like shortcut the shell knows,
  // and only while there is a track to like.
  readonly property bool canLike: root.hasTrack && NP.canLikePlayer(root.player)
  readonly property bool shown: root.hasClient
  // Read the host at trigger time: a property binding on the host can lag the
  // open, and an anchor check can miss the island while the bar is already
  // hosting another card. Any open island owns the bar, so the track flash
  // waits until it closes.
  function _islandOpen(): bool {
    const host = root.barWindow ? root.barWindow.islandHost : null
    return !!host && host.open
  }

  // Title text switch (shell.statusbar.nowPlayingTitle, default
  // off): on shows the title next to the icon, off collapses the
  // pill to the bare icon slot. The track-change flash
  // (shell.statusbar.nowPlayingFlash, default on) reveals the name
  // either way.
  readonly property bool showTitle: Settings.value("shell.statusbar.nowPlayingTitle") === true
  readonly property bool flashEnabled: Settings.value("shell.statusbar.nowPlayingFlash") !== false
  // The reveal window is the shared one, so the clock owns `active` and no
  // handler keeps a second copy of it. The track observer already seeds on
  // the first track, so this instance opts out of the reveal's backend settle
  // gate: that gate would swallow a real next/prev in the first seconds
  // after the bar loads.
  FlashReveal {
    id: nameFlash

    settled: true
  }
  readonly property bool flashActive: nameFlash.active
  readonly property string trackKey: root.player !== null ? NP.playerKey(root.player) : ""
  property bool _trackSeeded: false
  property string _lastTrackKey: ""
  property bool _trackObserveQueued: false
  readonly property string artUrl: root.player !== null ? root.player.trackArtUrl ?? "" : ""

  function _queueTrackObservation() {
    if (root._trackObserveQueued) return
    root._trackObserveQueued = true
    Qt.callLater(root._observeTrack)
  }

  function _observeTrack() {
    root._trackObserveQueued = false
    if (!root.hasTrack) {
      root._trackSeeded = false
      root._lastTrackKey = ""
      root._stopFlash()
      return
    }
    const key = root.trackKey
    if (key === "") return
    if (!root._trackSeeded) {
      root._lastTrackKey = key
      root._trackSeeded = true
      return
    }
    if (key === root._lastTrackKey) return
    root._lastTrackKey = key
    if (root.flashEnabled) root._fireFlash(key)
  }

  // Track-name flash: reveals the title for 3s on a track change. The
  // icon is untouched by it - only (un)pause swaps the glyph (play on
  // resume, pause on pause, album otherwise), so next/previous never
  // change what the slot shows.
  function _startFlash() {
    if (!root.flashEnabled || !root.hasTrack) return
    if (root._islandOpen()) {
      root._stopFlash()
      return
    }
    nameFlash.pulse()
  }

  // Fullscreen defer, the Network/Bluetooth convention: a track announced
  // while a fullscreen window owns this screen must not expand the bar over
  // the content. The event itself is parked, not just a flag: a newer
  // next/prev replaces the held event, so a burst leaves only the last one.
  // Its payload is a track key, not a title snapshot - the reveal still reads
  // the live name, and a held key that no longer names the active track is
  // stale and gets dropped on replay.
  property var _flashPendingEvent: null
  readonly property bool _flashPending: root._flashPendingEvent !== null
  function _parkFlash(key) {
    const held = root._flashPendingEvent
    if (key === null && held === null) return
    root._flashPendingEvent = key === null ? null : { key: key }
  }

  function _fireFlash(key) {
    if (root.fullscreenActive) {
      root._parkFlash(key)
      return
    }
    root._startFlash()
  }

  // IPC's explicit track flash. It never observes the track or updates a
  // track key; it shares the gate so an explicit announcement parks the same
  // event an automatic one does.
  function ipcTrigger(name) {
    if (name !== "flashTrack") return false
    root._fireFlash(root.trackKey)
    return true
  }

  function _stopFlash() {
    nameFlash.clear()
  }

  onTrackKeyChanged: root._queueTrackObservation()
  onTitleChanged: {
    root._queueTrackObservation()
    // A title landing while the name is up is a mid-flash swap:
    // kick it. An opening flash skips this (titleSlide is still 0)
    // and rides the width reveal instead.
    if (root.titleSlide > 0 && !root._islandOpen()) labelText.kickName()
  }
  onArtistChanged: root._queueTrackObservation()
  onAlbumChanged: root._queueTrackObservation()
  onHasTrackChanged: {
    if (!root.hasTrack) {
      root._stopFlash()
      root._parkFlash(null)
    }
  }
  onFlashEnabledChanged: {
    if (!root.flashEnabled) {
      root._stopFlash()
      root._parkFlash(null)
    }
  }
  onFullscreenActiveChanged: {
    if (root.fullscreenActive) {
      // Entering fullscreen with a flash up: park the event and take the
      // reveal off screen instead of running it under the fullscreen window.
      if (root.flashActive) {
        root._parkFlash(root.trackKey)
        root._stopFlash()
      }
      return
    }
    if (root._flashPending) {
      const key = root._flashPendingEvent.key
      root._parkFlash(null)
      if (key === root.trackKey) root._startFlash()
    }
  }
  // Opening an island shows the track there, so a flash already running ends
  // with the open rather than playing out behind the card.
  Connections {
    target: root.barWindow ? root.barWindow.islandHost : null

    function onOpenChanged() {
      if (root._islandOpen()) root._stopFlash()
    }
  }
  Component.onCompleted: {
    root._transportSeeded = true
    root._queueTrackObservation()
  }

  // Previous sorted view, kept so a regroup can re-point playerIndex at the
  // same player instead of whatever lands on slot 0.
  property var _lastPlayers: []

  // The pill follows the active client on every regroup
  // (`NP.pickPlayerIndex`), while the island card holds until its next open:
  // the island settles its card once, when it opens, and keeps it for as long
  // as it stays open, so a regroup must not hand the card to another client.
  onPlayersChanged: {
    const next = NP.pickPlayerIndex(root._lastPlayers, root.players, root.playerIndex,
      p => p.playbackState === MprisPlaybackState.Playing)
    root._lastPlayers = root.players
    if (next === root.playerIndex) return
    root.playerIndex = next
  }

  // Collapsible slot (see CollapsibleSlot.qml). Title reveal (second
  // axis, local): 1 with title, 0 icon-only. The inset rides inside the
  // animated width so both rest states land exact (Weather icon-only
  // contract). A client with nothing loaded has no title to reveal, so it
  // lands on the bare slot rather than reserving room for empty text.
  collapseShown: root.shown
  collapseFull: root.titleSlide > 0 ? pill.width : BarControl.iconSlot
  // The reveal is the pill's one open/close clock. The name swap is a second
  // scalar folded into the same width expression, not a width Behavior:
  // gating a width chase on titleSlide === 1 made the close freeze and the
  // snap land at the end. nameWidth binds the live label extent, so a spammed
  // next/prev retargets the one width binding at each swap.
  property real titleSlide: root.hasTrack && (root.showTitle || root.flashActive) ? 1 : 0
  Behavior on titleSlide {
    Glide { duration: Ui.slowMs }
  }
  property real nameWidth: Math.min(labelText.implicitWidth, 240)
  Behavior on nameWidth {
    Glide { duration: Ui.fastMs }
  }

  // Icon + title pill (the Weather module boxing): the slot's own
  // inset all lands on the trailing text edge.
  Item {
    id: pill

    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: BarControl.iconSlot + root.titleSlide * (root.nameWidth + 4 + BarControl.slotInset)
    height: root.height
    // clip keeps the sliding name inside the slot while nameWidth catches
    // up. The bar.iconSlot base keeps collapseFull continuous when the
    // flash closes (pill settles exactly onto the icon-only width).
    clip: true

    // Transport slide-fade: the shared CrossfadeIcon trades the two glyphs
    // in one fixed, clipped slot. Play arrives from the right, pause from
    // the left, and the return mirrors the last direction, so the album
    // glyph comes back from the side the action glyph is leaving toward.
    // The wrapper docks left so the label anchors to a stable right edge;
    // clip keeps the travel inside the slot so neighbours never see it.
    Item {
      id: trackIcon

      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: BarControl.iconSlot
      height: parent.height
      clip: true

      // Pause/play and the like confirmation share this glyph: a track
      // change only reveals the title beside the album glyph, and the
      // 1s flash then hands the slot back to the album.
      readonly property string currentName: root.transportIcon !== "" ? root.transportIcon : "music-album"
      // Travel of the incoming glyph: +1 arrives from the right (play),
      // -1 from the left (pause); the trip home mirrors the last one.
      property int slideDir: 1

      // Two-tone like glyphs: the added heart is red whole, while the
      // removed heart keeps the body tone and lets its slash carry the red
      // (heart-off marks only that path as class="indicator"). Every other
      // transport glyph stays in the regular foreground tone. The resolver
      // runs at swap time, so each layer keeps its own tone while it fades.
      function toneFor(glyph) {
        return glyph === "heart" ? "red" : "foreground_0"
      }
      function accentFor(glyph) {
        return glyph === "heart-off" ? "red" : ""
      }
      function directionFor(glyph) {
        if (glyph === "play") trackIcon.slideDir = 1
        else if (glyph === "pause") trackIcon.slideDir = -1
        else trackIcon.slideDir = -trackIcon.slideDir
        return trackIcon.slideDir
      }

      CrossfadeIcon {
        anchors.centerIn: parent
        name: trackIcon.currentName
        colorFor: glyph => trackIcon.toneFor(glyph)
        accentFor: glyph => trackIcon.accentFor(glyph)
        directionFor: glyph => trackIcon.directionFor(glyph)
        slideX: Ui.s
        durationMs: Ui.slowMs
        fadeEasing: Easing.OutCubic
      }
    }

    Title {
      id: labelText

      anchors.left: trackIcon.right
      anchors.leftMargin: 4
      anchors.verticalCenter: parent.verticalCenter
      visible: root.titleSlide > 0
      level: 3
      width: Math.min(implicitWidth, 240)
      font.pixelSize: BarControl.pillFontSize
      text: root.title
      elide: Text.ElideRight
      // Shift composes with the anchors, so the slide below never
      // fights the layout the way animating x would.
      transform: Translate { id: nameShift }

      // Mid-flash title swap: slide-fade the new name in, the island's
      // kickMeta language, so a name arriving while the flash is up
      // reads as motion instead of a jump.
      function kickName() {
        // labelText.text and nameWidth both bind live values - root.title and
        // its implicit width. The kick rides the name on screen at this edge,
        // never a title snapshotted when the flash opened, so a spammed
        // next/prev retargets the same width binding each time.
        if (root.title === "") return
        if (MotionPolicy.enabled) {
          nameSlide.restart()
          nameFade.restart()
        } else {
          nameShift.x = 0
          labelText.opacity = 1
        }
      }
    }

    NumberAnimation {
      id: nameSlide

      target: nameShift
      property: "x"
      from: 24
      to: 0
      duration: Ui.fastMs
      easing.type: Easing.OutCubic
    }

    NumberAnimation {
      id: nameFade

      target: labelText
      property: "opacity"
      from: 0
      to: 1
      duration: Ui.fastMs
      easing.type: Easing.OutCubic
    }
  }

  // Spotify's own Save/Remove shortcut. The MPRIS bus has no like method, so
  // the action is delivered to the client's window the same way the user
  // would: a key press targeted by window class, with no focus switch. The
  // dispatch is fire-and-forget because the player publishes no state to
  // read back; the flash is the optimistic confirmation.
  function _sendLikeShortcut() {
    Exec.run(["hyprctl", "-q", "eval", NP.likeShortcutScript()])
  }

  // Click contract: left opens the island; middle likes the track when the
  // active client has a like action and otherwise toggles transport; right
  // always toggles transport. `canTogglePlaying` is a declaration a client
  // can publish false, so a client that opts out of Playback/Pause swallows
  // the transport press instead of taking it and doing nothing.
  fillButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.MiddleButton && root.canLike) {
      const liked = NP.toggleLiked(root.player)
      root._flashTransport(liked ? "heart" : "heart-off")
      root._sendLikeShortcut()
      return
    }
    if (mouse.button === Qt.MiddleButton || mouse.button === Qt.RightButton) {
      // A client that publishes canTogglePlaying=false swallows the press: the
      // shell behaved correctly and the pad is inert because the client said so.
      if (!root.player || root.player.canTogglePlaying === false) return
      // Optimistic swap: players report Pause late (fade-out and teardown
      // before the signal), so prime the flash from the pre-toggle state
      // instead of waiting for the round trip. Idempotent: onPlayingChanged
      // re-asserts the same value when the signal lands, and the 1s hold
      // self-corrects if the toggle failed.
      root._flashTransport(root.playing ? "pause" : "play")
      root.player.togglePlaying()
      return
    }
    root.openIsland()
  }

  // Icon rows (the Printers convention): track/artist/album plus the
  // player volume so scroll feedback reads without opening the island.
  // Missing fields render as icon + "--" per contract.
  readonly property var tipLines: [
    { icon: "music-track", text: root.title !== "" ? root.title : "--" },
    { icon: "music-artist", text: root.artist !== "" ? root.artist : "--" },
    { icon: "music-album", text: root.album !== "" ? root.album : "--" },
    // MPRIS -1 means "unknown": Format.percent would print -100%, which
    // contradicts the island's muted-style fill and the gate every writer
    // uses. Read the same normalized level, and show "--" when there is no
    // level to report at all.
    { icon: "volume-max", text: root.player !== null && NP.volumeKnown(root.player.volume)
      ? Format.percent(NP.normalizeVolume(root.player.volume)) : "--" }
  ]

  barTipActive: root.hovered && !root.islandOpen
  barTipText: root.hasTrack ? root.title : "Now Playing"
  barTipLines: root.tipLines

  Component {
    id: islandComp

    NowPlayingIsland {
      id: island

      // The client the card is actually showing: the island can have switched
      // away from the module's own pick, and the lyrics window must follow it.
      // The card closes as the window opens: the window is a toplevel and
      // covers the bar, so an island left open behind it is a second surface
      // showing the same track with no way back to it. That close now lives in
      // bar.showLyrics (LYR-1) so the pad and the menu/keybind verb share one
      // owner - this handler no longer closes the island itself.
      onLyricsFullscreenRequested: {
        BarControl.showLyrics(island.player, ShotLib.matchScreen(root.barScreen, Ui.validScreens))
      }
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  // Scroll adjusts the active player's own volume (never the system
  // sink) and stays silent: the tooltip already carries the live
  // volume line, so an OSD for it would only be noise. The sink path
  // (Volume.qml via the Audio service) keeps its own OSD.
  //
  // The write goes through MediaState.setPlayerVolume - the same primitive
  // the island's slider uses - so normalization, the mute-resume token and
  // the transport resume are one implementation, not a gesture path plus a
  // second policy-free writer. The shared gate also refuses a client that
  // reports an unknown (-1) level, which a raw clamp would turn into "set
  // volume to zero". Unaccepted, so the scroll falls through to the module's
  // own handling instead of being swallowed.
  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (!root.canSetVolume) return
      const step = 0.05
      const d = event.angleDelta.y > 0 ? step : -step
      if (!Core.MediaState.setPlayerVolume(root.player, NP.normalizeVolume(root.player.volume) + d)) return
      event.accepted = true
    }
  }
}
