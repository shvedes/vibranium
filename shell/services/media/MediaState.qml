pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import qs.common
import "../../common/NowPlaying.js" as NP

// MediaState - the normalized MPRIS state owner.
//
// One subscriber to Mpris.players for the shell's media path: it drops
// the nulls the backend set carries, filters browser identities out,
// orders playing clients first, and names the head of that order as the
// active player. That head is the active player, and its cover is the one
// url worth warming before anybody asks (MediaArt).
//
// Surfaces read here; nothing in this file decides what a surface shows.
Singleton {
  id: root

  readonly property string tag: "mediaState"

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
