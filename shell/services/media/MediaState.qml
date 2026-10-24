pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.common
import "../../common/NowPlaying.js" as NP

// MediaState - the normalized MPRIS state owner, and the media event
// contract between the media service and every surface that shows media.
//
// One subscriber to Mpris.players for the shell's media path: it drops
// the nulls the backend set carries, filters browser identities out,
// orders playing clients first, and names the head of that order as the
// active player. That head is who a media event is about, and its cover
// is the one url worth warming before anybody asks (MediaArt).
//
// MediaEvents observes the backend and publishes here; surfaces read
// here. Nothing in this file decides whether an event is shown, where, or
// for how long - that is the OSD's (see OSD.qml). What this file owes a
// subscriber is a normalized, frozen description of what the backend did,
// so a surface never re-reads the player object it was handed.
//
//   Core.MediaState.publish(kind, player, previous)   // MediaEvents
//   Connections {                                    // any surface
//     target: Core.MediaState
//     function onEventChanged() { ...Core.MediaState.event... }
//   }
Singleton {
  id: root

  readonly property string tag: "mediaState"

  // Bus mirror of the last event, so a reader that must not import the
  // media service can still see the normalized description. The typed
  // property above stays the contract; this is the same payload for
  // anything that reads topics instead of singletons.
  readonly property string eventTopic: "media.state.event"

  readonly property int revDep: Settings.rev
  // A browser tab playing audio is not a media client: those identities
  // are excluded from the media set entirely. The key keeps its
  // shell.osd.* name, so an existing configuration keeps meaning what it
  // meant before this state moved here.
  readonly property bool blockBrowsers: {
    root.revDep
    return Settings.value("shell.osd.blockBrowsers") !== false
  }
  readonly property var players: NP.sortPlayers(
    root.blockBrowsers
      ? NP.filterBrowsers(Mpris.players ? Mpris.players.values ?? [] : [])
      : (Mpris.players ? Mpris.players.values ?? [] : []),
    p => p.playbackState === MprisPlaybackState.Playing)
  readonly property var activePlayer: root.players.length > 0 ? root.players[0] ?? null : null
  // The cover the warmer holds for a player nobody is displaying yet: the
  // head of the media set is the player every now-playing surface shows.
  readonly property string activeArtUrl: root.activePlayer !== null
    ? String(root.activePlayer.trackArtUrl ?? "")
    : ""

  // --- event contract -----------------------------------------------------
  //
  // `kind` is one of:
  //   "player"     the active player changed. `player` is the new one and
  //                null when none is left; `previous` is the one it
  //                replaced, null when there was none to replace.
  //   "track"      a new track identity was observed on the active player.
  //   "transport"  the active player started or paused.
  //   "stopped"    the active player stopped.
  // Written only by publish(); a frozen object per event, so one event
  // reads as exactly one change and a subscriber cannot edit history.
  readonly property var kinds: ({ player: 1, track: 1, transport: 1, stopped: 1 })
  property var event: null
  property int _seq: 0

  // MPRIS Identity is the spec's human-readable name for a client, with the
  // bus name as the fallback for a client that declares none.
  function publish(kind, player, previous) {
    const name = String(kind || "")
    if (root.kinds[name] !== 1) {
      // A closed map against one writer, so a refusal here cannot be a runtime
      // condition - it is a caller passing a kind the contract does not have,
      // and the event is dropped rather than published as something a surface
      // would render.
      return false
    }
    const p = player ?? null
    const title = p ? String(p.trackTitle ?? "") : ""
    const artist = p ? String(p.trackArtist ?? "") : ""
    const raw = p ? NP.playerPosition(p) : 0
    root._seq += 1
    root.event = Object.freeze({
      kind: name,
      seq: root._seq,
      player: p,
      previous: previous ?? null,
      key: p ? NP.playerKey(p) : "",
      title: title,
      artist: artist,
      album: p ? String(p.trackAlbum ?? "") : "",
      artUrl: p ? String(p.trackArtUrl ?? "") : "",
      // A player reports Position after Metadata, so an immediate read
      // on a new track still carries the old position: a track event
      // snaps to the settle budget, a transport event reports the
      // player's own number.
      position: name === "track" ? NP.freshSkipPosition(raw) : raw,
      length: p ? NP.playerLength(p) : 0,
      paused: p ? p.playbackState !== MprisPlaybackState.Playing : true,
      // The icon names the event, not the surface: a track change shows
      // the album glyph, a transport change the direction it moved.
      icon: name === "track"
        ? "music-album"
        : (p && p.playbackState !== MprisPlaybackState.Playing ? "pause" : "play"),
    })
    Bus.publish(root.eventTopic, root.event)
    return true
  }

  // --- external volume control -------------------------------------------
  //
  // Whether a player takes a volume write is the player's own declaration:
  // canControl + volumeSupported (NP.canSetPlayerVolume), cached per
  // dbusName for the shell's life. The flags are the verdict, and no user
  // action anywhere steps a player's level to ask the question. A player
  // that declares Volume and ignores the write keeps a live slider - the
  // island's fill follows the shell's optimistic copy.
  //
  // Deaf-player verdicts per dbusName, reserved for writers that prove
  // deafness out of band. No such writer exists, so the map stays empty
  // and the flags below are the whole answer. Replaced wholesale rather
  // than mutated, because the notify is what re-evaluates a surface's
  // binding.
  property var _volumeCaps: Object.create(null)

  // True when the player declares a settable Volume (canControl +
  // volumeSupported) and no verdict has said otherwise. A pure read, so a
  // surface binds it: a player with no answer reads as capable, and a
  // player whose recorded answer is "does not take the write" reads as
  // not. Keyed per dbusName, so a client that leaves takes its answer
  // with it.
  function volumeCapable(player) {
    if (!NP.canSetPlayerVolume(player)) return false
    return root._volumeCaps[NP.playerVolumeKey(player)] !== false
  }
}
