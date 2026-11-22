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

  // Player-owned intents (mute resume, saved volume, optimistic like) live in
  // the shared JS library. Retire them when the media set changes so a recycled
  // bus name cannot pick up a slot the departed player left behind. The set is
  // the live source, so no second subscription or copied list is needed.
  onPlayersChanged: NP.dropPlayerIntents(root.players)

  // The cover the warmer holds for a player nobody is displaying yet: the
  // head of the media set is the player every now-playing surface shows.
  readonly property string activeArtUrl: root.activePlayer !== null
    ? String(root.activePlayer.trackArtUrl ?? "")
    : ""

  // A client that has stopped is still in the MPRIS set, but it has no track
  // for a lyrics view to open. Playing and paused are the two states that
  // carry one; the head of the sorted set is the client surfaces should use.
  readonly property bool hasActivePlayer: {
    const p = root.activePlayer
    return p !== null && p !== undefined && p.playbackState !== MprisPlaybackState.Stopped
  }

  // Menu provider for the Utilities "Show Lyrics" row. The row stays listed
  // and mutes while there is no usable client, the same shape every other
  // state-gated row uses: reading hasActivePlayer inside the hook makes the
  // delegate's availability binding follow MPRIS without a shell guard.
  function _registerMenuProvider() {
    ProviderHost.claimProvider("show.lyrics", {
      visible: () => root.hasActivePlayer
    }, root)
  }

  Component.onCompleted: root._registerMenuProvider()
  Component.onDestruction: ProviderHost.unregisterProvider("show.lyrics", root)

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
  // volumeSupported), reports a real level, and no verdict has said otherwise.
  // A pure read, so a surface binds it: a player with no answer reads as
  // capable, and a player whose recorded answer is "does not take the write"
  // reads as not. Keyed per dbusName, so a client that leaves takes its answer
  // with it.
  //
  // MPRIS reserves a NEGATIVE Volume for "this client does not know its
  // volume", and NP.normalizeVolume collapses that to 0 - the right number to
  // paint a bar with, the wrong one to hand back as the player's own level.
  // NP.volumeKnown is the gate that refuses it (Q6): every writer asks
  // volumeCapable first, so a wheel step or a slider fill taken off an unknown
  // read cannot write 0 back and mute a client nobody asked to touch. Zero
  // passes, because a muted player reporting 0 is reporting a real level.
  function volumeCapable(player) {
    if (!NP.canSetPlayerVolume(player)) return false
    if (!NP.volumeKnown(player.volume)) return false
    return root._volumeCaps[NP.playerVolumeKey(player)] !== false
  }

  // The single writer of a player's Volume property. The bar wheel and the
  // island's slider, wheel and mute pad all land here, so normalization, the
  // mute-resume token and the transport resume are one implementation rather
  // than a gesture path plus a second, policy-free writer (XPLAT-1). The
  // player is explicit because the island can hold a client other than
  // activePlayer. The gate above refuses a client reporting an unknown level.
  function setPlayerVolume(player, ratio) {
    if (!root.volumeCapable(player)) return false
    if (!isFinite(Number(ratio))) return false
    const current = NP.normalizeVolume(player.volume)
    const next = NP.normalizeVolume(ratio)
    const unmuted = NP.volumeUnmuted(current, next)
    if (!unmuted && current > 0 && next === 0) NP.setMuteResumePending(player, false)
    player.volume = next
    // The mute-restore path is the one place transport starts as a side effect
    // of a volume write: a client the user stopped stays stopped, and a paused
    // one resumes - which is exactly the state the mute paused it from.
    if (unmuted && NP.consumeMuteResume(player)
      && player.playbackState !== MprisPlaybackState.Stopped
      && player.canPlay === true) {
      player.play()
    }
    return true
  }
}
