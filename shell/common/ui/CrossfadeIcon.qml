pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Glyph swap with a fade: two Icons share one fixed slot and trade
// opacity when `name` flips - the same crossfade the network island's
// speed-test title uses for its caps/action titles, on the icon axis.
// Opacity never touches measure, so the slot holds its size throughout
// and surrounding rows never reflow mid-fade. Empty swaps snap: going
// to "" hides the slot at once (a vanishing glyph always coincides
// with its owner's own show/hide fade).
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

  Component.onCompleted: {
    _aName = name
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
    if (_aFront) _bName = name
    else _aName = name
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
    root._aFront = !root._aFront
  }

  implicitWidth: root.size > 0 ? root.size : Math.max(iconA.implicitWidth, iconB.implicitWidth)
  implicitHeight: root.size > 0 ? root.size : Math.max(iconA.implicitHeight, iconB.implicitHeight)
  visible: root.name !== ""

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
    onSwapReadyChanged: root._tradeIfReady()
    Behavior on opacity {
      enabled: MotionPolicy.enabled
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
    onSwapReadyChanged: root._tradeIfReady()
    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs }
    }
  }
}
