pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.services as Core
import qs.features.bar

// Bar face of the privacy service (qs.services.privacy): a static right-zone
// launcher for the privacy island. On a mic or camera start its glyph
// slide-fades from the default incognito to the action in its own color,
// holds 2s, then slide-fades back. The flash remembers which source armed
// it, so that source stopping early returns the glyph at once instead of
// leaving the action icon up until the dwell runs out. A screenshare holds
// its glyph until the share stops. The capture dots themselves are NOT drawn
// here - they live on the bar's own privacy overlay (PrivacyOverlay.qml), an
// Overlay-layer surface per screen, so they survive a fullscreen covering the bar.
// All state, the per-app ledger, the tooltip/island models and the link-cut
// toggles live in the service, so the overlay's dots and the lockscreen dots
// mirror the same state without duplicating any PipeWire code.
BarModule {
  id: root

  // Left click opens the info island; the fill still reports `hovered`
  // for the tooltip.
  fillButtons: Qt.LeftButton
  onClicked: mouse => root.openIsland()

  // Regular static module: one icon slot, no slide and no collapse, so the
  // slot holds its width whether or not a capture is running.
  readonly property real slotWidth: root.iconSlot
  implicitWidth: root.slotWidth

  // Capture flash: on a mic/camera start the glyph slide-fades from the
  // default incognito to the action, holds 2s, then fades back. The hold is
  // a dwell, not motion, so it is not motion-gated. A screenshare is not a
  // flash: it owns the glyph until the share ends.
  //
  // `flashSource` is the source that armed the glyph now shown ("mic" or
  // "cam"). Keeping it - rather than just the glyph - is what lets a source
  // that stops early end the dwell at once. It is also the guard against a
  // stale end: a second source that takes over the glyph becomes the new
  // owner, so the first source going quiet cannot cut that flash short.
  property string flashSource: ""
  readonly property string actionIcon: root.flashSource === "mic" ? "mic-on"
    : root.flashSource === "cam" ? "camera" : ""
  property bool _captureSeeded: false
  readonly property string captureGlyph: Core.Privacy.shareOn
    ? "screen-capture" : root.actionIcon
  readonly property string currentGlyph: root.captureGlyph !== ""
    ? root.captureGlyph : "incognito"
  Timer {
    id: actionTimer

    interval: 2000
    repeat: false
    onTriggered: root._endFlash()
  }
  function _flashAction(source) {
    // A pending flash would surface again when the share ends.
    if (Core.Privacy.shareOn) return
    root.flashSource = source
    actionTimer.restart()
  }
  // The one clear path: stop the dwell and release the glyph. Used by the
  // timer, by the owning source's off-edge, and by a share taking over.
  function _endFlash() {
    actionTimer.stop()
    root.flashSource = ""
  }
  // An off-edge ends the dwell only when that source still owns the glyph.
  // A source that never armed it (or was superseded) must not cut a flash
  // belonging to another source short.
  function _endFlashFor(source) {
    if (root.flashSource === source) root._endFlash()
  }

  // Action glyphs keep their dot colors; the idle glyph keeps the bar
  // foreground. CrossfadeIcon resolves the color per layer, so the outgoing
  // glyph does not repaint when the incoming one arrives.
  function toneFor(glyph) {
    if (glyph === "mic-on") return "green"
    if (glyph === "camera") return "purple"
    if (glyph === "screen-capture") return "orange"
    return "foreground_0"
  }

  CrossfadeIcon {
    anchors.centerIn: parent
    name: root.currentGlyph
    colorFor: glyph => root.toneFor(glyph)
    slideX: Ui.s
  }

  // Tooltip asks on every hover, not only while a capture runs: the
  // service projects the per-app table from the live ledger and returns
  // no rows with no client, so the idle half is a literal here.
  // A quiet privacy slot stays self-explaining instead of silent - the
  // literal reads as a plain sentence (the island already shows the same
  // words, with no prefix). Active rows render through the host's shared
  // lines path like every compact tooltip, so the bubble insets match.
  barTipActive: root.hovered && !root.islandOpen
  barTipText: Core.Privacy.active ? "" : "No apps using your devices"
  barTipLines: Core.Privacy.active ? Core.Privacy.tooltipRows : []

  Component {
    id: islandComp

    PrivacyIsland {
      rows: Core.Privacy.islandRows
      onInvokeRequested: (app, key) => {
        // DEBUG, and deliberately not INFO: the row's button asks the
        // privacy service to cut a link or put one back, and the service's
        // pipeline decides which and whether it landed - a cut can be
        // refused outright (nothing_to_restore), which the row shows and
        // nothing else records. So this is the request, who was asked and
        // for what, and the outcome line belongs to services/privacy where
        // the cut is actually run.
        return Core.Privacy._toggleTarget(app, key)
      }
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp

  // The service owns the capture booleans and `active`; mic/camera starts arm
  // the flash, their ends release it early when that source still owns the
  // glyph, a share owns the glyph while it lasts, and the idle edge closes a
  // stale island. A source whose flash was superseded or dropped by a share
  // leaves the current glyph alone.
  Connections {
    target: Core.Privacy

    function onMicOnChanged() {
      if (!root._captureSeeded) return
      if (Core.Privacy.micOn) root._flashAction("mic")
      else root._endFlashFor("mic")
    }
    function onCamOnChanged() {
      if (!root._captureSeeded) return
      if (Core.Privacy.camOn) root._flashAction("cam")
      else root._endFlashFor("cam")
    }
    function onShareOnChanged() {
      if (!root._captureSeeded || !Core.Privacy.shareOn) return
      // The share holds the glyph through `captureGlyph`; drop any pending
      // flash so it cannot pop back once the share ends.
      root._endFlash()
    }
    function onActiveChanged() {
      if (!Core.Privacy.active && root.islandOpen)
        root.barWindow.islandHost.close()
    }
  }

  Component.onCompleted: root._captureSeeded = true
}
