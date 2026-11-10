pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Services.Mpris
import qs.common
import "../../../../common/NowPlaying.js" as NP
import "../../../../common/process/CommandSpec.js" as CommandSpec

// Fullscreen lyrics surface for the Now Playing island: a left click on the
// island's cover while its transcript is up asks the module to open this
// window, which outlives the island and is handed the client rather than a
// binding to it.
//
// The composition is ratio-driven rather than pixel-driven, so 16:9, 16:10
// and 3:2 outputs all read the same: a cover column on the left with the seek
// lane under it, and the synced transcript filling the rest. The cover box is
// derived from the cover's own aspect ratio and centred in its column, so a
// portrait or wide cover is neither cropped nor left in a letterbox.
//
// Esc or the corner minimizer closes it. Right-clicking the island's artwork
// goes back to the island's controls instead of opening this.
PanelWindow {
  id: root

  // Filled by the island at open time. The MPRIS object outlives both the
  // island and this window, which is why a reference is enough.
  property var player: null
  property bool opened: false
  property ShellScreen targetScreen: null

  // While the transcript is up the session must not idle out from under it:
  // the inhibitor stops the compositor marking the session idle, which is what
  // the idle daemon's lock and suspend rows wait on. Releasing the surface
  // releases the hold; the window association is what makes a compositor
  // respect it.
  IdleInhibitor {
    enabled: root.opened
    window: root
  }

  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.left: true
  anchors.right: true
  anchors.top: true
  anchors.bottom: true
  visible: root.opened
  screen: root.targetScreen

  WlrLayershell.namespace: "vibranium:lyrics"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: root.opened
    ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

  readonly property bool animOn: MotionPolicy.enabled
  readonly property string artUrl: root.player !== null ? root.player.trackArtUrl ?? "" : ""
  readonly property bool playing: root.player !== null
    && root.player.playbackState === MprisPlaybackState.Playing
  readonly property real lengthSec: NP.playerLength(root.player)
  readonly property bool canSeekPosition: NP.canSetPlayerPosition(root.player)
  // Transport, gated per client exactly as the island's pads are: a
  // capability the client publishes false refuses the write and dims its pad.
  readonly property bool hasTrack: root.player !== null
    && String(root.player.trackTitle ?? "") !== ""
  readonly property bool shuffling: root.player !== null ? (root.player.shuffle ?? false) : false
  readonly property bool looping: root.player !== null && root.player.loopState !== undefined
    && root.player.loopState !== MprisLoopState.None
  readonly property bool loopOne: root.player !== null
    && root.player.loopState === MprisLoopState.Track
  readonly property bool canShuffle: root.player !== null
    && root.player.canControl !== false
    && root.player.shuffleSupported !== false
  readonly property bool canLoop: root.player !== null
    && root.player.canControl !== false
    && root.player.loopSupported !== false
  readonly property bool canTogglePlaying: root.player !== null
    && root.player.canTogglePlaying !== false
  property real shownPosition: 0
  readonly property real progressRatio: root.lengthSec > 0
    ? Math.min(1, root.shownPosition / root.lengthSec) : 0
  // Click seeks ease, sustained drags snap: the pointer must travel past 6px
  // while pressed before the lane belongs to the drag. Same contract as the
  // island's lane.
  property bool _seeking: false
  property real _pressX: 0

  // Backdrop density. The surface paints the theme background solid under the
  // transcript; a double click on empty space swaps it for the same colour at
  // 80% opacity, which lets the desktop read faintly behind the lyrics while
  // they stay legible. A view preference rather than a setting, so it lives in
  // the shell cache ($VIBRANIUM_CACHE/shell.json, "lyrics" section) instead of
  // the settings catalog.
  //
  // The fill is a Rectangle inside the window, not the window's own `color`:
  // a surface colour reaches the compositor with the surface, so a live change
  // to it only shows up the next time the surface is mapped - the backdrop
  // stayed opaque until the overlay was reopened. A Rectangle is ordinary
  // scene graph and repaints on the tick the cache write lands, which is also
  // what lets the compositor's blur follow the alpha (see the vibranium:lyrics
  // layer rule in default/hypr/window-rules.lua).
  readonly property real dimBackdropAlpha: 0.8

  // Read through the cache on every evaluation, so a restart and a second
  // overlay (one per bar) both land on the saved value; toggleBackdrop is the
  // only writer. Anything outside (0, 1) - absent, hand-edited, a future
  // value this switch does not own - reads as the solid backdrop rather than
  // as a half-painted surface.
  readonly property real backdropAlpha: {
    const a = ShellCache.number("lyrics", "backdropAlpha", 1)
    return a > 0 && a < 1 ? a : 1
  }

  readonly property color backdropColor: Ui.tint("background_0", root.backdropAlpha)

  function toggleBackdrop() {
    ShellCache.updateSection("lyrics",
      { backdropAlpha: root.backdropAlpha >= 1 ? root.dimBackdropAlpha : 1 })
  }

  function open(p) {
    if (p === null || p === undefined) return
    root.player = p
    root.reanchor()
    root.opened = true
    Qt.callLater(function() { if (root.opened) content.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function reanchor() {
    const p = root.player !== null ? root.player.position ?? 0 : 0
    root.shownPosition = Math.min(root.lengthSec > 0 ? root.lengthSec : p, Math.max(0, p))
  }

  function seekAt(x, w) {
    if (!root.canSeekPosition || w <= 0) return
    const t = NP.clampRatio(x, w) * root.lengthSec
    root.player.position = t
    // Optimistic adopt so the lane jumps at once; the daemon's notify
    // corrects it a moment later.
    root.shownPosition = t
    if (root.player) root.player.positionChanged()
  }

  // Scrub preview: moves the lane only, writes nothing. A per-move position
  // write queues up in the player and replays after release, so a drag
  // commits once, on release.
  function scrubTo(x, w) {
    if (!root.canSeekPosition || w <= 0) return
    root.shownPosition = NP.clampRatio(x, w) * root.lengthSec
  }

  function seekTo(seconds) {
    if (!root.canSeekPosition) return
    const t = Math.max(0, Math.min(root.lengthSec, Number(seconds) || 0))
    root.player.position = t
    root.shownPosition = t
    if (root.player) root.player.positionChanged()
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

  function toggleShuffle() {
    if (!root.canShuffle) return
    root.player.shuffle = !root.shuffling
  }

  // none -> repeat-all -> repeat-one -> none, the island's cycle.
  function cycleLoop() {
    if (!root.canLoop) return
    root.player.loopState = root.player.loopState === MprisLoopState.None
      ? MprisLoopState.Playlist
      : (root.player.loopState === MprisLoopState.Playlist
        ? MprisLoopState.Track : MprisLoopState.None)
  }

  onOpenedChanged: {
    root._seeking = false
    if (root.opened) {
      root.reanchor()
      root._holdStart()
    } else {
      root._holdStop()
    }
  }
  Component.onDestruction: root._holdStop()
  onPlayerChanged: {
    root._seeking = false
    root.reanchor()
    // The client left the bus: nothing on this surface can act any more.
    if (root.player === null && root.opened) root.close()
  }
  onLengthSecChanged: root.reanchor()
  // --- logind hold ---------------------------------------------------------
  //
  // The Wayland inhibitor above is what stops the compositor idling, but logind
  // has no record of it, so `systemd-inhibit --list` and the lock screen's
  // blocker notice (which reads logind's ListInhibitors) cannot see it. This is
  // the same hold as a real logind lock: an idle block owned by a
  // systemd-inhibit child for as long as the surface is open. Idle only, the
  // policy the caffeine lock already follows - an explicit suspend stays an
  // explicit suspend.
  property var _holdJob: null

  function _holdStart() {
    if (root._holdJob !== null) return
    const spec = CommandSpec.argv([
      "systemd-inhibit", "--what=idle", "--who=Vibranium",
      "--why=Lyrics fullscreen is open", "--mode=block",
      "sleep", "infinity"
    ])
    if (spec.ok !== true) return
    const ended = () => {
      root._holdJob = null
      // A hold that died under an open surface is retried; a hold released by
      // closing the surface is not.
      if (root.opened) holdRetry.restart()
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

  Timer {
    id: holdRetry

    interval: 5000
    repeat: false
    onTriggered: if (root.opened) root._holdStart()
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

  // The transcript follows the clock the way the island's does: one position
  // poll per second while the client plays, plus the daemon's own notify. The
  // pane needs no clock of its own.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.playing && !root._seeking && root.player !== null
    onTriggered: if (root.player) root.player.positionChanged()
  }

  Connections {
    target: root.player

    // A scrub owns the lane until release; notifies, including the poke
    // seekAt makes, must not move it under the pointer.
    function onPositionChanged() { if (!root._seeking) root.reanchor() }
    function onPlaybackStateChanged() { root.reanchor() }
  }



  Item {
    id: content

    anchors.fill: parent
    focus: root.opened
    Keys.onEscapePressed: root.close()

    // The surface's own backdrop, under everything else. See backdropColor for
    // why this is a Rectangle rather than the window's colour.
    Rectangle {
      id: backdrop

      anchors.fill: parent
      color: root.backdropColor
    }

    // Empty space is the gesture surface: a double click anywhere the pads,
    // the lane and the transcript do not reach swaps the backdrop. Declared
    // under the rest, so every other child keeps its own clicks.
    MouseArea {
      id: backdropHit

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      onDoubleClicked: root.toggleBackdrop()
    }

    // Screen-relative margins: a 1080p output and a 3:2 laptop get the same
    // composition instead of the same pixel inset.
    readonly property real pad: Math.round(Math.max(16, Math.min(48,
      Math.min(width, height) * 0.055)))
    readonly property real gap: Math.round(Math.max(20, Math.min(64, width * 0.035)))
    readonly property real availW: Math.max(0, width - 2 * pad)
    readonly property real availH: Math.max(0, height - 2 * pad)
    // Cover column share. Capped by the available height so a short, wide
    // output does not hand the transcript a sliver.
    readonly property real coverW: Math.max(120, Math.min(availW * 0.42, availH * 0.95))
    // Transport pads fill the space between the cover and the lane, sized
    // from the cover column so the whole left group keeps one scale.
    readonly property real padSlot: Math.round(Math.max(48, Math.min(88, coverW * 0.115)))
    readonly property real padIcon: Math.round(padSlot * 0.5)
    readonly property real timePx: Math.max(Ui.fontS, Math.round(Ui.fontS * 1.45))
    readonly property real progressH: Math.round(timePx * 1.6)
    readonly property real stackGap: Math.round(gap * 0.35)
    // The band the cover may occupy: the column minus the pads, the lane and
    // the gaps between them.
    readonly property real artMaxH: Math.max(80,
      availH - padSlot - progressH - 2 * stackGap)
    // Presentation type: the pane's own base sizes multiplied, bounded so a
    // 4K output does not turn one cue into a headline.
    readonly property real lyricsScale: Math.max(1.5, Math.min(3.2, availH / 460))
    readonly property real lyricsX: pad + coverW + gap
    readonly property real lyricsW: Math.max(0, width - lyricsX - pad)
    readonly property real emptyIcon: Math.round(Math.max(64,
      Math.min(lyricsW, availH) * 0.24))
    // The cover's own shape, so the box is exactly the painted image rather
    // than a square the artwork has to letterbox inside. A cover that has not
    // landed yet is treated as square, which is what the shipped art is.
    readonly property real artAspect: art.status === Image.Ready && art.implicitHeight > 0
      ? art.implicitWidth / art.implicitHeight : 1
    readonly property real coverBoxW: Math.max(0, Math.min(coverW, artMaxH * artAspect))
    readonly property real coverBoxH: artAspect > 0 ? coverBoxW / artAspect : coverBoxW
    // Cover, transport and lane are one group centred in the column: a short
    // wide cover leaves no gap above the pads, and a tall one does not push
    // them off the bottom.
    readonly property real stackH: coverBoxH + padSlot + progressH + 2 * stackGap
    readonly property real stackY: pad + Math.max(0, Math.round((availH - stackH) / 2))

    Rectangle {
      id: artFrame

      x: content.pad + Math.round((content.coverW - width) / 2)
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
    }

    // Transport: shuffle, previous, play/pause, next, loop. The island's pad
    // row minus the player switching and the mode pad, at a size that belongs
    // on this surface rather than in the bar.
    Row {
      id: controlsRow

      x: content.pad + Math.round((content.coverW - width) / 2)
      y: content.stackY + content.coverBoxH + content.stackGap
      height: content.padSlot
      spacing: Math.round(content.padSlot * 0.22)

      IconButton {
        name: "shuffle"
        iconSize: content.padIcon
        slotSize: content.padSlot
        flat: true
        cornerRadius: RoundingPolicy.radius
        colorKey: root.shuffling ? "accent" : "foreground_0"
        animationsEnabled: root.animOn
        actionable: root.canShuffle
        opacity: root.canShuffle ? 1 : 0.4
        onClicked: root.toggleShuffle()
      }

      IconButton {
        name: "skip-back"
        iconSize: content.padIcon
        slotSize: content.padSlot
        flat: true
        cornerRadius: RoundingPolicy.radius
        animationsEnabled: root.animOn
        actionable: root.hasTrack && root.player?.canGoPrevious !== false
        opacity: root.hasTrack ? 1 : 0.4
        onClicked: root.previousTrack()
      }

      IconButton {
        name: root.playing ? "pause" : "play"
        iconSize: content.padIcon
        slotSize: content.padSlot
        flat: true
        cornerRadius: RoundingPolicy.radius
        animationsEnabled: root.animOn
        actionable: root.canTogglePlaying
        opacity: root.canTogglePlaying ? 1 : 0.4
        onClicked: root.togglePlaying()
      }

      IconButton {
        name: "skip-forward"
        iconSize: content.padIcon
        slotSize: content.padSlot
        flat: true
        cornerRadius: RoundingPolicy.radius
        animationsEnabled: root.animOn
        actionable: root.hasTrack && root.player?.canGoNext !== false
        opacity: root.hasTrack ? 1 : 0.4
        onClicked: root.nextTrack()
      }

      IconButton {
        name: root.loopOne ? "repeat-1" : "repeat"
        iconSize: content.padIcon
        slotSize: content.padSlot
        flat: true
        cornerRadius: RoundingPolicy.radius
        colorKey: root.looping ? "accent" : "foreground_0"
        animationsEnabled: root.animOn
        actionable: root.canLoop
        opacity: root.canLoop ? 1 : 0.4
        onClicked: root.cycleLoop()
      }
    }

    // Elapsed, seek lane, total: the island's lane contract under the cover,
    // at presentation scale.
    Item {
      id: progressBlock

      x: content.pad
      y: content.stackY + content.coverBoxH + content.stackGap
        + content.padSlot + content.stackGap
      width: content.coverW
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
          id: seekLane

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

              Behavior on width {
                enabled: root.animOn && root.lengthSec > 0 && !root._seeking
                NumberAnimation {
                  duration: Ui.normalMs
                  easing.type: Easing.OutCubic
                }
              }
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
              if (root.canSeekPosition) {
                if (root._seeking) {
                  root.player.position = root.shownPosition
                  root.player.positionChanged()
                } else {
                  root.seekAt(mouse.x, width)
                }
              }
              root._seeking = false
            }
            onCanceled: {
              root._seeking = false
              root.reanchor()
            }
          }

          WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: event => {
              if (event.angleDelta.y === 0) return
              if (!root.canSeekPosition) return
              const d = event.angleDelta.y > 0 ? 5 : -5
              const t = Math.min(root.lengthSec, Math.max(0, root.shownPosition + d))
              root.player.position = t
              root.shownPosition = t
              if (root.player) root.player.positionChanged()
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

    Item {
      id: lyricsSide

      x: content.lyricsX
      y: content.pad
      width: content.lyricsW
      height: content.availH
      // Track-switch entrance: the transcript fades in place while the cover
      // crossfades, so a switch reads as one new track rather than one
      // element swapping.

      LyricsPane {
        id: pane

        anchors.fill: parent
        // The pane answers "no lyrics" in one small line of its own; an empty
        // state above it says the same thing at presentation scale. With a
        // translucent backdrop that line would read through the cover, so the
        // pane steps out of the way while a cover is over it.
        opacity: pane.status === "none" || !root.hasTrack ? 0 : 1
        player: root.player
        position: root.shownPosition
        active: root.opened
        playing: root.playing
        seekable: root.canSeekPosition
        // A presentation surface has nothing to dismiss back to, so a
        // right-click stays inert and the reader's scroll is the only
        // gesture that moves the transcript.
        dismissable: false
        scrollable: true
        textScale: content.lyricsScale
        onSeekRequested: seconds => root.seekTo(seconds)
      }

      // The pane's own empty state is one line of text. The fullscreen
      // surface says it at presentation scale instead; the pane stays
      // underneath so its fetch and cache states are unchanged.
      Rectangle {
        anchors.fill: parent
        visible: pane.status === "none"
        color: root.backdropColor

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
        color: root.backdropColor

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

    // The fade itself. The script leg clears the transcript in place; the
    // short hold makes it read as a fade rather than a frame that happened to
    // be dim. With motion off nothing is staged and the tween is zero-length,
    // so the swap is a single frame.
    SequentialAnimation {
      id: trackSwap

      ScriptAction {
        script: {
          if (!root.animOn) return
          lyricsSide.opacity = 0
        }
      }
      PauseAnimation {
        duration: root.animOn ? 60 : 0
      }
      NumberAnimation {
        target: lyricsSide
        property: "opacity"
        to: 1
        duration: MotionPolicy.duration(Ui.slowMs)
        easing.type: Easing.InOutCubic
      }
    }

    IconButton {
      id: minimizer

      z: 10
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      anchors.bottomMargin: 10
      anchors.rightMargin: 10
      name: "minimize"
      iconSize: 20
      slotSize: 36
      flat: true
      cornerRadius: RoundingPolicy.radius
      animationsEnabled: root.animOn
      // Low-key by default so it never competes with the transcript; the
      // pointer brings it back to full strength.
      opacity: minimizer.hovered ? 1 : 0.5
      onClicked: root.close()
    }
  }
}
