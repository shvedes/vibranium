pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.features.bar

// Reading mode indicator. Hyprland shader state is decided by the presence
// of $XDG_CONFIG_HOME/hypr/hyprland.conf.d/reading-mode.lua: the CLI toggle
// writes/removes that include and reloads Hyprland, so the file is the
// single source of truth - never the live shader report (stale across
// reloads). The module watches the file and shows an icon
// only while it exists; left click toggles through the same backend, and
// middle/right clicks pass through untouched.
CollapsibleSlot {
  id: root

  // The include file vb-toggle-reading-mode creates and removes.
  readonly property string _configPath: Paths.configHome + "/hypr/hyprland.conf.d/reading-mode.lua"

  // Appears only while reading mode is active; takes no space otherwise.
  readonly property bool active: root._presence !== null && root._presence.present
  // --- state (file presence) ---

  // The policy stays here: this include's presence IS reading mode,
  // because the CLI toggle is what writes and removes it. The tracker
  // only answers "does this path hold content".
  //
  // Assigned in onCompleted rather than through a binding, because a
  // binding on _configPath would track a second time if that path ever
  // changed and leave the first observation holding a watcher forever.
  // The owner string names this consumer; the handle the tracker mints is
  // the identity its reference count is keyed on, so every output
  // observes the same path through one shared watcher instead of N.
  property var _presence: null

  Component.onCompleted: {
    root._presence = FilePresence.track("bar/readingMode/" + String(root), root._configPath)
  }
  // Released with the module, so a bar closed on the last output drops
  // the watcher and the prober rather than leaving the path watched.
  Component.onDestruction: {
    if (root._presence !== null) FilePresence.release(root._presence)
  }

  // --- indicator ---

  // Collapsible slot (see CollapsibleSlot.qml): zero width while idle
  // so it leaves no gap.
  collapseShown: root.active

  Icon {
    // Pinned to the trailing edge the box grows from (right-anchored zone):
    // the Icon item is slot-sized and paints its glyph centered inside, so
    // a flush-right anchor centers the glyph at rest and holds it
    // screen-fixed while the slot grows (left overflow is clipped).
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    name: "reading-mode"
    colorKey: "foreground_0"
    opacity: root.fade
    visible: opacity > 0
  }

  // Left click toggles reading mode, through
  // shell.statusbar.readingModeLeftClick when that is set and through the
  // same backend otherwise. Middle and right clicks are rejected at the
  // surface level (fillButtons), so they pass through and do nothing.
  fillButtons: Qt.LeftButton
  onClicked: mouse => {
    root.clickCommand("leftClick", "vb-toggle-reading-mode")
    // The toggle command is fire-and-forget, so re-read through the shared
    // entry straight away: that is the fast path, and the watcher's own
    // later event is the confirmation. The verdict itself is the tracker's
    // (blocking read on the parked prober, absence read from empty text, a
    // failed read inactive) - this module only decides that presence of
    // this include means reading mode.
    if (root._presence !== null) FilePresence.refresh(root._presence)
  }

  ToolTipBind {
    active: root.active && root.hovered
    // First line states the mode; the note carries the warning that
    // grayscale shows up in screenshots and screen recordings. The label
    // wraps on its own.
    text: "Reading mode is active\n\n"
      + "Note that grayscale effect will be visible on screenshots and screen records"
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }
}
