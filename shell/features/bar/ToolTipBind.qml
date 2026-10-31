import QtQuick
import qs.common

// ToolTipBind: per-module tooltip request without a window. Holds
// the bindings a per-module ToolTip window would hold and
// pushes a snapshot to the shared host on every relevant change,
// so dependency tracking stays in bindings (no missed updates) and
// the host only arbitrates. Retires itself on destruction so a
// dying module never leaves a stale bubble behind.
//
// `lines` is the icon-led row list the host renders instead of the plain
// label: one { icon, text } object per row, with three optional fields -
// `colorKey` (a palette key for that row's label), `dimTiers` (tier
// count for a tiered glyph) and `accentKey` (a palette key for that row's
// indicator elements, class="indicator" - the muted marks). The host owns
// the row geometry and paints every glyph in the foreground tone.
QtObject {
  id: root

  property var host: null
  property Item anchor: null
  property var barWindow: null
  property bool active: false
  property string text: ""
  property var lines: []
  property bool markup: false
  property int maxWidth: 260

  function _push() {
    // Asked for a bubble with nowhere to send it: the module is wired, the
    // host is missing or is not a host at all.
    if (!root.host || typeof root.host._serve !== "function") return
    root.host._serve(root, {
      anchor: root.anchor,
      barWindow: root.barWindow,
      text: root.text,
      lines: root.lines,
      markup: root.markup,
      maxWidth: root.maxWidth
    })
  }
  function _drop() {
    if (!root.host || typeof root.host._retire !== "function") return
    root.host._retire(root)
  }

  onActiveChanged: root.active ? root._push() : root._drop()
  onTextChanged: if (root.active) root._push()
  onLinesChanged: if (root.active) root._push()
  onMarkupChanged: if (root.active) root._push()
  onMaxWidthChanged: if (root.active) root._push()
  onAnchorChanged: if (root.active) root._push()
  onBarWindowChanged: if (root.active) root._push()
  onHostChanged: if (root.active) root._push()
  Component.onDestruction: root._drop()
}
