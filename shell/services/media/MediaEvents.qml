pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
// qs.services exports a Timer singleton, and an unaliased self-import
// would shadow the QtQuick one this file's position tick uses, so the
// state owner is named through the module alias.
import qs.services as Core
import qs.common
import "../../common/NowPlaying.js" as NP

// MediaEvents - the resident MPRIS observer. It owns exactly two things:
// the signal wiring onto the active player, and the 1s position tick
// that fills the sample ring the pop policy reads. What it produces is a
// classification - a new track, a start, a pause, a stop, a player swap -
// published to MediaState. Whether that is shown, and how, belongs to the
// surface (OSD.qml): this file reads no setting, names no view, and never
// mentions the OSD.
//
// Why it stays resident instead of tracking lazily: the pop policy needs
// the sample ring, and an empty ring reads as a skip, so a tracker that
// started on its first consumer would misjudge the first change it saw. A
// track change is one MPRIS signal that nothing replays, so a tracker torn
// down while no consumer existed would miss it outright. The cost of
// staying resident is one Connections block on the active player and one
// 1s timer that runs only while a player is on the bus - with no player
// there is no polling at all.
Singleton {
  id: root

  readonly property string tag: "mediaEvents"

  property bool _seeded: false
  property var _lastPlayer: null
  property string _trackKey: ""
  property int _playbackState: -1
  // Shuffle and repeat are the two MPRIS properties this file observes but
  // publishes nothing for: no surface in the shell draws them, and they are
  // mode state rather than a track or a transport change, so they take the
  // same queued-observation path as playback and are reported on their own.
  // -1 is "not read for this player", which is what keeps a value the player
  // already had at arrival from being reported as a change the user made.
  property int _shuffle: -1
  property int _loopState: -1
  // Whether this file has EVER reported a player, as opposed to seeding one.
  // The seed flag is cleared by _reset() on every departure, so it cannot
  // distinguish "the shell just started" from "a player arrived after the last
  // one left" - and those two are the difference between a DEBUG line and an
  // INFO one. Deliberately not cleared by _reset(): it is a statement about
  // the shell's lifetime, not about the current set.
  property bool _everSeen: false
  // The capability record of the active player, and the player it was read
  // from. null means "not read for this player", which is what keeps a
  // capability the player already had at arrival from being reported as one it
  // just lost. The player reference is what makes a late signal from a
  // replaced player a no-op rather than a diff against the wrong baseline.
  property var _lastCaps: null
  property var _capPlayer: null
  // The last Volume this file read, and whether it has read one. MPRIS uses a
  // negative Volume for "this player does not know its volume", and
  // `NP.normalizeVolume` clamps that to 0 - so a naive line would report a
  // player that does not know its level as a player that is muted. The raw
  // number is kept for exactly that reason.
  property var _volumeSeen: null
  // The set of clients this file has already seen, as diff keys. Registration
  // is set MEMBERSHIP, not the head of the set: `NowPlaying.qml`'s slot comes up
  // "whenever a client is registered, playing or not", and a second client that
  // registers while the first is active never reaches `_activeChanged`. Kept
  // here rather than derived, because a diff needs the previous set and a
  // binding over `Core.MediaState.players` cannot remember one.
  property var _seenClients: ({})
  // Newest-first ring of position samples, capped by noteSample. It is
  // the only thing that separates an auto-advance from a skip.
  property var _samples: []
  property bool _observeQueued: false
  property bool _playbackQueued: false
  property bool _volumeQueued: false

  function _reset() {
    root._seeded = false
    root._lastPlayer = null
    root._trackKey = ""
    root._playbackState = -1
    root._shuffle = -1
    root._loopState = -1
    // Same reason as _playbackState: a capability or a level the new player
    // already had at arrival is not a change the user made. `_everSeen` is
    // deliberately NOT cleared - it is about the shell's lifetime, not the set.
    root._lastCaps = null
    root._capPlayer = null
    root._volumeSeen = null
    root._samples = []
    // The stall counter is per-player state sitting in a file whose lifetime is
    // the shell's, so it has to be cleared here or it survives a swap. A player
    // that stalled twice in a row reports its second stall one tick early,
    // because the counter arrives primed. Caught by the media agent reading
    // this file after I wrote it - the counter is only reachable from the tick
    // and from its own reset, so nothing else would ever have cleared it.
    root._stalledTicks = -1
  }

  // A client's own name, for a line that has to say which client it is about.
  // MPRIS `Identity` is the spec's human-readable name for a client - the same
  // bounded, client-supplied string as an app name - and the bus name is the
  // fallback for a client that declares none.
  //
  // NOT `NP.playerKey`, which is the obvious helper here and the wrong one: it
  // falls back to a digest of `trackTitle`/`trackArtist`/`trackAlbum` when a
  // client publishes neither a unique id nor a track id, so a line carrying it
  // would carry a handle on what was playing. This file's rule is that no line
  // names the track.
  function _clientName(p) {
    if (!p) return "unknown"
    const identity = String(p.identity ?? "")
    if (identity !== "") return identity
    return String(p.dbusName ?? "") === "" ? "unknown" : String(p.dbusName)
  }

  // The diff key. The bus name first because it is unique per client and two
  // clients can legitimately publish the same identity - which is why this is
  // not the name the line prints.
  function _clientKey(p) {
    if (!p) return ""
    const bus = String(p.dbusName ?? "")
    if (bus !== "") return "bus:" + bus
    return "identity:" + String(p.identity ?? "")
  }

  // A client joined the set. The one thing the media contract has no event for:
  // `publish()` fires on the ACTIVE player changing, so a client that registers
  // without taking the head is invisible to every subscriber - and "a client
  // registered but nothing showed up" is precisely what this line exists to
  // answer.
  function _playersChanged() {
    const players = Core.MediaState.players
    const seen = Object.assign({}, root._seenClients)
    let joined = 0
    for (let i = 0; i < players.length; i++) {
      const key = root._clientKey(players[i])
      if (key === "" || seen[key] === true) continue
      seen[key] = true
      joined++
      const name = root._clientName(players[i])
      // The first client of a shell's life is DEBUG and every later one is
      // INFO, which is what `_everSeen` was added for: a shell that starts
      // with music already playing is not an event, and one that gains a
      // client after another left is. `_everSeen` is about the shell's
      // lifetime rather than the current set, so a client arriving after the
      // last one left is still INFO - which is the case a reader needs.
      if (root._everSeen) {
        Log.info("registered player (" + Log.summarize(name) + "), total " + Core.MediaState.players.length)
        // Inside the INFO branch and not after the if/else: the shell's first
        // client is reported at DEBUG (see `_everSeen`), and a DEBUG line whose
        // parent is a DEBUG line is not the shape this tree's contract allows -
        // it would carry the same event at the same weight twice.
        const d = Log.at()
        if (d.allows("debug")) {
          // `key` rather than `dbusName`: it IS the bus name, prefixed, and it
          // is what this file files the client under, so it is the thing a
          // reader wants to grep for when two clients publish one identity.
          // The identity above is client-supplied text off the bus and unbounded
          // there, so it goes through `summarize` here even though the INFO
          // prints it whole - a summary is the INFO's own prefix plus the length
          // it was cut at, so the pair still correlates.
          //
          // `set N + M` is the diff's shape and `M` is a running count WITHIN
          // this evaluation, so one burst of re-announces reads as the same `N`
          // with `+1 +2 +3` beside it and three unrelated arrivals do not. That
          // distinction is the reason this line exists at all: the set wrapper
          // rebuilds under every client, and without it a reader cannot tell a
          // re-register from a newcomer.
          const filed = Object.keys(root._seenClients).length
          d.debug("registered player (" + Log.summarize(name) + "), total "
            + Core.MediaState.players.length + ": filed under "
            + Log.summarize(key) + ", set " + filed + " + " + joined)
        }
      } else {
        Log.debug("registered player (" + Log.summarize(name) + "), total " + Core.MediaState.players.length)
      }
      root._everSeen = true
    }
    // Only the growth is recorded. A departure is not this line's business and
    // a line that reported both ways would report the same set twice on a
    // re-registering client - which some do, since MPRIS clients re-announce.
    if (joined > 0) root._seenClients = seen
  }

  // The active player arrived, changed or left. A swap carries the player
  // it replaced, so a surface can drop a card still showing it, and a
  // player that came up already playing is a transport event in its own
  // right. The first sighting only seeds: there is no card to invalidate
  // and no change to announce.
  function _activeChanged() {
    const p = Core.MediaState.activePlayer
    const previous = root._lastPlayer
    if (!p) {
      Core.MediaState.publish("player", null, previous)
      root._reset()
      return
    }
    const changed = previous !== p
    root._lastPlayer = p
    root._trackKey = String(p.trackTitle ?? "") === "" ? "" : NP.playerKey(p)
    root._playbackState = p.playbackState
    // A player arrives carrying whatever shuffle and repeat it was already set
    // to. Seeding here is what keeps the arrival from being read as a mode
    // change the user never made, the same reason _playbackState is read
    // above rather than observed.
    root._shuffle = p.shuffleSupported ? (p.shuffle ? 1 : 0) : -1
    root._loopState = p.loopSupported ? Number(p.loopState) : -1
    // The capability record is taken before any of the returns below, because
    // it is the baseline the first capability signal after the switch is
    // compared against. A capability that arrives with the player is part of
    // arriving.
    const caps = root._caps(p)
    root._lastCaps = caps
    root._capPlayer = p
    if (!root._seeded) {
      root._seeded = true
      root._everSeen = true
      return
    }
    if (!changed) return
    Core.MediaState.publish("player", p, previous)
    if (p.playbackState === MprisPlaybackState.Playing) root._commitTransport()
  }

  // The capability set, as one object so that a change to it is a diff rather
  // than a sentence, and so that the same record answers both questions: what
  // a player can do when it registers, and what it stopped being able to do.
  //
  // Every flag is read `=== true`, the STRICTER of the two rules the tree
  // applies to these properties - the island's shuffle and loop gates read
  // them `!== false`, the volume and seek gates read them `=== true`. The
  // strict reading is the one that belongs in a diagnostic: a client that
  // leaves a property undeclared then reads as not offering it, which is the
  // answer that explains a pad doing nothing, where the lenient rule would
  // print `yes` for a property that was never sent.
  //
  // The list is the capabilities the shell's own controls gate on. `canQuit`
  // and `canRaise` are real MPRIS flags and deliberately absent: nothing in
  // the tree reads them, so a line about them is a line about something no
  // control can act on.
  readonly property var capKeys: [
    "canControl",
    "canPlay",
    "canPause",
    "canTogglePlaying",
    "canSeek",
    "canGoNext",
    "canGoPrevious",
    "volumeSupported",
    "positionSupported",
    "lengthSupported",
    "shuffleSupported",
    "loopSupported"
  ]

  function _caps(p) {
    const out = {}
    for (let i = 0; i < root.capKeys.length; i++) out[root.capKeys[i]] = p[root.capKeys[i]] === true
    return out
  }

  // Several signals describe one track change (Metadata, TrackTitle,
  // PostTrack), so the reads are coalesced into one queued observation.
  function _queueTrackObservation() {
    if (root._observeQueued) return
    root._observeQueued = true
    Qt.callLater(root._observeTrack)
  }

  function _observeTrack() {
    root._observeQueued = false
    const p = Core.MediaState.activePlayer
    if (!p || root._lastPlayer !== p) return
    const key = NP.playerKey(p)
    if (key === "" || key === root._trackKey) return
    const oldKey = root._trackKey
    const prev = NP.lastSampleFor(root._samples, oldKey)
    const hadTrack = oldKey !== ""
    root._trackKey = key
    root._playbackState = p.playbackState
    // The pop policy is the other half of a track change: a track that
    // advanced on its own must still raise the OSD, and the sample ring that
    // decides it is invisible by construction. The inputs are read from NP
    // rather than a second copy of the policy here, which would drift:
    // `manual` is the shell's own transport stamp, `previous` whether the old
    // track was ever sampled at all, and `ended` whether its newest sample sat
    // at its end - which together are the whole of what shouldPopOsd reads.
    const stamp = NP.manualFresh(3000)
    const popped = hadTrack && NP.shouldPopOsd(stamp, prev, hadTrack)
    if (!popped) return
    root._commit(p, key, "track")
  }

  function _queuePlaybackObservation() {
    if (root._playbackQueued) return
    root._playbackQueued = true
    Qt.callLater(root._observePlayback)
  }

  function _observePlayback() {
    root._playbackQueued = false
    const p = Core.MediaState.activePlayer
    if (!p) return
    if (!root._seeded || root._lastPlayer !== p) {
      root._activeChanged()
      return
    }
    const state = p.playbackState
    if (state === root._playbackState) return
    root._playbackState = state
    if (state === MprisPlaybackState.Stopped) {
      Core.MediaState.publish("stopped", p)
      return
    }
    root._commitTransport()
  }

  // Shuffle and repeat, read together. They are independent properties with
  // independent change signals, and a player that changes both in one gesture
  // raises both, so one observation settles whichever actually moved rather
  // than reading each signal on its own.
  //
  // Nothing here is published: no surface draws these, so the two baselines
  // are the whole of the state. They still have to be read, because they are
  // what stops a player's own arrival-time values from being read later as a
  // gesture the user made.
  function _observeModes() {
    const p = Core.MediaState.activePlayer
    if (!p) return

    if (p.shuffleSupported) {
      const now = p.shuffle ? 1 : 0
      root._shuffle = now
    }
    if (p.loopSupported) {
      root._loopState = Number(p.loopState)
    }
  }

  // A capability that moves while the player is registered is a change the
  // user can see and nothing else announces: a remote or companion client that
  // takes control away dims the pads and stops the keys, and the shell has no
  // other way to tell that apart from a pad that is broken.
  //
  // MPRIS re-publishes its whole flag set as a client settles, so the read is
  // continuous rather than discrete and a client that re-publishes the same
  // flags is the common case. The record is kept as the baseline the next
  // signal is compared against, and a signal that arrives after the player was
  // replaced is dropped rather than diffed against the wrong one.
  function _observeCaps() {
    const p = Core.MediaState.activePlayer
    if (!p) return
    root._lastCaps = root._caps(p)
    root._capPlayer = p
  }

  // Volume is the one MPRIS number that is not a fact about a control: a
  // client can declare Volume, answer a write with success and never apply it
  // (see the volume section in MediaState for the round trip that finds that
  // out), and MPRIS reserves a NEGATIVE value for "this player does not know
  // its volume". `NP.normalizeVolume` clamps that to 0, so anything built from
  // the normalized number would read a player that does not know its level as
  // a player that is muted - the raw read is what gets kept.
  function _observeVolume() {
    // The queue flag is cleared FIRST, and that is the whole contract of this
    // function. `_volumeQueued` is what makes several Volume signals inside
    // one turn collapse into one observation, and a flag that is set on the
    // way in and never cleared latches: the second and every later volume
    // change of the session is dropped on the floor with no error, which is
    // exactly the failure the other two queued observers avoid by resetting
    // their flags here.
    root._volumeQueued = false
    const p = Core.MediaState.activePlayer
    if (!p) {
      root._volumeSeen = null
      return
    }
    const raw = Number(p.volume)
    const was = root._volumeSeen
    root._volumeSeen = raw
    // A level the player already had when it registered is a level the user
    // set somewhere else, not a change this shell is reporting, so the first
    // read only seeds.
    if (was === null || was === raw) return
  }

  function _commitTransport() {
    const p = Core.MediaState.activePlayer
    if (!p) return
    root._commit(p, NP.playerKey(p), "transport")
  }

  // Last gate before publishing: the event must still describe the active
  // player and the track it was read from, and a player with no title has
  // no track to name. A player that vanished or changed track inside the
  // observation window publishes nothing.
  function _commit(p, key, kind) {
    if (!p || p !== Core.MediaState.activePlayer || NP.playerKey(p) !== key) return
    if (String(p.trackTitle ?? "") === "") return
    Core.MediaState.publish(kind, p, null)
  }

  // The one subscription to the state owner. The active player is the
  // only thing this file tracks, and the state owner is the only reader
  // of the backend set, so a new player arrives as one change here.
  Connections {
    target: Core.MediaState

    function onActivePlayerChanged() { root._activeChanged() }
    function onPlayersChanged() { root._playersChanged() }
  }

  Connections {
    target: Core.MediaState.activePlayer

    function onPostTrackChanged() { root._queueTrackObservation() }
    function onMetadataChanged() { root._queueTrackObservation() }
    function onUniqueIdChanged() { root._queueTrackObservation() }
    function onTrackTitleChanged() { root._queueTrackObservation() }
    function onTrackArtistChanged() { root._queueTrackObservation() }
    function onTrackAlbumChanged() { root._queueTrackObservation() }
    function onPlaybackStateChanged() { root._queuePlaybackObservation() }
    function onShuffleChanged() { root._observeModes() }
    function onLoopStateChanged() { root._observeModes() }
    // The volume read is queued for the same reason the transport read is: a
    // mute is three signals on some clients (Volume, then the state, then the
    // state again), and an un-coalesced read would report a mute as a step to
    // zero and then a step back out of it.
    function onVolumeChanged() { root._queueVolumeObservation() }
    // Capability flags, all onto one observation. Twelve separate handlers
    // would be twelve chances to drift from the record `_caps` builds, and a
    // client that revises its whole flag set at once is exactly the case where
    // one line per signal is the wrong shape.
    function onCanControlChanged() { root._observeCaps() }
    function onCanPlayChanged() { root._observeCaps() }
    function onCanPauseChanged() { root._observeCaps() }
    function onCanTogglePlayingChanged() { root._observeCaps() }
    function onCanSeekChanged() { root._observeCaps() }
    function onCanGoNextChanged() { root._observeCaps() }
    function onCanGoPreviousChanged() { root._observeCaps() }
    function onVolumeSupportedChanged() { root._observeCaps() }
    function onPositionSupportedChanged() { root._observeCaps() }
    function onLengthSupportedChanged() { root._observeCaps() }
    function onShuffleSupportedChanged() { root._observeCaps() }
    function onLoopSupportedChanged() { root._observeCaps() }
  }

  function _queueVolumeObservation() {
    if (root._volumeQueued) return
    root._volumeQueued = true
    Qt.callLater(root._observeVolume)
  }

  // Position is a polled MPRIS property, so it only moves when something
  // asks the player to re-read it. The same tick records the sample the
  // next track change is judged against; with no player it does not run.
  Timer {
    interval: 1000
    repeat: true
    running: Core.MediaState.activePlayer !== null
    onTriggered: {
      const p = Core.MediaState.activePlayer
      if (!p) return
      p.positionChanged()
      const pos = NP.playerPosition(p)
      const len = NP.playerLength(p)
      NP.noteSample(root._samples, NP.playerKey(p), pos, len)
      root._watchPositionStall(p, pos)
    }
  }

  // Consecutive ticks on which a playing player's position did not move. -1
  // means "not stalled", which is the state almost every tick is in and the
  // reason a plain counter is the wrong shape: it would carry a number that is
  // nearly always zero.
  //
  // This is the fault a playing player whose position does not move, and it
  // is the real reason this tick exists: the progress strip freezes AND the
  // pop policy reads every change as a skip. Three consecutive dead ticks is
  // the threshold: one is a player rounding Position to whole seconds, and a
  // threshold of one marks a healthy player as broken.
  property int _stalledTicks: -1

  function _clearPositionStall() {
    root._stalledTicks = -1
  }

  function _watchPositionStall(p, pos) {
    // Not playing is not a stall: a paused player legitimately sits still and
    // a stopped one has no position at all. Leaving the counter primed here
    // would make the next real stall count one tick early.
    if (p.playbackState !== MprisPlaybackState.Playing) {
      root._clearPositionStall()
      return
    }

    // Compared against the previous sample rather than against a remembered
    // value, so a track change that restarts the position reads as movement
    // without needing its own reset. `lastSampleFor` skips samples belonging
    // to another player, which matters when two players are registered.
    const prev = NP.lastSampleFor(root._samples, NP.playerKey(p))
    if (prev === null) return
    if (Math.abs(Number(pos) - Number(prev.pos)) > 0.001) {
      root._clearPositionStall()
      return
    }

    root._stalledTicks = root._stalledTicks < 0 ? 1 : root._stalledTicks + 1
    // The counter is cleared at the threshold rather than left at 3, so a
    // player that stays stalled is one fault rather than a fault every three
    // seconds, and so the next fault counts from zero again.
    if (root._stalledTicks >= 3) root._clearPositionStall()
  }
}
