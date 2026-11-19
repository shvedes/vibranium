pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Glyph swap with a fade (optionally a slidefade): two Icons share one fixed
// slot and trade opacity when `name` flips - the same crossfade the network
// island's speed-test title uses for its caps/action titles, on the icon
// axis. `rise` adds vertical travel (incoming from below, outgoing above) and
// `slideX` adds horizontal travel (incoming from the right, outgoing left),
// both in step with the fade - the icon counterpart of SlideSwap's text
// travel. Opacity and transform never touch measure, so the slot holds its
// size throughout and surrounding rows never reflow mid-swap.
// Empty swaps snap: going to "" hides the slot at once (a vanishing glyph
// always coincides with its owner's own show/hide fade).
//
// A swap is staged on the hidden layer and the front is traded only once
// that layer can paint. Swapping first blanked the slot for as long as the
// new data URL took to decode: the incoming Icon had never loaded, so
// retainWhileLoading had no raster to keep, and the outgoing layer's
// opacity was already 0 (with motion off, in the same frame). With the
// gate, the outgoing glyph stays painted until the incoming one is ready,
// and MotionPolicy only gates the fade that follows - on a slow CPU that
// is a late fade instead of a frame of nothing.
Item {
  id: root

  // Icon name in the shipped set (shell/assets/icons).
  property string name: ""
  // Palette key the SVG is recolored with.
  property string colorKey: "foreground_0"
  // Optional second palette key for two-tone assets (class="indicator").
  property string accentKey: ""
  // Tiered glyphs (volume/wifi strength): how many leading wave/arc
  // groups stay in full body tone.
  property int dimTiers: 0
  // Animated indicator layer (connecting/searching ticks, mute marks).
  property bool indicatorActive: false
  property string indicatorAnim: ""
  // Layout size, Icon semantics: > 0 renders at exactly this logical
  // size, still DPR-corrected; 0 falls back to the bar slot/canvas
  // tokens (in which case the slot measures the layers' own slots).
  property real size: 0
  // Optional vertical slidefade travel. > 0 stages the incoming glyph `rise`
  // px below and sends the outgoing one `rise` px above as the trades; 0
  // (default) keeps the pure crossfade every existing consumer uses. Set it
  // once at construction - it is captured for the staged layer at swap time.
  property real rise: 0
  // Horizontal counterpart: > 0 stages the incoming glyph `slideX` px to the
  // right and sends the outgoing one `slideX` px left. Independent of `rise`;
  // 0 (default) keeps the pure crossfade.
  property real slideX: 0
  // Whether the fade and any travel run. Defaults to the shell's global
  // motion policy; a consumer whose swap must stay alive with animations off
  // (the launcher badge cycle) sets true explicitly.
  property bool animate: MotionPolicy.enabled

  // Double buffer. _aName starts tracking `name` so the first paint
  // lands without motion; onCompleted freezes it into a snapshot (the
  // assignment drops the binding with no value change, so no tween
  // fires) and every later flip stages on the hidden layer, then
  // trades front once that layer is ready. Same-name writes are no-ops
  // so re-asserting a binding never restarts the fade.
  property string _aName: name
  property string _bName: ""
  property bool _aFront: true
  // A new name is staged on the hidden layer but its raster has not
  // decoded yet; the front stays where it is while this is set.
  property bool _swapPending: false

  // Once a layer has decoded a raster it keeps that raster painted while a new
  // source loads (Icon.retainWhileLoading). A color-only change drops
  // swapReady for the decode even though there is no empty slot to hide, and
  // requiring it in `visible` blinked the glyph off on every frame of a color
  // tween. Latched per layer so a name that has never decoded still waits for
  // its first raster.
  property bool _aPainted: false
  property bool _bPainted: false
  // Travel offsets for the two layers: the hidden layer waits below/right of
  // the slot, the front sits at rest, and the outgoing layer leaves above/left
  // when the front trades.
  property real _aRise: 0
  property real _bRise: 0
  property real _aX: 0
  property real _bX: 0

  Component.onCompleted: {
    _aName = name
    _bRise = rise
    _bX = slideX
  }

  onNameChanged: {
    const showing = _aFront ? _aName : _bName
    if (name === showing) {
      // The requested glyph is already in front (a flip bounced back before
      // the staged layer decoded): the staged swap is moot.
      _swapPending = false
      return
    }
    if (name === "") {
      // Empty swaps snap: drop any staged swap and hide the slot at once.
      _swapPending = false
      if (_aFront) _bName = ""
      else _aName = ""
      return
    }
    if (_aFront) {
      _bName = name
      _bRise = root.rise
      _bX = root.slideX
    } else {
      _aName = name
      _aRise = root.rise
      _aX = root.slideX
    }
    _swapPending = true
    // The staged layer's own name -> source binding lands with this change
    // notification, so its status cannot be trusted from inside this
    // handler; check on a later turn and again when the layer reports back.
    Qt.callLater(root._tradeIfReady)
  }

  // Move the front only when the hidden layer has something to paint. The
  // other layer keeps its full opacity until then, which is the whole point:
  // a never-loaded Icon would otherwise paint an empty slot.
  function _tradeIfReady() {
    if (!root._swapPending) return
    const incoming = root._aFront ? iconB : iconA
    if (!incoming.swapReady) return
    root._swapPending = false
    if (root._aFront) {
      root._aRise = -root.rise
      root._bRise = 0
      root._aX = -root.slideX
      root._bX = 0
    } else {
      root._bRise = -root.rise
      root._aRise = 0
      root._bX = -root.slideX
      root._aX = 0
    }
    root._aFront = !root._aFront
  }

  implicitWidth: root.size > 0 ? root.size : Math.max(iconA.implicitWidth, iconB.implicitWidth)
  implicitHeight: root.size > 0 ? root.size : Math.max(iconA.implicitHeight, iconB.implicitHeight)
  // Empty hides at once (the owner's own fade goes with it). A non-empty name
  // shows the slot once the FRONT layer has something decoded, or has decoded
  // before and is still retaining that raster through a load: on an empty ->
  // non-empty swap the incoming name is staged on the hidden layer and has no
  // retained raster, so binding this to `name` alone painted an empty slot
  // until the trade. A color-only change, by contrast, must not blank a glyph
  // that is already painted.
  visible: root.name !== ""
    && (root._aFront
      ? root._aName !== "" && (iconA.swapReady || root._aPainted)
      : root._bName !== "" && (iconB.swapReady || root._bPainted))

  Icon {
    id: iconA
    anchors.centerIn: parent
    name: root._aName
    colorKey: root.colorKey
    accentKey: root.accentKey
    dimTiers: root.dimTiers
    indicatorActive: root.indicatorActive
    indicatorAnim: root.indicatorAnim
    size: root.size
    opacity: (root._aFront && root._aName !== "") ? 1 : 0
    transform: Translate {
      x: root._aX
      y: root._aRise
      Behavior on x {
        enabled: root.animate
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
      }
      Behavior on y {
        enabled: root.animate
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
      }
    }
    onSwapReadyChanged: root._tradeIfReady()
    onReadyChanged: if (ready) root._aPainted = true
    Behavior on opacity {
      enabled: root.animate
      NumberAnimation { duration: Ui.fastMs }
    }
  }

  Icon {
    id: iconB
    anchors.centerIn: parent
    name: root._bName
    colorKey: root.colorKey
    accentKey: root.accentKey
    dimTiers: root.dimTiers
    indicatorActive: root.indicatorActive
    indicatorAnim: root.indicatorAnim
    size: root.size
    opacity: (!root._aFront && root._bName !== "") ? 1 : 0
    transform: Translate {
      x: root._bX
      y: root._bRise
      Behavior on x {
        enabled: root.animate
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
      }
      Behavior on y {
        enabled: root.animate
        NumberAnimation { duration: Ui.fastMs; easing.type: Easing.OutCubic }
      }
    }
    onSwapReadyChanged: root._tradeIfReady()
    onReadyChanged: if (ready) root._bPainted = true
    Behavior on opacity {
      enabled: root.animate
      NumberAnimation { duration: Ui.fastMs }
    }
  }
}
