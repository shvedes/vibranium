pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Glyph swap with a fade: two Icons share one fixed slot and trade
// opacity when `name` flips - the same crossfade the network island's
// speed-test title uses for its caps/action titles, on the icon axis.
// Opacity never touches measure, so the slot holds its size throughout
// and surrounding rows never reflow mid-fade. Empty swaps snap: going
// to "" hides the slot at once (a vanishing glyph always coincides
// with its owner's own show/hide fade). MotionPolicy gates both
// tweens, so with animations off the swap is a single-frame switch.
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
  // trades front. Same-name writes are no-ops so re-asserting a
  // binding never restarts the fade.
  property string _aName: name
  property string _bName: ""
  property bool _aFront: true

  Component.onCompleted: {
    _aName = name
  }

  onNameChanged: {
    const showing = _aFront ? _aName : _bName
    if (name === showing) return
    if (_aFront) {
      _bName = name
      _aFront = false
    } else {
      _aName = name
      _aFront = true
    }
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
    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs }
    }
  }
}
