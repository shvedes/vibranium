pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell.Services.Mpris
import qs.common
import "../../common/NowPlaying.js" as NP

// Now-playing pill riding the lockscreen's bottom edge. Flat-box language:
// policy-rounded corners, translucent theme fill, 1px keyline. Album art when the
// player supplies it (note-glyph fallback otherwise), and a track title over
// an artist-album line. Vanishes entirely with no track.
// While a track plays and a lyric sheet is ready, the body crossfades to the
// shared lyrics pane and the frame grows to the lyrics footprint. The compact
// track card stays centred underneath, while the keyline and progress strip
// follow the new size. Pause - or a track with no words - shrinks the frame and
// fades the names back in.
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
  // Pause-on-lock sends its pause as the surface is being built, and players
  // report the state change a beat later. Hold the transcript for the start of
  // this surface only, releasing as soon as the pause lands; later play/pause
  // transitions must not wait on it.
  property bool _lockPauseSettled: true
  Timer {
    interval: 600
    repeat: false
    running: !root._lockPauseSettled
    onTriggered: root._lockPauseSettled = true
  }
  // The body swaps to lyrics only for a playing track whose sheet is ready. A
  // playing track the provider has no words for keeps the names: the pane's
  // "No lyrics" state is an offer in the island and noise on a lock screen.
  readonly property bool lyricsUp: root.playing && root._lockPauseSettled
    && root.hasTrack && lyrics.ready
  readonly property string title: root.player !== null ? root.player.trackTitle ?? "" : ""
  readonly property string artist: root.player !== null ? root.player.trackArtist ?? "" : ""
  readonly property string album: root.player !== null ? root.player.trackAlbum ?? "" : ""
  readonly property bool hasTrack: root.player !== null && root.title !== "" && root.player.playbackState !== MprisPlaybackState.Stopped

  // Progress tracking: same idea as lib/ProgressBar.qml - discrete
  // MPRIS position (polled) drives `shownPosition`, while the fill width
  // (`progressRatio`) glides via a Behavior (lib/Glide, OutCubic) like
  // the menu's numeric/range bars.
  property real shownPosition: 0

  // The player's own length, through the shared accessor the island and
  // MediaState read. Reading `player.length` raw makes a
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
    root.shownPosition = NP.playerPosition(root.player)
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
    // A pause-on-lock pause needs a beat to land. Hold only when there is a
    // playing client or the client list is not known yet; a paused lock or a
    // later play must not wait.
    root._lockPauseSettled = !(Settings.lockscreenPauseMusic
      && (root.playing || root.player === null))
    if (root.hasTrack) {
      root.progressAppear = 0
      progressAppearAnim.restart()
    }
  }
  onLengthSecChanged: root.reanchor()
  onPlayingChanged: {
    root.reanchor()
    if (!root.playing) root._lockPauseSettled = true
  }

  // Keep position fresh while playing - MPRIS only pushes on seeks,
  // so we poll via positionChanged() as recommended in the docs.
  //
  // The pill polls whichever client it shows, including the active one:
  // nothing else ticks that player, and the pinned client can fall out of
  // the head mid-lock (a newcomer starts playing).
  Timer {
    id: poll
    interval: 1000
    running: root.playing && root.player !== null
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

  // Compact for track data, roomier only while the transcript is up. The
  // height drives everything inside the card, so the lyrics, their type and
  // the progress strip grow together instead of being sized for the big frame.
  readonly property int compactWidth: 400
  readonly property int compactHeight: 94
  readonly property int lyricsWidth: 520
  readonly property int lyricsHeight: 120
  readonly property int targetWidth: root.lyricsUp ? root.lyricsWidth : root.compactWidth
  readonly property int targetHeight: root.lyricsUp ? root.lyricsHeight : root.compactHeight
  readonly property real lyricsGrowth: Math.max(0, Math.min(1,
    (root.height - root.compactHeight) / (root.lyricsHeight - root.compactHeight)))
  // True while the frame is tweening between footprints. The progress fill
  // must track the moving width directly rather than animate toward it.
  readonly property bool _sizeMoving: Math.abs(root.width - root.targetWidth) > 0.5
    || Math.abs(root.height - root.targetHeight) > 0.5
  width: root.targetWidth
  height: root.targetHeight

  Behavior on width {
    enabled: MotionPolicy.enabled
    NumberAnimation {
      duration: Ui.normalMs
      easing.type: Easing.OutCubic
    }
  }
  Behavior on height {
    enabled: MotionPolicy.enabled
    NumberAnimation {
      duration: Ui.normalMs
      easing.type: Easing.OutCubic
    }
  }

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
      enabled: MotionPolicy.enabled
      NumberAnimation {
        duration: 200
      }
    }

    Item {
      id: cardBody

      // The track card keeps its compact footprint and stays centred while the
      // frame grows around it; only the transcript spends the extra room.
      width: root.compactWidth
      height: root.compactHeight
      anchors.centerIn: parent
      // Crossfade against the transcript below. The body stays on its compact
      // footprint, so the track content does not move while the frame grows
      // around it.
      opacity: root.lyricsUp ? 0 : 1
      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation {
          duration: Ui.normalMs
          easing.type: Easing.OutCubic
        }
      }

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

          // Art frame: cropped cover when decoded; the empty frame is the
          // fallback while it loads or when the player ships none.
          Rectangle {
            width: 64
            height: 64
            anchors.verticalCenter: parent.verticalCenter
            color: Ui.tint("background_3", 0.5)

            Image {
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

            // Placeholder when no MPRIS player - 50% transparent music.svg
            Icon {
              anchors.centerIn: parent
              visible: !root.hasTrack
              name: "music"
              colorKey: "foreground_0"
              size: 36
              opacity: 0.5
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

    LyricsPane {
      id: lyrics

      anchors.fill: parent
      // The strip is painted inside the bottom keyline; keep the words above
      // it rather than over it as the strip thickens with the card.
      anchors.bottomMargin: 6 + 2 * root.lyricsGrowth
      // No ask for a box the user switched off: the pane otherwise fetches a
      // sheet on every lock even while the card is hidden. A later enable
      // re-points the player, and the track key change loads the sheet.
      player: Settings.lockscreenNowPlaying ? root.player : null
      position: root.shownPosition
      // Always live so the cue under the playhead is already centred when
      // playback starts and the fade only reveals it. `active` drives the
      // island's slide, not this card's crossfade.
      active: true
      // Presentation only: no seek, no dismiss, no drag.
      seekable: false
      dismissable: false
      scrollable: false
      // Cue changes glide to the next line like the island; only the body
      // swap itself is a crossfade.
      glide: true
      // The card's own growth drives the transcript's type: base size on the
      // compact track card, the larger size only once the lyrics frame opens.
      textScale: 1 + 0.4 * root.lyricsGrowth
      // Only the passed, current and upcoming cues: a glanceable three-line
      // window rather than the island's full transcript.
      contextLines: 1
      opacity: root.lyricsUp ? 1 : 0
      visible: opacity > 0.001
      Behavior on opacity {
        enabled: MotionPolicy.enabled
        NumberAnimation {
          duration: Ui.normalMs
          easing.type: Easing.OutCubic
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
      // Follows the card's growth exactly, so the strip and the lyrics bottom
      // edge stay aligned while the frame opens.
      height: 5 + 2 * root.lyricsGrowth
      // Keep the fill from painting past the strip while the frame shrinks.
      clip: true
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
        // the Behavior runs whenever a length exists, the spawn finished and
        // the card is at rest, so a paused jump animates instead of snapping.
        width: parent.width * Math.min(1, Math.max(0, root.progressRatio)) * root.progressAppear
        color: Theme.color("accent")

        Behavior on width {
          // Follow a resizing frame in lockstep; only animate progress
          // changes that happen at rest.
          enabled: MotionPolicy.enabled && root.lengthSec > 0
            && root.progressAppear >= 0.99 && !root._sizeMoving
          NumberAnimation {
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
          }
        }
      }
    }
  }
