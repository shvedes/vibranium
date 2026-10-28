pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell.Services.Mpris
import qs.common
import qs.features.osd
import qs.services as Core
import "../../../../common/NowPlaying.js" as NP

// Now Playing island. Lockscreen flat-box language (square corners,
// translucent theme fill, 1px keyline): large art left, track lines +
// seekable progress + times + control pads in the right column.
// Player pads stay visible and dim out while a single client is alive.
//
// SPLIT MAP (one owner each, no behavior change): Strip (transport
// strip: art column, meta column, seek/volume lanes, pads, player
// switching) and Marquee (title marquee: overflow measure, leg/pause
// animation, reset on track change).
Item {
  id: root

  readonly property int artColumnGap: 12
  // Fixed, not a minimum: the frame is a constant width so `islandContentWidth`
  // is a constant too, and the card does not resize on a track change. Covers
  // are cropped to the frame instead - see the fillMode on the two art images.
  readonly property int artColumnWidth: 144
  readonly property int metaColumnWidth: 280
  // Lane geometry. Each lane row is [readout][gap][lane][gap][readout] and
  // spans the full column, the volume row carrying one readout fewer and a
  // mute pad in its place:
  //
  //   progress:  [ elapsed ][gap][ seek lane ][gap][ total ]
  //   volume:    [icon    ][gap][ volume lane ][gap][ percent ]
  //
  // Elapsed and total are back on their own sides of the lane. As one
  // `1:59/3:49` they were the same measurement twice and read as a fraction;
  // as two fields flanking the control they say what they are - where the
  // position is, and how far there is to go - and the row reads as the shape of
  // the thing it controls.
  //
  // The progress row has no leading glyph, so its lane starts at the column's
  // left edge and the two lanes deliberately do not share an x. It gives the
  // width to the lane instead: the volume row's lead is one 18px pad against
  // the progress row's two time columns, so the volume lane is the longer of
  // the two without either row having width reserved against it.
  readonly property int muteSlot: 18
  readonly property int laneGap: Ui.s / 2
  // Sized from the track, not from the theoretical worst case, and one number
  // serves both time columns because both hold the same value. The elapsed
  // position never passes the length, so the length is the longest either field
  // can take and the length is the widest string they will be asked to hold - a
  // column reserved for the cap is nearly two and a half times too wide for a
  // four-minute track, and the leftover is the gap between a readout and the
  // lane. `playerLength` caps the length, so this can never exceed
  // `NP.widestTime()` and a column can never elide.
  readonly property int timeColumnWidth: Math.ceil(timeColumn.advanceWidth)
  readonly property int percentColumnWidth: Math.ceil(percentColumn.advanceWidth)
  readonly property int seekLaneWidth: Math.max(0, root.metaColumnWidth
    - 2 * root.timeColumnWidth - 2 * root.laneGap)
  readonly property int volumeLaneWidth: Math.max(0, root.metaColumnWidth - root.muteSlot
    - root.percentColumnWidth - 2 * root.laneGap)
  property int islandContentWidth: root.artColumnWidth + root.artColumnGap + root.metaColumnWidth + 2 * Ui.outerPad
  property int islandContentHeight: Math.ceil(contentRoot.bodyHeight) + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null
  readonly property bool animOn: MotionPolicy.enabled
  readonly property bool marqueeEnabled: root.animOn && root.islandHost !== null && root.islandHost.open

  readonly property bool blockBrowsers: Settings.value("shell.osd.blockBrowsers") !== false
  readonly property var players: NP.sortPlayers(
    root.blockBrowsers ? NP.filterBrowsers(Mpris.players ? Mpris.players.values ?? [] : [])
      : (Mpris.players ? Mpris.players.values ?? [] : []),
    p => p.playbackState === MprisPlaybackState.Playing)
  property int playerIndex: 0
  // Click seeks ease, sustained drags snap: _seeking arms only
  // after the pointer moves past 6px while pressed.
  property bool _seeking: false
  property real _pressX: 0
  readonly property var player: root.players.length > 0
    ? root.players[Math.min(root.playerIndex, root.players.length - 1)] ?? null
    : null
  readonly property bool playing: root.player !== null && root.player.playbackState === MprisPlaybackState.Playing
  onTitleChanged: {
    root.refreshTrackUrl()
    const key = root.title + "|" + root.artist + "|" + root.album
    if (root._lastMetaKey === "") {
      root._lastMetaKey = key
      return
    }
    if (key === root._lastMetaKey) return
    root._lastMetaKey = key
    const dir = NP.manualDir()
    if (dir === 0) return
    root._swapDir = dir
    metaText.kickMeta()
  }
  onLinkCopiedChanged: titleMarquee.reset()
  readonly property string title: root.player !== null ? root.player.trackTitle ?? "" : ""
  readonly property string artist: root.player !== null ? root.player.trackArtist ?? "" : ""
  readonly property string album: root.player !== null ? root.player.trackAlbum ?? "" : ""
  readonly property string artUrl: root.player !== null ? root.player.trackArtUrl ?? "" : ""
  // Set while a cover that has already loaded is waiting for the flash
  // boundary that is allowed to fade it in. See the art frame.
  property bool _artArmed: false
  // The url this island holds in the shared art warmer (MediaArt), so a
  // reopen on the same track hits the decoded pixmap instead of fetching
  // again. Requested when the url arrives, released when it leaves or the
  // island is destroyed - the hold lasts as long as the track is shown.
  property string _demandedArt: ""
  function _syncArtDemand() {
    if (root._demandedArt !== "" && root._demandedArt !== root.artUrl) {
      Core.MediaArt.release(root._demandedArt)
      root._demandedArt = ""
    }
    if (root.artUrl !== "" && root._demandedArt !== root.artUrl) {
      if (Core.MediaArt.request(root.artUrl)) root._demandedArt = root.artUrl
    }
  }
  // Direct track link from raw MPRIS metadata (xesam:url), refreshed
  // on title/player change (metadata itself carries no usable notify).
  // http/file only: player-internal schemes never leave the player.
  // MPRIS exposes no artist/album urls, so only the title links.
  property string trackUrl: ""
  readonly property bool hasTrackLink: root.trackUrl !== ""
  // Copy flash: click copies the link and swaps the title for
  // "Copied!" with fades, 2s on screen, then swaps back.
  // Restart-safe mid-cycle. Hover state stays hoisted (see above).
  property bool linkCopied: false
  function flashCopied() {
    if (!root.hasTrackLink) return
    Exec.run(["wl-copy", "--type", "text/plain", root.trackUrl])
    copiedCycle.restart()
  }

  // The copy flash: the title fades out, the ScriptAction swaps the text to
  // "Copied!", it fades back, holds 2s, and the swap is undone the same way.
  //
  // The four fades carry the policy in their DURATION rather than in a
  // `running` gate, because a NumberAnimation has no `enabled` member and the
  // ScriptActions in between must still run: with the compositor switch off
  // each fade is 0 and the copy still reads "Copied!" for the same 2s, it just
  // stops travelling. The 2s hold is a dwell, not motion, so it is not gated.
  SequentialAnimation {
    id: copiedCycle

    NumberAnimation {
      target: titleText
      property: "opacity"
      to: 0
      duration: MotionPolicy.duration(Ui.fastMs)
      easing.type: Easing.OutCubic
    }
    ScriptAction {
      script: root.linkCopied = true
    }
    NumberAnimation {
      target: titleText
      property: "opacity"
      to: 1
      duration: MotionPolicy.duration(Ui.fastMs)
      easing.type: Easing.OutCubic
    }
    PauseAnimation {
      duration: 2000
    }
    NumberAnimation {
      target: titleText
      property: "opacity"
      to: 0
      duration: MotionPolicy.duration(Ui.fastMs)
      easing.type: Easing.OutCubic
    }
    ScriptAction {
      script: root.linkCopied = false
    }
    NumberAnimation {
      target: titleText
      property: "opacity"
      to: 1
      duration: MotionPolicy.duration(Ui.fastMs)
      easing.type: Easing.OutCubic
    }
  }
  // Hover state lives here (not bound from the text): a Text binding
  // to its own later-created MouseArea child resolves undefined on
  // first evaluation and never recovers (no underline, log spam).
  property bool titleHover: false
  function refreshTrackUrl() {
    let u = ""
    if (root.player !== null) {
      const md = root.player.metadata
      if (md) {
        const v = md["xesam:url"]
        if (typeof v === "string" && /^(https?|file):/.test(v)) u = v
      }
    }
    root.trackUrl = u
  }
  onArtUrlChanged: {
    root._artArmed = false
    root._syncArtDemand()
    artFade.stop()
    artReveal.stop()
    if (root.artUrl === "") {
      artTop.opacity = 0
      artTop.source = ""
      art.opacity = 0
      artFrame.waitingArt = false
      return
    }
    if (!root.animOn) {
      artTop.opacity = 0
      artTop.source = ""
      artFrame.waitingArt = false
      art.opacity = 1
      return
    }
    artTop.source = root.artUrl
    // A reveal interrupted mid-leg settles: the cover that was fading in
    // is up, and the incoming one crossfades over it.
    if (art.opacity > 0.01) art.opacity = 1
    // A crossfade over artwork that is already up is not a plain box
    // waiting on a cover, so it does not flash.
    artFrame.waitingArt = !artFrame.artPainted
  }
  // The card is here for a registered client, not for a track. A paused,
  // idle or freshly opened player is the case it exists for: the resume
  // pad, the volume row and the client arrows all act on the client, and a
  // "No media playing" line over a live client denies the one thing the
  // user can do about it. Transport state is what the card *shows* - the
  // play and pause pads swap, the progress row dims - never whether the
  // card is there.
  //
  // `hasTrack` is the narrower question, and it only decides whether there
  // is a name to show: the name rows fall back to the same `--` placeholder
  // the artist and album rows already use, and the track-skip pads stay
  // inert.
  readonly property bool hasClient: root.player !== null
  readonly property bool hasTrack: root.hasClient && root.title !== ""
  readonly property bool canNext: root.playerIndex < root.players.length - 1
  readonly property bool canPrev: root.playerIndex > 0
  readonly property bool shuffling: root.player !== null ? (root.player.shuffle ?? false) : false
  readonly property bool looping: root.player !== null && root.player.loopState !== undefined
    && root.player.loopState !== MprisLoopState.None
  readonly property bool loopOne: root.player !== null && root.player.loopState === MprisLoopState.Track
  // Per-player MPRIS capabilities: unsupported pads dim via `enabled`
  // and the toggles below refuse to write.
  //
  // `shuffle` and `loopState` each need *two* answers before a write: MPRIS
  // makes the write conditional on canControl as well as on the matching
  // *Supported flag. A player that offers the flag but refuses control - a
  // remote or companion client - answers the write with an error, so the
  // capability is the conjunction, the same shape `canSetPlayerVolume` uses
  // for volume.
  readonly property bool canShuffle: root.player !== null
    && root.player.canControl !== false
    && root.player.shuffleSupported !== false
  readonly property bool canLoop: root.player !== null
    && root.player.canControl !== false
    && root.player.loopSupported !== false
  // The volume gate is the one capability the bus cannot answer: a browser
  // MPRIS client declares Volume and drops the write, and Quickshell caches
  // the write the shell made, so both MPRIS flags stay true. MediaState owns
  // the round trip that settles it; see its volume section.
  readonly property bool canSetVolume: Core.MediaState.volumeCapable(root.player)
  // The player's own length, through the shared accessor the OSD, MediaState
  // and MediaEvents all read. Reading `player.length` raw is what made a live
  // stream look like a finished track: Quickshell reports `length` as the
  // current position when the player publishes no `mpris:length`, so the
  // ratio came out as 1 and the bar sat permanently full.
  readonly property real lengthSec: NP.playerLength(root.player)
  // Seeking is gated on the flags *and* a real length. No round trip here,
  // unlike volume: a missing length is an absence rather than a declaration a
  // player can fake, and probing by writing a position would audibly jump
  // playback - not a trade a seek bar is worth.
  readonly property bool canSeekPosition: NP.canSetPlayerPosition(root.player)
  property real shownPosition: 0
  readonly property real progressRatio: root.lengthSec > 0 ? Math.min(1, root.shownPosition / root.lengthSec) : 0

  // Width probe for the two time columns, which hold the same value and so are
  // measured once. The sample is this track's own length, which is the widest
  // string either column can show: the elapsed position never passes the
  // length, and `fmtTime` takes the length as its reference, so the two fields
  // cannot disagree about whether the hour is there and the shape cannot change
  // mid-track at the 59:59 -> 1:00:00 crossing.
  //
  // A player with no length has no reference that could put the hour field in,
  // so the columns fall back to the no-hour shape - which is what a stream
  // renders as well, since a stream over an hour long with no length to compare
  // against is the one case where the hour is genuinely unknowable in advance.
  TextMetrics {
    id: timeColumn

    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontXs
    text: root.lengthSec > 0 ? NP.fmtTime(root.lengthSec, root.lengthSec) : "--:--"
  }

  // The volume row's percentage, reserved at a full three digits so the lane
  // beside it does not move as the level goes 9% -> 10% -> 100%.
  TextMetrics {
    id: percentColumn

    font.family: Ui.fontFamily
    font.pixelSize: Ui.fontXs
    text: "100%"
  }

  function reanchor() {
    const p = root.player !== null ? root.player.position ?? 0 : 0
    root.shownPosition = Math.min(root.lengthSec > 0 ? root.lengthSec : p, Math.max(0, p))
  }

  onPlayerChanged: {
    root.reanchor()
    root.refreshTrackUrl()
  }
  onLengthSecChanged: root.reanchor()

  // Previous sorted view, kept so a regroup can re-point playerIndex at the
  // same player object instead of whatever lands on its old slot.
  property var _lastPlayers: []

  // The card does not rearrange while the island is open. A regroup is a
  // transport change on one client, and pulling the card out from under the
  // pointer the instant that client pauses reads as the island losing the
  // track rather than the track stopping - so the hold follows its client by
  // identity and nothing else, and a client that leaves the view is the only
  // thing that moves the index.
  //
  // The arrangement is settled once, at open. IslandHost destroys the island
  // when it closes, so every open is a fresh instance whose playerIndex is 0,
  // and slot 0 of the sorted view is the actively playing client - the first
  // alive one when nothing is playing, which is what keeps a paused Spotify on
  // the card rather than an empty one.
  onPlayersChanged: {
    const prevSel = root._lastPlayers[root.playerIndex] ?? null
    root._lastPlayers = root.players
    if (prevSel === null) {
      if (root.playerIndex > root.players.length - 1)
        root.playerIndex = Math.max(0, root.players.length - 1)
      return
    }
    const idx = root.players.indexOf(prevSel)
    if (idx >= 0 && idx !== root.playerIndex) {
      // A regroup is not a switch the user made, so the card re-points where
      // it stands rather than slide-fading onto itself.
      root._silentRemap = true
      root.playerIndex = idx
      root._silentRemap = false
    }
  }

  // Player switch: user moves (arrows/wheel) animate via kickSwap;
  // automatic regroups (pause/resume re-sorts) re-point silently via
  // _silentRemap so the card never slide-fades onto itself.
  onPlayerIndexChanged: {
    if (!root._silentRemap) body.kickSwap()
  }
  property bool _silentRemap: false

  // Swap direction for kickSwap: +1 slides the new card in from the
  // right (next), -1 from the left (prev). Written before the index
  // moves; remap-driven moves reuse the last user direction.
  property int _swapDir: 1

  // Last metadata key seen by the track-change mover below.
  // Seeded at birth so the first paint never animates.
  property string _lastMetaKey: ""

  function nextPlayer() {
    if (!root.canNext) return
    root._swapDir = 1
    root.playerIndex += 1
    body.kickSwap()
  }

  function prevPlayer() {
    if (!root.canPrev) return
    root._swapDir = -1
    root.playerIndex -= 1
    body.kickSwap()
  }

  function previousTrack() {
    if (!root.hasTrack) return
    if (root.player?.canGoPrevious === false) return
    NP.noteManual("previous")
    root.player?.previous()
  }

  function nextTrack() {
    if (!root.hasTrack) return
    if (root.player?.canGoNext === false) return
    NP.noteManual("next")
    root.player?.next()
  }

  function toggleShuffle() {
    if (!root.canShuffle) return
    const next = !root.shuffling
    root.player.shuffle = next
  }

  // Loop cycle: none -> repeat-all -> repeat-one -> none.
  function cycleLoop() {
    if (!root.canLoop) return
    const next = root.player.loopState === MprisLoopState.None ? MprisLoopState.Playlist
      : (root.player.loopState === MprisLoopState.Playlist ? MprisLoopState.Track : MprisLoopState.None)
    root.player.loopState = next
  }

  function seekRelative(offset) {
    if (!root.canSeekPosition) return
    root.player.seek(offset)
    root.player.positionChanged()
  }

  // Absolute seek: ratio across the lane width maps onto lengthSec.
  // The strip adopts the target at once; the live onPositionChanged
  // below corrects on daemon notify.
  function seekAt(x, w) {
    if (!root.canSeekPosition || w <= 0) return
    const t = NP.clampRatio(x, w) * root.lengthSec
    root.player.position = t
    // Optimistic adopt so the strip jumps at once; the live
    // onPositionChanged above corrects on daemon notify.
    root.shownPosition = t
    if (root.player) root.player.positionChanged()
  }

  // Scrub preview: moves the strip only, writes nothing. Per-move
  // position writes queue up in the player and replay back and forth
  // after release, so a drag commits once, on release.
  function scrubTo(x, w) {
    if (!root.canSeekPosition || w <= 0) return
    root.shownPosition = NP.clampRatio(x, w) * root.lengthSec
  }

  // Active player's own volume (0..1, never the system sink).
  //
  // A player whose Volume reads -1 means "this client does not know its
  // volume" (see the MPRIS spec), and `NP.normalizeVolume` clamps that to 0 -
  // so the lane below renders an unknown level as a muted one, and a write
  // taken from it would set a player to zero. The clamp is load-bearing for
  // the fill, so it is kept; the log records the raw read instead, which is
  // how a reader tells "muted" from "unknown".
  readonly property real playerVolume: root.player !== null ? NP.normalizeVolume(root.player.volume) : 0

  function setPlayerVolume(ratio) {
    if (!root.canSetVolume || !isFinite(Number(ratio))) return false
    const current = root.playerVolume
    const next = NP.normalizeVolume(ratio)
    const unmuted = NP.volumeUnmuted(current, next)
    if (!unmuted && current > 0 && next === 0) NP.setMuteResumePending(root.player, false)
    root.player.volume = next
    // The mute-restore path is the one place that starts transport as a side
    // effect of a volume write, so it is the one place that reads the
    // transport state: a client the user has stopped stays stopped, and a
    // paused one resumes - which is exactly the state the mute paused it from.
    if (unmuted && NP.consumeMuteResume(root.player)
      && root.player.playbackState !== MprisPlaybackState.Stopped
      && root.player.canPlay === true) {
      root.player.play()
    }
    return true
  }
  function adjustPlayerVolume(direction) {
    const d = Number(direction)
    if (!root.canSetVolume || !isFinite(d) || d === 0) return false
    return root.setPlayerVolume(NP.adjustedVolume(root.playerVolume, d, Core.Audio.step))
  }
  function togglePlayerMute() {
    if (!root.canSetVolume) return false
    const next = NP.togglePlayerVolume(root.player, 0.5)
    const wasPlaying = root.playing
    const changed = root.setPlayerVolume(next)
    if (changed && next === 0) NP.setMuteResumePending(root.player, wasPlaying)
    // Muting pauses a playing client, which is a transport call the user did
    // not ask for and which no pad on the card suggests.
    if (changed && next === 0 && wasPlaying && root.player.canPause === true) {
      root.player.pause()
    }
    return changed
  }
  function resumePlayer() {
    if (!root.hasClient) return
    if (root.player.canTogglePlaying === false) return
    if (NP.consumeMuteResume(root.player) && root.playerVolume <= 0)
      root.setPlayerVolume(NP.restorePlayerVolume(root.player, 0.5))
    root.player.togglePlaying()
  }

  // mm:ss clock for the textual progress below (shared lib).
  function fmtTime(s) { return NP.fmtTime(s) }

  // Discrete MPRIS position, polled like the lockscreen: the notify
  // re-evaluates shownPosition, the strip width follows.
  //
  // Skipped while the card is on the active player: MediaEvents ticks that
  // one permanently, and this card is already re-evaluated by it. The card
  // can be parked on a second client with the arrows, and nothing else ticks
  // that one.
  Timer {
    interval: 1000
    running: root.playing && !root._seeking
      && root.player !== null && root.player !== Core.MediaState.activePlayer
    repeat: true
    onTriggered: {
      if (root.player) root.player.positionChanged()
    }
  }

  Connections {
    target: root.player
    // While scrubbing the strip belongs to the finger: daemon notifies
    // (including our own positionChanged poke in seekAt) must not yank
    // it back mid-drag. Release re-arms; the next notify settles.
    function onPositionChanged() { if (!root._seeking) root.reanchor() }
    function onPlaybackStateChanged() {
      root.reanchor()
      if (root.playing && root.playerVolume <= 0) NP.setMuteResumePending(root.player, false)
    }
  }

  Component.onCompleted: {
    root._syncArtDemand()
    OSD.retainMediaIsland(root)
    // Body focus wins over the host sink deliberately (see IslandHost),
    // but only once the island is actually shown: a focus request
    // recorded while hidden dies with the construction turn. The visible
    // arm below covers islands built hidden; this covers islands built
    // shown.
    root._primeBodyFocus()
    // The island opens on a track whose cover is usually still loading, and
    // the plain box is what the frame shows until it arrives. An artUrl that
    // was never anything else raises no change, so the flash is seeded from
    // the state the frame already opens in - unless the cover is already
    // warm (the active track's decode the warmer holds, or this island's own
    // demand from a previous open). A warm cover shows instantly like the
    // OSD instead of replaying the skeleton for a track that never left.
    if (root.artUrl !== "" && art.status === Image.Ready) {
      art.opacity = 1
      artFrame.waitingArt = false
    } else {
      let warm = false
      try { warm = Core.MediaArt.warmUrls.indexOf(root.artUrl) >= 0 } catch (e) { warm = false }
      artFrame.waitingArt = root.animOn && root.artUrl !== "" && !warm
    }
  }
  Component.onDestruction: {
    if (root._demandedArt !== "") Core.MediaArt.release(root._demandedArt)
    root._demandedArt = ""
    OSD.releaseMediaIsland(root)
  }

  // Focus request, on visible only: fires when the island shows (and at
  // construction when built shown), never while hidden.
  function _primeBodyFocus() {
    if (!root.visible) return
    Qt.callLater(() => body.forceActiveFocus())
  }
  onVisibleChanged: {
    if (root.visible) Qt.callLater(() => body.forceActiveFocus())
  }

  Item {
    id: contentRoot

    anchors.fill: parent

    // Height of the loaded content column; the island's
    // islandContentHeight binding reads it through contentRoot.
    readonly property real bodyHeight: body.implicitHeight

    Column {
      id: body

      width: parent.width
      spacing: Ui.s

      Keys.onPressed: event => {
        if (event.key === Qt.Key_Escape) {
          root.islandHost.close()
          event.accepted = true
          return
        }
        if (event.key !== Qt.Key_Left && event.key !== Qt.Key_Right) return

        const mods = event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier
          | Qt.AltModifier | Qt.MetaModifier)
        if (mods === Qt.ShiftModifier) {
          root.seekRelative(event.key === Qt.Key_Right ? 10 : -10)
          event.accepted = true
          return
        }
        if (mods !== Qt.ControlModifier) return
        if (!event.isAutoRepeat) {
          if (event.key === Qt.Key_Right) root.nextTrack()
          else root.previousTrack()
        }
        event.accepted = true
      }

      // Player-swap entrance: the card slide-fades once per user switch
      // (menu sub-glide tokens). Remap regroups and (un)pause flips stay
      // silent - nothing was swapped by the user. The island open is
      // untouched (movers are the only callers).
      function kickSwap() {
        if (root.animOn) {
          swapSlide.from = root._swapDir >= 0 ? 24 : -24
          swapSlide.restart()
          swapFade.restart()
        } else {
          body.x = 0
          body.opacity = 1
        }
      }

      NumberAnimation {
        id: swapSlide

        target: body
        property: "x"
        from: 24
        to: 0
        duration: Ui.slowMs
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: swapFade

        target: body
        property: "opacity"
        from: 0
        to: 1
        duration: Ui.slowMs
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: metaSlide

        target: metaText
        property: "x"
        from: 24
        to: 0
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: metaFade

        target: metaText
        property: "opacity"
        from: 0
        to: 1
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }

      Row {
        width: parent.width
        spacing: root.artColumnGap
        visible: root.hasClient

        Rectangle {
          id: artFrame

          // The artwork is on screen: the settled layer or the incoming
          // crossfade is painted. Chrome that belongs to the cover - the
          // scrim and the bottom fade - hangs off this rather than off a
          // load state, so a plain box still waiting on a cover carries none
          // of it.
          readonly property bool artPainted: art.opacity > 0.01 || artTop.opacity > 0.01

          // The frame is showing the plain box with a cover on its way. The
          // one state the box flashes in; the reveal clears it.
          property bool waitingArt: false

          width: root.artColumnWidth
          // Full left side: follow the right column top to bottom so no gap
          // ever opens under the art (column height is content-driven, no
          // loop). The height still tracks the metadata, so the frame is a
          // fixed width rather than a fixed rectangle - only the width is
          // what the card's own size is derived from.
          height: metaCol.height
          color: Ui.solid("background_2")
          border.width: 1
          border.color: Ui.tint("foreground_1", 0.25)

          // The plain box's skeleton wash: the frame's own fill under a tint
          // that breathes on the shared skeleton cadence while a cover is on
          // its way. `visible` follows the flash rather than the state, so a
          // box that is not waiting reads as the frame's own fill and keyline
          // and nothing more - which is also what a motion-off run gets.
          Rectangle {
            id: artWash

            anchors.fill: parent
            visible: artFlash.running
            opacity: Ui.dimmedOpacity
            color: Ui.tint("foreground_1", 0.14)

            // One cadence for every skeleton in the shell, read out of the
            // primitive rather than written again here. The primitive carries
            // its own infinite loop, which would never hand control back to
            // the ScriptAction below, so this site runs it as one cycle per
            // iteration and loops out here instead: the cycle boundary is the
            // only moment a waiting cover is allowed to fade in.
            SequentialAnimation on opacity {
              id: artFlash

              loops: Animation.Infinite
              running: root.animOn && root.hasClient && (artFrame.waitingArt || artReveal.running)

              SkeletonPulse {
                id: artPulse

                index: 0
                loops: 1
              }
              ScriptAction {
                script: artFrame.flashBoundary()
              }
              // A cover still waiting when the flash stopped without reaching
              // its boundary - the motion switch flipping under it is the only
              // way - arrives rather than leaving the frame empty.
              onStopped: {
                if (!root._artArmed) return
                root._artArmed = false
                art.opacity = 1
              }
            }
          }

          // PreserveAspectCrop scales the cover to cover the frame and drops
          // the overflow, which QtQuick crops from the centre. A wide cover
          // therefore loses its left and right thirds rather than letterboxing
          // inside a frame whose width is the one thing the card must not
          // derive from the artwork. Only the image is cropped - the frame
          // itself is the fixed-size Rectangle above.
          Image {
            id: art

            anchors.fill: parent
            visible: opacity > 0.01
            // Held down while the plain box is up: an image that paints as
            // soon as it loads is one that appears beside the flash instead
            // of on it, so the reveal below is what puts this under the wash.
            opacity: 0
            source: root.artUrl
            asynchronous: true
            cache: true
            retainWhileLoading: true
            fillMode: Image.PreserveAspectCrop
            // Same decode size as the warmer and the OSD card, so a cover
            // warmed for one surface hits the shared pixmap cache for this
            // one instead of decoding a second raster for the same url.
            sourceSize.width: 256
            sourceSize.height: 256

            onStatusChanged: {
              if (status === Image.Ready && root.artUrl !== "") artFrame.coverLanded()
              else if (status === Image.Error) artFrame.coverFailed()
            }
          }

          // Incoming cover: crossfades over the settled one on track
          // switch instead of swapping instantly.
          Image {
            id: artTop

            anchors.fill: parent
            visible: opacity > 0.01
            opacity: 0
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 256
            sourceSize.height: 256

            onStatusChanged: {
              if (status === Image.Ready && root.artUrl !== ""
                && String(artTop.source) === root.artUrl
                && !artFrame.waitingArt) artFade.restart()
            }
          }

          NumberAnimation {
            id: artFade

            target: artTop
            property: "opacity"
            from: 0
            to: 1
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
            onFinished: {
              if (String(artTop.source) !== root.artUrl) return
              // `art` follows the url on its own and has already loaded it
              // beside this crossfade, so there is nothing to commit here:
              // the incoming layer steps aside and the settled one holds it.
              artTop.opacity = 0
            }
          }

          // The reveal: the artwork fading in as the flash's rising leg.
          // The duration is the primitive's, so the cover cannot drift off
          // the cadence it is arriving on, and the leg itself is the
          // animation - this only supplies when it starts.
          NumberAnimation {
            id: artReveal

            target: art
            property: "opacity"
            from: 0
            to: 1
            duration: MotionPolicy.duration(artPulse.fadeMs)
            easing.type: Easing.InOutQuad
          }

          // The cover landed. While the plain box is flashing it waits for
          // the end of the cycle and fades in on the next flash; with no
          // flash running there is no flash to arrive on, so it is simply up.
          function coverLanded() {
            if (!artFlash.running) {
              art.opacity = 1
              return
            }
            root._artArmed = true
          }

          // The load ended without a pixmap, so no cover is arriving: the box
          // stops waiting and holds its own fill.
          function coverFailed() {
            root._artArmed = false
            waitingArt = false
          }

          // One flash has completed and the next is starting. The only moment
          // a waiting cover may fade in, which is what makes the artwork read
          // as part of the flashing animation rather than beside it.
          function flashBoundary() {
            if (!root._artArmed) return
            root._artArmed = false
            waitingArt = false
            artReveal.restart()
          }

          Rectangle {
            anchors.fill: parent
            visible: artFrame.artPainted && root.hasClient
            color: Qt.rgba(0, 0, 0, 0.38)
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 28
            visible: artFrame.artPainted && root.hasClient
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

          Icon {
            anchors.centerIn: parent
            // The frame's placeholder: a client with nothing named in it
            // (no title yet, or a fresh one that never played).
            visible: !root.hasTrack
            name: "music"
            colorKey: "foreground_1"
            size: 48
          }

          Rectangle {
            anchors.fill: parent
            visible: artMouse.containsMouse
            color: Ui.tint("foreground_0", 0.07)
          }

          MouseArea {
            id: artMouse

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
              if (mouse.button === Qt.RightButton) return
              root.islandHost.close()
              if (root.hasTrackLink) Exec.run(["xdg-open", root.trackUrl])
            }
          }
        }

        Column {
          id: metaCol

          width: root.metaColumnWidth
          anchors.verticalCenter: parent.verticalCenter
          spacing: 5

          Column {
            id: metaText

            width: parent.width
            spacing: 5
            clip: true

            // Track-change entrance: same slide-fade language as the
            // player-swap kickSwap above, scoped to the three name
            // rows only. Clipped, so text never slides over the art;
            // progress and pads never move (island-wide motion is for
            // player switches only).
            function kickMeta() {
              if (root.animOn) {
                metaSlide.from = root._swapDir >= 0 ? 24 : -24
                metaSlide.restart()
                metaFade.restart()
              } else {
                metaText.x = 0
                metaText.opacity = 1
              }
            }

            Row {
              width: parent.width
              spacing: 7

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "music-track"
                colorKey: "accent"
                size: 16
              }

              Item {
                id: titleMarquee

                width: parent.width - 16 - 7
                height: titleText.implicitHeight
                clip: true

                readonly property real overflow: Math.max(0, titleText.implicitWidth - width)
                readonly property int legMs: Math.max(1800, Math.min(9000,
                  Math.round(1800 + overflow * 24)))
                readonly property int endpointPauseMs: 400

                function reset() {
                  titleText.x = 0
                  if (root.marqueeEnabled && !root.linkCopied && titleMarquee.overflow > 0)
                    titleMarqueeAnimation.restart()
                  else
                    titleMarqueeAnimation.stop()
                }

                onWidthChanged: titleMarquee.reset()

                SequentialAnimation {
                  id: titleMarqueeAnimation

                  running: root.marqueeEnabled && !root.linkCopied && titleMarquee.overflow > 0
                  loops: Animation.Infinite
                  NumberAnimation {
                    target: titleText
                    property: "x"
                    from: 0
                    to: -titleMarquee.overflow
                    duration: titleMarquee.legMs
                    easing.type: Easing.InOutSine
                  }
                  PauseAnimation {
                    duration: titleMarquee.endpointPauseMs
                  }
                  NumberAnimation {
                    target: titleText
                    property: "x"
                    from: -titleMarquee.overflow
                    to: 0
                    duration: titleMarquee.legMs
                    easing.type: Easing.InOutSine
                  }
                  PauseAnimation {
                    duration: titleMarquee.endpointPauseMs
                  }
                  onStopped: titleText.x = 0
                }

                Text {
                  id: titleText

                  width: root.marqueeEnabled ? implicitWidth : titleMarquee.width
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.linkCopied ? "Copied!" : (root.title !== "" ? root.title : "--")
                  color: Ui.solid("foreground_0")
                  font.pixelSize: 12
                  font.family: Ui.fontFamily
                  font.bold: true
                  font.underline: root.titleHover && root.hasTrackLink
                  elide: root.marqueeEnabled ? Text.ElideNone : Text.ElideRight
                  wrapMode: Text.NoWrap
                  textFormat: Text.PlainText
                  onTextChanged: titleMarquee.reset()
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: root.hasTrackLink
                  hoverEnabled: true
                  cursorShape: root.hasTrackLink ? Qt.PointingHandCursor : Qt.ArrowCursor
                  acceptedButtons: Qt.LeftButton
                  onEntered: root.titleHover = true
                  onExited: root.titleHover = false
                  onClicked: root.flashCopied()
                }
              }
            }

            Row {
              width: parent.width
              spacing: 7

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "music-artist"
                colorKey: "foreground_1"
                size: 15
              }

              Text {
                width: parent.width - 15 - 7
                anchors.verticalCenter: parent.verticalCenter
                text: root.artist !== "" ? root.artist : "--"
                color: Ui.tint("foreground_1", 0.7)
                font.pixelSize: 11
                font.family: Ui.fontFamily
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
            }

            Row {
              width: parent.width
              spacing: 7

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "music-album"
                colorKey: "foreground_1"
                size: 16
              }

              Item {
                id: albumMarquee

                width: parent.width - 16 - 7
                height: albumText.implicitHeight
                clip: true

                readonly property real overflow: Math.max(0, albumText.implicitWidth - width)
                readonly property int legMs: Math.max(1800, Math.min(9000,
                  Math.round(1800 + overflow * 24)))
                readonly property int endpointPauseMs: 400

                function reset() {
                  albumText.x = 0
                  if (root.marqueeEnabled && albumMarquee.overflow > 0)
                    albumMarqueeAnimation.restart()
                  else
                    albumMarqueeAnimation.stop()
                }

                onWidthChanged: albumMarquee.reset()

                SequentialAnimation {
                  id: albumMarqueeAnimation

                  running: root.marqueeEnabled && albumMarquee.overflow > 0
                  loops: Animation.Infinite
                  NumberAnimation {
                    target: albumText
                    property: "x"
                    from: 0
                    to: -albumMarquee.overflow
                    duration: albumMarquee.legMs
                    easing.type: Easing.InOutSine
                  }
                  PauseAnimation {
                    duration: albumMarquee.endpointPauseMs
                  }
                  NumberAnimation {
                    target: albumText
                    property: "x"
                    from: -albumMarquee.overflow
                    to: 0
                    duration: albumMarquee.legMs
                    easing.type: Easing.InOutSine
                  }
                  PauseAnimation {
                    duration: albumMarquee.endpointPauseMs
                  }
                  onStopped: albumText.x = 0
                }

                Text {
                  id: albumText

                  width: root.marqueeEnabled ? implicitWidth : albumMarquee.width
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.album !== "" ? root.album : "--"
                  color: Ui.tint("foreground_1", 0.55)
                  font.pixelSize: 11
                  font.family: Ui.fontFamily
                  elide: root.marqueeEnabled ? Text.ElideNone : Text.ElideRight
                  wrapMode: Text.NoWrap
                  textFormat: Text.PlainText
                  onTextChanged: albumMarquee.reset()
                }
              }
            }
          }

          // Spotify-style progress: elapsed, seek lane, total in one
          // row. The lane keeps the click/drag/wheel seek contract.
          //
          // The row stays visible for a player with no length, because the
          // elapsed counter is the only time information a stream has. The
          // dim lives on the lane rather than here: the row is a readout and
          // the lane is the control, and the row already carries a dim of its
          // own for a client that is not playing, which is a transport state
          // and not a capability.
          Row {
            width: parent.width
            spacing: root.laneGap
            visible: root.hasClient
            opacity: root.playing ? 1 : 0.5

            Behavior on opacity {
              enabled: root.animOn
              NumberAnimation {
                duration: Ui.fastMs
                easing.type: Easing.OutCubic
              }
            }

            // The elapsed counter, at the column's left edge with no glyph
            // ahead of it: the row is two readouts and a control, and a leading
            // icon only borrowed width the lane could have had. The column is
            // the track's own length, so the digits sit against the lane with
            // no leftover between them.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: root.timeColumnWidth
              text: root.lengthSec > 0 ? root.fmtTime(root.shownPosition, root.lengthSec) : "--:--"
              color: Ui.tint("foreground_1", 0.55)
              font.pixelSize: Ui.fontXs
              font.family: Ui.fontFamily
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }

            Item {
              width: root.seekLaneWidth
              height: 18
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
                height: 6
                anchors.verticalCenter: parent.verticalCenter
                color: Ui.tint("foreground_1", 0.25)

                Rectangle {
                  width: parent.width * root.progressRatio
                  height: parent.height
                  color: Ui.solid("accent")

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
                      // The drag commits once, here, on release - the same
                      // reason `scrubTo` writes nothing: a per-move position
                      // write replays back and forth after the release.
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

            // The total, at the row's right end in the same column as the
            // elapsed counter, so the two ends of the lane are readouts of
            // identical measure and the row reads as the shape of the thing it
            // controls: how far in, how far to go, and the control between.
            //
            // Both take the length as their reference, so the hour appears for
            // both or neither and the shape cannot change mid-track at the
            // 59:59 -> 1:00:00 crossing. A player with no length gets the
            // placeholder rather than a running counter: a counter with nothing
            // to count toward reads as a broken bar.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: root.timeColumnWidth
              text: root.lengthSec > 0 ? root.fmtTime(root.lengthSec, root.lengthSec) : "--:--"
              color: Ui.tint("foreground_1", 0.55)
              font.pixelSize: Ui.fontXs
              font.family: Ui.fontFamily
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }

          // Player volume: the Volume island slider language (sharp
          // 6px track, direct drag, wheel steps). Icon tiers follow
          // the level through the Audio service thirds.
          //
          // A player that does not take a volume write is grayed, not
          // hidden: the row still shows what the player reports, and the
          // annotator's split says how. `actionable` keeps the button and
          // the lane in the hit-test chain so Qt.ForbiddenCursor actually
          // reaches the user, the handlers guard on the same flag to stay
          // inert, and the row's opacity carries the dim.
          //
          // The row is [icon][lane][percentage]: the pad at the row's left edge
          // where the icon rows above put theirs, the lane hard against it, the
          // level at the right end. One lead and one short readout against the
          // progress row's two time columns and no lead, so this lane is the
          // longer of the two - by exactly what the progress row spends on
          // readouts - and neither row has width reserved against it.
          Row {
            width: parent.width
            spacing: root.laneGap
            visible: root.hasClient
            opacity: root.canSetVolume ? 1 : 0.5

            Behavior on opacity {
              enabled: root.animOn
              NumberAnimation {
                duration: Ui.fastMs
                easing.type: Easing.OutCubic
              }
            }

            // `slotSize` is the button's own square target and its own width
            // (IconButton sizes itself from it), so the lane's lead is the pad
            // and nothing more.
            IconButton {
              name: Core.Audio.volumeIconFor(root.playerVolume, false)
              colorKey: "foreground_1"
              accentKey: root.playerVolume <= 0.01 ? "red" : ""
              dimTiers: Core.Audio.volumeDimTiersFor(root.playerVolume, false)
              iconSize: root.muteSlot
              slotSize: root.muteSlot
              flat: true
              cornerRadius: RoundingPolicy.radius
              animationsEnabled: root.animOn
              actionable: root.canSetVolume
              onClicked: root.togglePlayerMute()

              // A handler rather than a mouse area: it does not take the
              // click, and unlike `enabled: false` it keeps setting the
              // cursor for a button the shell has made inert.
              HoverHandler {
                cursorShape: root.canSetVolume ? Qt.PointingHandCursor : Qt.ForbiddenCursor
              }

              WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                  if (!root.adjustPlayerVolume(event.angleDelta.y)) return
                  event.accepted = true
                }
              }
            }

            Item {
              id: volLane

              width: root.volumeLaneWidth
              height: 18
              anchors.verticalCenter: parent.verticalCenter

              property bool dragging: false
              property real pressX: 0

              Rectangle {
                width: parent.width
                height: 6
                anchors.verticalCenter: parent.verticalCenter
                color: Ui.tint("foreground_1", 0.25)

                Rectangle {
                  width: parent.width * Math.max(0, Math.min(1, root.playerVolume))
                  height: parent.height
                  color: Ui.solid("accent")

                  Behavior on width {
                    enabled: root.animOn && !volLane.dragging
                    NumberAnimation {
                      duration: Ui.normalMs
                      easing.type: Easing.OutCubic
                    }
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                anchors.topMargin: -6
                anchors.bottomMargin: -6
                hoverEnabled: true
                cursorShape: root.canSetVolume ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                acceptedButtons: Qt.LeftButton
                // Seek-lane rule: clicks glide to the point, sustained
                // drags (past 6px) snap and commit on release. Every
                // write is guarded on the gate, which is what leaves an
                // inert lane inert while its cursor still reads as
                // forbidden.
                onPressed: mouse => {
                  if (!root.canSetVolume) return
                  volLane.pressX = mouse.x
                }
                onPositionChanged: mouse => {
                  if (!root.canSetVolume || !pressed) return
                  if (Math.abs(mouse.x - volLane.pressX) > 6) {
                    volLane.dragging = true
                    root.setPlayerVolume(mouse.x / width)
                  }
                }
                onReleased: mouse => {
                  if (root.canSetVolume) root.setPlayerVolume(mouse.x / width)
                  volLane.dragging = false
                }
                // Same release rule as the seek lane above: an
                // interrupted drag must never stick `dragging` on.
                onCanceled: volLane.dragging = false
              }

              WheelHandler {
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                onWheel: event => {
                  if (!root.adjustPlayerVolume(event.angleDelta.y)) return
                  event.accepted = true
                }
              }
            }

            // The level, at the row's right end in a three-digit reserve so
            // `9%` and `100%` leave the lane exactly where it is, and
            // right-aligned so the number sits on the card's right margin
            // where the volume row's edge is, rather than drifting with its own
            // width.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: root.percentColumnWidth
              horizontalAlignment: Text.AlignRight
              text: Math.round(root.playerVolume * 100) + "%"
              color: Ui.tint("foreground_1", 0.55)
              font.pixelSize: Ui.fontXs
              font.family: Ui.fontFamily
              textFormat: Text.PlainText
              elide: Text.ElideRight
            }
          }

          Row {
            width: parent.width
            spacing: Ui.s

            IconButton {
              name: "arrow-left-to-line"
              iconSize: 20
              slotSize: 32
              flat: true
              cornerRadius: RoundingPolicy.radius
              animationsEnabled: root.animOn
              enabled: root.canPrev
              onClicked: root.prevPlayer()
            }

            // Tint crossfade: the icon raster cannot morph, so a
            // foreground layer and an accent layer blend in opposite
            // directions on state change. No dip, no flicker; the slot
            // (hover wash, border, clicks) stays on the bottom button.
            Item {
              id: shuffleWrap

              width: 32
              height: 32

              property real shuffleTint: root.shuffling ? 1 : 0
              Behavior on shuffleTint {
                enabled: root.animOn
                NumberAnimation {
                  duration: Ui.slowMs
                  easing.type: Easing.OutCubic
                }
              }

              IconButton {
                id: shuffleBtn

                anchors.fill: parent
                name: "shuffle"
                  iconSize: 20
                slotSize: 32
                flat: true
                cornerRadius: RoundingPolicy.radius
                colorKey: "foreground_0"
                animationsEnabled: root.animOn
                enabled: root.canShuffle
                opacity: enabled ? 1 : 0.4
                iconOpacity: 1 - shuffleWrap.shuffleTint
                onClicked: root.toggleShuffle()

                Icon {
                  anchors.centerIn: parent
                  name: "shuffle"
                  colorKey: "accent"
                  size: 20
                  opacity: (shuffleBtn.enabled ? 1 : 0.4) * shuffleWrap.shuffleTint
                }
              }
            }

            IconButton {
              name: "skip-back"
              iconSize: 20
              slotSize: 32
              flat: true
              cornerRadius: RoundingPolicy.radius
              animationsEnabled: root.animOn
              enabled: root.hasTrack && root.player?.canGoPrevious !== false
              onClicked: root.previousTrack()
            }

            Item {
              width: 32
              height: 32

              IconButton {
                anchors.centerIn: parent
                name: "play"
                  iconSize: 20
                slotSize: 32
                flat: true
                cornerRadius: RoundingPolicy.radius
                animationsEnabled: root.animOn
                opacity: !root.playing && root.hasClient ? 1 : 0
                x: !root.playing ? 0 : -8
                visible: opacity > 0.01
                z: root.playing ? 0 : 1
                enabled: root.hasClient && root.player?.canTogglePlaying !== false && !root.playing
                onClicked: root.resumePlayer()

                Behavior on opacity {
                  enabled: root.animOn
                  NumberAnimation {
                    duration: Ui.fastMs
                    easing.type: Easing.OutCubic
                  }
                }
                Behavior on x {
                  enabled: root.animOn
                  NumberAnimation {
                    duration: Ui.fastMs
                    easing.type: Easing.OutCubic
                  }
                }
              }

              IconButton {
                anchors.centerIn: parent
                name: "pause"
                  iconSize: 20
                slotSize: 32
                flat: true
                cornerRadius: RoundingPolicy.radius
                animationsEnabled: root.animOn
                opacity: root.playing && root.hasClient ? 1 : 0
                x: root.playing ? 0 : 8
                visible: opacity > 0.01
                z: root.playing ? 1 : 0
                enabled: root.hasClient && root.player?.canTogglePlaying !== false && root.playing
                onClicked: root.player.togglePlaying()

                Behavior on opacity {
                  enabled: root.animOn
                  NumberAnimation {
                    duration: Ui.fastMs
                    easing.type: Easing.OutCubic
                  }
                }
                Behavior on x {
                  enabled: root.animOn
                  NumberAnimation {
                    duration: Ui.fastMs
                    easing.type: Easing.OutCubic
                  }
                }
              }
            }

            IconButton {
              name: "skip-forward"
              iconSize: 20
              slotSize: 32
              flat: true
              cornerRadius: RoundingPolicy.radius
              animationsEnabled: root.animOn
              enabled: root.hasTrack && root.player?.canGoNext !== false
              onClicked: root.nextTrack()
            }

            // Tint crossfade, same as shuffle above: foreground and
            // accent layers blend on loop change. Glyph swaps with the
            // loop mode on both layers at once (no blank frame).
            Item {
              id: repeatWrap

              width: 32
              height: 32

              property real repeatTint: root.looping ? 1 : 0
              Behavior on repeatTint {
                enabled: root.animOn
                NumberAnimation {
                  duration: Ui.slowMs
                  easing.type: Easing.OutCubic
                }
              }

              IconButton {
                id: repeatBtn

                anchors.fill: parent
                name: root.loopOne ? "repeat-1" : "repeat"
                  iconSize: 20
                slotSize: 32
                flat: true
                cornerRadius: RoundingPolicy.radius
                colorKey: "foreground_0"
                animationsEnabled: root.animOn
                enabled: root.canLoop
                opacity: enabled ? 1 : 0.4
                iconOpacity: 1 - repeatWrap.repeatTint
                onClicked: root.cycleLoop()

                Icon {
                  anchors.centerIn: parent
                  name: root.loopOne ? "repeat-1" : "repeat"
                  colorKey: "accent"
                  size: 20
                  opacity: (repeatBtn.enabled ? 1 : 0.4) * repeatWrap.repeatTint
                }
              }
            }

            IconButton {
              name: "arrow-right-to-line"
              iconSize: 20
              slotSize: 32
              flat: true
              cornerRadius: RoundingPolicy.radius
              animationsEnabled: root.animOn
              enabled: root.canNext
              onClicked: root.nextPlayer()
            }
          }
        }
      }

      // The empty state, and it means what it says: no client in the view at
      // all. Reached when the last one leaves between the click that opened
      // the island and the island's own first paint, or when every client is
      // filtered out as a browser. A client that is merely paused is not here
      // - the card above is, and the play pad on it is what resumes it.
      Text {
        visible: !root.hasClient
        width: parent.width
        horizontalAlignment: Text.AlignHCenter
        text: "No media playing"
        color: Ui.tint("foreground_1", 0.55)
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
        textFormat: Text.PlainText
      }
    }
  }
}
