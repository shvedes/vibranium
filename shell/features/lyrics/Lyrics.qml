pragma Singleton

import QtQml
import QtQuick
import Quickshell
import qs.common

// Owner of the Utilities `lyrics` target and the fullscreen player surface.
// It is resident: the menu row must work with no bar mounted. The overlay
// itself is demand-loaded by URL, so neither entry path imports Now Playing's
// bar module to obtain it.
Singleton {
  id: root

  readonly property string tag: "lyrics"

  property var overlay: null
  property int generation: 0
  property var _playerResolver: null
  property var _pendingPlayer: null
  property int _pendingGeneration: 0
  readonly property bool open: root.overlay !== null && root.overlay.opened === true

  // A superseding request invalidates the outstanding load. A late completion
  // from an older generation never attaches or opens a stale overlay.
  function _invalidate() {
    root.generation++
    root._pendingPlayer = null
    root._pendingGeneration = 0
  }

  // Resolving the active player is the menu path's concern. It is compiled on
  // first use rather than on the boot path: importing qs.services here would
  // pull the service singletons onto every shell start.
  function _activePlayer() {
    if (root._playerResolver) return root._playerResolver.player
    root._playerResolver = Qt.createQmlObject(
      'import QtQml; import qs.services; QtObject { readonly property var player: MediaState.activePlayer }',
      root, "lyrics-player-resolver")
    return root._playerResolver ? root._playerResolver.player : null
  }

  function showLyrics(player, screen) {
    const p = player !== null && player !== undefined ? player : root._activePlayer()
    const s = screen !== null && screen !== undefined ? screen : Ui.primaryScreen
    if (root.overlay !== null) {
      root.overlay.targetScreen = s
      root.overlay.open(p)
      return true
    }
    root._invalidate()
    const gen = root.generation
    root._pendingPlayer = p
    root._pendingGeneration = gen
    overlayLoader.active = true
    overlayLoader.setSource(
      Qt.resolvedUrl("../bar/modules/NowPlaying/LyricsFullscreenOverlay.qml"),
      { targetScreen: s })
    return true
  }

  function _openSurface(surface, player) {
    if (!surface || typeof surface.open !== "function") return false
    surface.open(player)
    return true
  }

  function close() {
    root._invalidate()
    const surface = root.overlay
    root.overlay = null
    overlayLoader.active = false
    overlayLoader.source = ""
    if (surface && typeof surface.close === "function") surface.close()
    return true
  }

  Loader {
    id: overlayLoader
    active: false
    asynchronous: true
    onLoaded: {
      if (item === null || root._pendingGeneration !== root.generation) {
        if (item) item.destroy()
        return
      }
      const p = root._pendingPlayer
      root._pendingPlayer = null
      root._pendingGeneration = 0
      root.overlay = item
      root._openSurface(item, p)
    }
    onStatusChanged: {
      if (status !== Loader.Error) return
      Log.warn("lyrics: overlay failed to load")
      root._invalidate()
    }
  }

}
