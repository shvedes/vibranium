pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell.Services.Mpris
import qs.common
import qs.features.bar
import qs.services as Core
import "../../../../common/NowPlaying.js" as NP

// Now Playing bar module (opt-in, off by default). Shows the active
// MPRIS track title in the bar; click opens the island, middle and right
// click toggle play/pause on the active client. Player pick:
// a playing client keeps the slot, a silent one hands it to the head
// while anything is playing, and an all-paused set keeps the last-used
// player instead of falling back to slot 0.
CollapsibleSlot {
  id: root

  readonly property bool blockBrowsers: Settings.value("shell.osd.blockBrowsers") !== false
  // The MPRIS set, named once. `Mpris.players` is a model that is briefly
  // absent while the bus is still answering, and `values` is briefly absent
  // on the model itself, so the two-step fold belongs to one place: written
  // out twice, the two copies are free to drift and the branch below would
  // silently filter one set and sort another.
  readonly property var allPlayers: Mpris.players ? Mpris.players.values ?? [] : []
  readonly property var players: NP.sortPlayers(
    root.blockBrowsers ? NP.filterBrowsers(root.allPlayers) : root.allPlayers,
    p => p.playbackState === MprisPlaybackState.Playing)
  property int playerIndex: 0
  readonly property var player: root.players.length > 0
    ? root.players[Math.min(root.playerIndex, root.players.length - 1)] ?? null
    : null
  readonly property string title: root.player !== null ? root.player.trackTitle ?? "" : ""
  readonly property string artist: root.player !== null ? root.player.trackArtist ?? "" : ""
  readonly property string album: root.player !== null ? root.player.trackAlbum ?? "" : ""
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
  // on pause), holds 1s, then slide-fades back. The hold is a dwell,
  // not motion, so it is not gated by MotionPolicy.
  property string transportIcon: ""
  property bool _transportSeeded: false
  Timer {
    id: transportTimer

    interval: 1000
    repeat: false
    onTriggered: root.transportIcon = ""
  }
  function _flashTransport(icon) {
    root.transportIcon = icon
    transportTimer.restart()
  }
  onPlayingChanged: {
    if (!root._transportSeeded) return
    if (!root.hasClient) {
      transportTimer.stop()
      root.transportIcon = ""
      return
    }
    root._flashTransport(root.playing ? "play" : "pause")
  }
  onHasClientChanged: {
    if (!root.hasClient) {
      transportTimer.stop()
      root.transportIcon = ""
    }
  }
  // Whether the active player takes a volume write at all. MPRIS cannot
  // say, and a browser client declares Volume and drops the write, so the
  // media service round-trips it; see its volume section. Bound here as
  // well as in the island so the answer is already settled by the time the
  // island opens.
  readonly property bool canSetVolume: Core.MediaState.volumeCapable(root.player)
  readonly property bool shown: root.hasClient

  // Title text switch (shell.statusbar.nowPlayingTitle, default
  // off): on shows the title next to the icon, off collapses the
  // pill to the bare icon slot. The track-change flash
  // (shell.statusbar.nowPlayingFlash, default on) reveals the name
  // either way.
  readonly property bool showTitle: Settings.value("shell.statusbar.nowPlayingTitle") === true
  readonly property bool flashEnabled: Settings.value("shell.statusbar.nowPlayingFlash") !== false
  property bool flashActive: false
  Timer {
    id: flashTimer

    interval: 3000
    repeat: false
    onTriggered: root._stopFlash()
  }
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
    if (root.flashEnabled) root._startFlash()
  }

  // Track-name flash: reveals the title for 3s on a track change. The
  // icon is untouched by it - only (un)pause swaps the glyph (play on
  // resume, pause on pause, album otherwise), so next/previous never
  // change what the slot shows.
  function _startFlash() {
    if (!root.flashEnabled || !root.hasTrack) return
    root.flashActive = true
    flashTimer.restart()
  }

  function _stopFlash() {
    flashTimer.stop()
    root.flashActive = false
  }

  onTrackKeyChanged: root._queueTrackObservation()
  onTitleChanged: {
    root._queueTrackObservation()
    // A title landing while the name is up is a mid-flash swap:
    // kick it. An opening flash skips this (titleSlide is still 0)
    // and rides the width reveal instead.
    if (root.titleSlide > 0) labelText.kickName()
  }
  onArtistChanged: root._queueTrackObservation()
  onAlbumChanged: root._queueTrackObservation()
  onHasTrackChanged: {
    if (!root.hasTrack) root._stopFlash()
  }
  onFlashEnabledChanged: {
    if (!root.flashEnabled) root._stopFlash()
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
  collapseFull: root.titleSlide > 0 ? pill.width : Bar.iconSlot
  property real titleSlide: root.hasTrack && (root.showTitle || root.flashActive) ? 1 : 0
  Behavior on titleSlide {
    Glide { duration: Ui.slowMs }
  }

  // Icon + title pill (the Weather module boxing): the slot's own
  // inset all lands on the trailing text edge.
  Item {
    id: pill

    anchors.left: parent.left
    anchors.verticalCenter: parent.verticalCenter
    width: Bar.iconSlot + root.titleSlide * (Math.min(labelText.implicitWidth, 240) + 4 + Bar.slotInset)
    height: root.height
    // The open/close travel is owned by the titleSlide Behavior below, so
    // this chase stays out of its way: ungated it restarts every frame off
    // the moving driver, the close freezes, and the snap lands at the end.
    // Gated to the settled-open state it only smooths the width jumps when
    // the name swaps while the flash is already up (spammed next/prev).
    // clip keeps the sliding name inside the slot while the width catches
    // up. The Bar.iconSlot base keeps collapseFull continuous when the
    // flash closes (pill settles exactly onto the icon-only width).
    clip: true
    Behavior on width {
      enabled: root.titleSlide === 1
      Glide { duration: Ui.fastMs }
    }

    // Transport slide-fade: two Icons share one fixed, clipped slot and
    // trade place when the glyph flips - play slides in from the right,
    // pause from the left, and the trip home mirrors the flash direction,
    // so the album glyph comes back from the side the action glyph is
    // leaving toward (the island's kickSwap language, on the icon axis).
    // tweens below, never bound, and handoffs start from live values;
    // with motion off the swap snaps. `clip` keeps the travel inside
    // the slot so neighbours never see it.
    Item {
      id: trackIcon

      // Fixed one-slot wrapper, always docked left: the icon keeps its
      // centred canvas and the label anchors to its stable right edge,
      // so the flash open/close moves only the pill's trailing edge
      // while icon and text hold still (the Network/Bluetooth
      // glyph-wrapper convention). The old left-vs-centered switch read
      // the titleSlide driver but positioned against the lagging pill
      // width, so the icon snapped right at the end of every close.
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Bar.iconSlot
      height: parent.height
      clip: true

      // Pause/play only: next/previous never change this glyph, so a
      // track change only reveals the title beside the album glyph.
      readonly property string currentName: root.transportIcon !== "" ? root.transportIcon : "music-album"
      // Travel of the incoming glyph: +1 arrives from the right (play),
      // -1 from the left (pause).
      property int slideDir: 1

      property string _aName: currentName
      property string _bName: ""
      property bool _aFront: true

      Component.onCompleted: {
        _aName = currentName
      }

      function _layer(i) { return i === 0 ? iconA : iconB }
      function _fadeOut(i) { return i === 0 ? fadeOutA : fadeOutB }
      function _slideOut(i) { return i === 0 ? slideOutA : slideOutB }

      onCurrentNameChanged: {
        const showing = _aFront ? _aName : _bName
        if (currentName === showing) return
        if (currentName === "play") slideDir = 1
        else if (currentName === "pause") slideDir = -1
        else slideDir = -slideDir
        const target = _aFront ? 1 : 0
        const outgoing = _aFront ? 0 : 1
        if (target === 0) _aName = currentName
        else _bName = currentName
        _aFront = target === 0
        const enter = _layer(target)
        const exit = _layer(outgoing)
        if (MotionPolicy.enabled) {
          fadeIn.stop()
          slideIn.stop()
          const outF = _fadeOut(outgoing)
          const outS = _slideOut(outgoing)
          outF.stop()
          outS.stop()
          fadeIn.target = enter
          fadeIn.from = enter.opacity
          fadeIn.restart()
          slideIn.target = enter
          slideIn.from = slideDir * Ui.s
          slideIn.to = 0
          slideIn.restart()
          outF.from = exit.opacity
          outF.restart()
          outS.from = exit.slideOff
          outS.to = -slideDir * Ui.s
          outS.restart()
        } else {
          fadeIn.stop()
          slideIn.stop()
          fadeOutA.stop()
          fadeOutB.stop()
          slideOutA.stop()
          slideOutB.stop()
          enter.slideOff = 0
          enter.opacity = 1
          exit.slideOff = 0
          exit.opacity = 0
        }
      }

      Icon {
        id: iconA

        property real slideOff: 0
        x: (parent.width - width) / 2 + slideOff
        y: (parent.height - height) / 2
        name: trackIcon._aName
        colorKey: "foreground_0"
        opacity: 1
      }

      Icon {
        id: iconB

        property real slideOff: 0
        x: (parent.width - width) / 2 + slideOff
        y: (parent.height - height) / 2
        name: trackIcon._bName
        colorKey: "foreground_0"
        opacity: 0
      }

      NumberAnimation {
        id: fadeIn

        property: "opacity"
        to: 1
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: slideIn

        property: "slideOff"
        to: 0
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: fadeOutA

        target: iconA
        property: "opacity"
        to: 0
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: slideOutA

        target: iconA
        property: "slideOff"
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: fadeOutB

        target: iconB
        property: "opacity"
        to: 0
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: slideOutB

        target: iconB
        property: "slideOff"
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.OutCubic
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
      font.pixelSize: Math.round(Ui.fontM * 0.95 * root.textScale)
      text: root.title
      elide: Text.ElideRight
      // Shift composes with the anchors, so the slide below never
      // fights the layout the way animating x would.
      transform: Translate { id: nameShift }

      // Mid-flash title swap: slide-fade the new name in, the island's
      // kickMeta language, so a name arriving while the flash is up
      // reads as motion instead of a jump.
      function kickName() {
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

  // Click contract: left opens the island, middle and right toggle transport.
  // Middle and right are the same action on purpose - the two that a hand
  // reaches for without aiming at the bar - and the toggle is the one action
  // worth having without opening anything. `canTogglePlaying` is a
  // declaration a client can publish false, so a client that opts out of
  // Playback/Pause swallows the press instead of taking it and doing
  // nothing.
  fillButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
  onClicked: mouse => {
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
    { icon: "volume-max", text: root.player ? Math.round((root.player.volume ?? 0) * 100) + "%" : "--" }
  ]

  ToolTipBind {
    active: root.hovered && !root.barWindow.islandHost.isOpenFor(root)
    text: root.hasTrack ? root.title : "Now Playing"
    lines: root.tipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    NowPlayingIsland {}
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  // Scroll adjusts the active player's own volume (never the system
  // sink) and stays silent: the tooltip already carries the live
  // volume line, so popping the OSD would only be noise. The island
  // has no player-volume control and the sink path (Volume.qml via
  // the Audio service) keeps its own OSD.
  //
  // The same gate the island's slider reads: a player that does not take
  // a volume write would take the scroll and the tooltip line would move
  // with nothing behind it. Unaccepted, so the scroll falls through to
  // the module's own handling instead of being swallowed.
  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (!root.player) return
      if (!root.canSetVolume) {
        // The gate is MediaState's round trip, not an MPRIS flag, so this is
        // the one refusal on this path the client never declared: a browser
        // adapter answers a volume write with success and drops it, and the
        // scroll would otherwise move the tooltip line with nothing behind it.
        return
      }
      const step = 0.05
      const d = event.angleDelta.y > 0 ? step : -step
      const cur = Number(root.player.volume ?? 0)
      if (isNaN(cur)) return
      const nv = Math.max(0, Math.min(1, cur + d))
      root.player.volume = nv
      event.accepted = true
    }
  }
}
