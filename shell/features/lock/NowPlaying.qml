pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell.Services.Mpris
import qs.common
// qs.services publishes a Timer singleton of its own, so it is taken under
// an alias: an unaliased import would shadow the QtQuick Timer this file's
// position tick below is a QtQuick.Timer. Same disambiguation MediaState.qml
// uses for the same reason.
import qs.services as Core
import "../../common/NowPlaying.js" as NP

// Now-playing pill riding the lockscreen's bottom edge. Flat-box language:
// policy-rounded corners, translucent theme fill, 1px keyline. Album art when the
// player supplies it (note-glyph fallback otherwise), track title over an
// artist-album line, and a tiny equalizer that dances during playback and
// freezes while the card dims for pause. Vanishes entirely with no track.
//
// Player pick: none. The pill pins the player that was active when the lock
// engaged (head of the sorted view) and keeps showing only that client for
// the whole lock session. A reorder never moves it, a newcomer never takes
// it over, and there are no Left/Right switches or key hints.
Item {
  id: root

  // Sorted view of Mpris.players: playing clients first, original order
  // preserved inside each group (shared lib with the bar island).
  readonly property bool blockBrowsers: Settings.value("shell.osd.blockBrowsers") !== false
  readonly property var players: NP.sortPlayers(
    root.blockBrowsers ? NP.filterBrowsers(Mpris.players ? Mpris.players.values ?? [] : [])
      : (Mpris.players ? Mpris.players.values ?? [] : []),
    p => p.playbackState === MprisPlaybackState.Playing)
  // The client pinned at lock time. Set once to the head of the sorted view
  // and never moved after: a reorder keeps the same object, a newcomer is
  // ignored, and a vanished client shows nothing rather than falling over to
  // whatever regrouped into its slot.
  property var pinned: null
  function _pinHead() {
    if (root.pinned !== null) return
    if (root.players.length === 0) return
    root.pinned = root.players[0] ?? null
  }
  onPlayersChanged: root._pinHead()
  // While unpinned (no client yet at surface creation) read the head so the
  // first frame already shows the active client; once pinned, stay on that
  // object while it is still on the bus and show nothing once it is gone.
  readonly property var player: root.pinned === null
    ? (root.players.length > 0 ? root.players[0] ?? null : null)
    : (root.players.indexOf(root.pinned) >= 0 ? root.pinned : null)
  readonly property bool playing: root.player !== null && root.player.playbackState === MprisPlaybackState.Playing
  readonly property string title: root.player !== null ? root.player.trackTitle ?? "" : ""
  readonly property string artist: root.player !== null ? root.player.trackArtist ?? "" : ""
  readonly property string album: root.player !== null ? root.player.trackAlbum ?? "" : ""
  readonly property bool hasTrack: root.player !== null && root.title !== "" && root.player.playbackState !== MprisPlaybackState.Stopped

  // Progress tracking: same idea as lib/ProgressBar.qml - discrete
  // MPRIS position (polled) drives `shownPosition`, the fill width
  // (`progressRatio`) glides via a Behavior (lib/Glide, OutCubic) like
  // the menu's numeric/range bars. Paused / length-less pins.
  property real anchorPosition: 0
  property real shownPosition: 0

  // The player's own length, through the shared accessor the island,
  // MediaState and MediaEvents all read. Reading `player.length` raw makes a
  // live stream look like a finished track: Quickshell reports `length` as
  // the current position when the player publishes no `mpris:length`, so the
  // ratio came out as 1 and the strip sat permanently full.
  readonly property real lengthSec: NP.playerLength(root.player)
  readonly property real progressRatio: root.lengthSec > 0 ? Math.min(1, root.shownPosition / root.lengthSec) : 0

  // Spawn cubic reveal: visual fill = progressRatio * progressAppear,
  // 0->1 600ms OutCubic on lock spawn / track gate. Playback glide is
  // the ProgressBar-compatible Behavior below.
  property real progressAppear: 0

  function reanchor() {
    const newPos = root.player !== null ? root.player.position ?? 0 : 0
    const len = root.lengthSec
    if (root.player === null) {
      root.anchorPosition = 0
      root.shownPosition = 0
      return
    }
    if (!root.playing || len <= 0) {
      root.anchorPosition = newPos
      root.shownPosition = newPos
      return
    }
    // Backward jumps are always honored: a manual rewind must paint at
    // once, never read as "nothing happened" until the next poll.
    root.anchorPosition = newPos
    root.shownPosition = newPos
  }

  onPlayerChanged: root.reanchor()
  onVisibleChanged: {
    root.reanchor()
    if (root.visible && root.hasTrack) {
      root.progressAppear = 0
      progressAppearAnim.restart()
    }
  }
  Component.onCompleted: {
    root._pinHead()
    root.reanchor()
    if (root.hasTrack) {
      root.progressAppear = 0
      progressAppearAnim.restart()
    }
  }
  onLengthSecChanged: root.reanchor()
  onPlayingChanged: root.reanchor()

  // Keep position fresh while playing - MPRIS only pushes on seeks,
  // so we poll via positionChanged() as recommended in the docs.
  //
  // Only when this pill is showing a client that is *not* the active one.
  // MediaEvents runs a permanent 1s tick over the active player, and every
  // surface watching that player is already re-evaluated by it, so ticking
  // it again here would fire the same signal twice a second for no gain.
  // The pinned client can fall out of the head mid-lock (a newcomer starts
  // playing), and then nobody else ticks it, so its own tick is the only
  // thing keeping it moving.
  Timer {
    id: poll
    interval: 1000
    running: root.playing && root.player !== null
      && root.player !== Core.MediaState.activePlayer
    repeat: true
    onTriggered: {
      if (root.player) root.player.positionChanged()
    }
  }

  Connections {
    target: root.player

    function onPositionChanged() {
      root.reanchor()
    }

    function onPlaybackStateChanged() {
      root.reanchor()
    }
  }

  // Hide entirely when no media is detected - parent gates via
  // Settings.lockscreenNowPlaying, we additionally hide when there is no track.
  visible: root.hasTrack

  width: 400
  height: 94

  onHasTrackChanged: {
    if (root.hasTrack) {
      root.progressAppear = 0
      progressAppearAnim.restart()
    } else {
      progressAppearAnim.stop()
      root.progressAppear = 0
    }
  }

  NumberAnimation {
    id: progressAppearAnim
    target: root
    property: "progressAppear"
    from: 0
    to: 1
    duration: 600
    easing.type: Easing.OutCubic
  }

  // Static card frame: fill, keyline, pause dim. The dim and its 200ms
  // fade cover the whole card for pause.
  Rectangle {
    id: contentFrame

    anchors.fill: parent
    opacity: root.hasTrack ? (root.playing ? 1 : 0.55) : 1
    // Opaque when no media - translucent otherwise
    color: root.hasTrack ? Ui.tint("background_1", 0.82) : Theme.color("background_1")
    // Corners follow RoundingPolicy (hypr.decoration.rounding).
    radius: RoundingPolicy.radius
    border.width: 1
    border.color: Ui.tint("foreground_1", 0.25)
    clip: true

    Behavior on opacity {
      NumberAnimation {
        duration: 200
      }
    }

    Item {
      anchors.fill: parent

      Row {
        id: row

          // Bottom margin reserves the progress strip's footprint, so the art
          // keeps equal breathing room above (border) and below (strip top).
          anchors.fill: parent
          anchors.leftMargin: 12
          anchors.rightMargin: 12
          anchors.topMargin: 12
          anchors.bottomMargin: 18
          spacing: 14

          // Art frame: cropped cover when decoded; while it loads or when the
          // player ships none, the frame itself turns into the visualizer
          // stage. With art present the bars ride a bottom scrim instead.
          Rectangle {
            id: artFrame

            readonly property bool hasArt: art.status === Image.Ready || art.status === Image.Loading

            width: 64
            height: 64
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("background_3", 0.5)

            Image {
              id: art

              anchors.fill: parent
              source: root.player !== null ? root.player.trackArtUrl ?? "" : ""
              asynchronous: true
              cache: true
              fillMode: Image.PreserveAspectCrop
              sourceSize.width: 128
              sourceSize.height: 128
              opacity: status === Image.Ready ? 1 : 0
              visible: opacity > 0.01

              Behavior on opacity {
                NumberAnimation {
                  duration: 400
                  easing.type: Easing.OutCubic
                }
              }
            }

            // Full-frame dim so the compact white bars read on near-white
            // covers: 38% black over art only, under scrim + bars.
            Rectangle {
              anchors.fill: parent
              visible: artFrame.hasArt && root.hasTrack
              color: Qt.rgba(0, 0, 0, 0.38)
            }

            // Readability scrim under the compact bars on top of covers.
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              height: 18
              visible: artFrame.hasArt && root.hasTrack
              gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop {
                  position: 0
                  color: Qt.rgba(0, 0, 0, 0)
                }
                GradientStop {
                  position: 1
                  color: Qt.rgba(0, 0, 0, 0.55)
                }
              }
            }

            // Placeholder when no MPRIS player - 50% transparent music.svg
            Icon {
              anchors.centerIn: parent
              visible: !root.hasTrack
              name: "music"
              colorKey: "foreground_0"
              size: 36
              opacity: 0.5
            }

            // Visualizer field spanning the frame's full width. On covers the
            // bars run compact and white over the scrim; on the bare stage they
            // go tall and accent-colored. Bottom-anchored so they stand up,
            // phase-driven so pause freezes them mid-bounce.
            Row {
              id: vizBars
              visible: root.hasTrack

              readonly property bool compact: artFrame.hasArt
              readonly property int barCount: 11
              readonly property real barWidth: (width - (barCount - 1) * spacing) / barCount

              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: compact ? 4 : 2
              anchors.rightMargin: compact ? 4 : 2
              anchors.bottomMargin: compact ? 3 : 4
              spacing: compact ? 3 : 2
              opacity: 0.5

              Repeater {
                model: vizBars.barCount

                Rectangle {
                  id: bar

                  required property int index

                  // Phase 0..1 drives bar length.
                  property real phase: 0.5

                  width: vizBars.barWidth
                  radius: RoundingPolicy.radius
                  anchors.bottom: parent.bottom
                  color: vizBars.compact ? Qt.rgba(1, 1, 1, 0.92) : Theme.color("accent")
                  height: (vizBars.compact ? 3 : 8) + phase * (vizBars.compact ? 10 : 46)

                  SequentialAnimation on phase {
                    loops: Animation.Infinite
                    running: root.playing
                    NumberAnimation {
                      to: 1
                      duration: 420 + bar.index * 120
                      easing.type: Easing.InOutQuad
                    }
                    NumberAnimation {
                      to: 0
                      duration: 360 + bar.index * 90
                      easing.type: Easing.InOutQuad
                    }
                  }
                }
              }
            }
          }

          Column {
            visible: root.hasTrack
            anchors.verticalCenter: parent.verticalCenter
            // Reserves room for art frame, both inter-gaps and the album icon,
            // so the trailing icon lands exactly inside the pill.
            width: row.width - 64 - 14
            spacing: 5

            Row {
              width: parent.width
              spacing: 7
              visible: root.title !== ""

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "music-track"
                colorKey: "accent"
                size: 16
              }

              Text {
                width: parent.width - 13 - 7
                anchors.verticalCenter: parent.verticalCenter
                visible: root.title !== ""
                text: String(root.title ?? "")
                textFormat: Text.PlainText
                color: Theme.color("foreground_0")
                font.pixelSize: 14
                font.family: Ui.fontFamily
                font.bold: true
                elide: Text.ElideRight
              }
            }

            Row {
              width: parent.width
              spacing: 7
              visible: root.artist !== ""

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "music-artist"
                colorKey: "foreground_1"
                size: 15
              }

              Text {
                width: parent.width - 15 - 7
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.artist ?? "")
                textFormat: Text.PlainText
                color: Ui.tint("foreground_1", 0.7)
                font.pixelSize: 12
                font.family: Ui.fontFamily
                elide: Text.ElideRight
              }
            }

            Row {
              width: parent.width
              spacing: 7
              visible: root.album !== ""

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "music-album"
                colorKey: "foreground_1"
                size: 16
              }

              Text {
                width: parent.width - 16 - 7
                anchors.verticalCenter: parent.verticalCenter
                text: String(root.album ?? "")
                textFormat: Text.PlainText
                color: Ui.tint("foreground_1", 0.55)
                font.pixelSize: 12
                font.family: Ui.fontFamily
                elide: Text.ElideRight
              }
            }
          }

          // Empty state - centered "No media playing" when nothing to track
          Item {
            visible: !root.hasTrack
            width: row.width - 64 - 14
            height: 64

            Text {
              anchors.fill: parent
              text: "No media playing"
              color: Ui.tint("foreground_1", 0.75)
              font.pixelSize: 14
              font.family: Ui.fontFamily
              font.italic: true
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              elide: Text.ElideRight
            }
          }
        }
      }
    }

    // Progress strip tucked just inside the keyline, painted last so the
    // card's translucent fill cannot mute it; hidden for streams that
    // report no length.
    Item {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: 1
      height: 5
      visible: root.lengthSec > 0

      Rectangle {
        anchors.fill: parent
        color: Ui.tint("background_3", 0.75)
      }

      Rectangle {
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        // Spawn: cubic 0->current via progressAppear (600ms OutCubic).
        // Position changes (playback polls and user seeks alike) glide with
        // Ui.normalMs OutCubic, including seeks while paused (prev-track):
        // the Behavior runs whenever a length exists and the spawn finished,
        // so a paused jump animates instead of snapping.
        width: parent.width * Math.min(1, Math.max(0, root.progressRatio)) * root.progressAppear
        color: Theme.color("accent")

        Behavior on width {
          enabled: root.lengthSec > 0 && root.progressAppear >= 0.99
          NumberAnimation {
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
          }
        }
      }
    }
  }
