pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import qs.features.bar

// Base for every bar module. Owns the pieces a module would otherwise hand-roll:
//
//  - the module contract: barScreen / barWindow (set by the slot wrapper
//    right after instantiation) and the implicit-size contract
//    (implicitHeight: Bar.height, width follows implicitWidth);
//  - the settings-command click: clickSetting()/clickCommand() resolve
//    shell.statusbar.<moduleId><action> and run the command through Exec;
//  - the hover surface: a built-in fill MouseArea (pointing-hand cursor,
//    hoverEnabled) that reports `hovered` and forwards clicks to the
//    module's `onClicked`. The fill sits raised above module content (z=1)
//    so the click surface covers the whole module. Sibling MouseAreas do not
//    share hover (the top one exits the one below), so content with its own
//    hover areas must OR them in itself - the tray does (fill gaps + item
//    hovers, row above the fill). Modules whose content owns the whole
//    surface with its own MouseAreas (Volume's per-icon areas) set
//    builtinFill to false and keep theirs.
//
//  - the island declaration: a module that can open an island assigns its
//    content Component to `islandComponent`, and that single assignment is
//    what `hasIsland` reports.
//    It is declared rather than derived from a click handler because a
//    handler can call islandHost.toggle from a path that is not "this module
//    opens an island" (Volume's mic pill does not).
//
// The module id is assigned by the slot wrapper (Zone.onLoaded / the
// group's member wiring), never derived from filenames.
Item {
  id: root

  // Module contract: set by the slot wrapper right after instantiation.
  // barWindow is what islands/tooltips anchor to; barScreen identifies the
  // monitor this module renders on.
  property ShellScreen barScreen: null
  property var barWindow: null

  // The module's layout slot id. The settings-key namespace for this
  // module's click commands: shell.statusbar.<moduleId><action>.
  property string moduleId: ""

  // The island content this module opens, or null. Declared here so one
  // line in a module says "left-click opens this"; `openIsland()` is then
  // the single call every such click handler makes, so a handler cannot
  // drift from the declaration.
  property Component islandComponent: null
  readonly property bool hasIsland: root.islandComponent !== null

  // Open this module's island through the shared host. The one place a
  // module opens its own island, so every click handler agrees about what
  // "open" means (toggle vs show, and which anchor item).
  function openIsland() {
    if (!root.hasIsland || !root.barWindow) return false
    root.barWindow.islandHost.toggle(root, root.islandComponent)
    return true
  }

  // The built-in fill surface. Modules whose content already covers the
  // whole module with its own MouseAreas set this to false and keep theirs.
  property bool builtinFill: true
  // Which buttons the fill surface accepts; modules narrow this to their
  // click contract (e.g. a right-click-only module).
  property int fillButtons: Qt.LeftButton | Qt.RightButton

  // Scaled bar metrics (F4): every module boxes into these instead of raw
  // Ui constants, so bar height + icon preset rescale everything.
  readonly property int iconSlot: Bar.iconSlot
  readonly property int iconCanvas: Bar.iconCanvas
  readonly property real textScale: Bar.textScale

  // Implicit-size contract: the bar row sizes modules by Bar.height and
  // their own implicitWidth.
  implicitHeight: Bar.height
  width: implicitWidth
  height: implicitHeight

  // The module's click surface, overridable per module.
  signal clicked(mouse: var)

  // True while the cursor sits on the fill itself. Sibling content with
  // its own MouseAreas above the fill exits this (see the hover-surface
  // note) - such modules OR this with their own hovers (the tray does).
  readonly property bool hovered: fillArea.containsMouse

  // Resolve one click-command setting (shell.statusbar.<moduleId><action>,
  // e.g. "rightClick") as a trimmed string; "" when unset.
  function clickSetting(action): string {
    const raw = Settings.value("shell.statusbar." + root.moduleId + action)
    return String(raw !== undefined ? raw : "").trim()
  }

  // Run a module click command: resolve the <action> setting and Exec.shell
  // it when non-empty, else run `fallback` (the module's default command).
  // Returns true when a command ran, false when neither path is available -
  // callers use the return to fall back to their own non-command behavior.
  function clickCommand(action, fallback): bool {
    const cmd = root.clickSetting(action)
    if (cmd !== "") {
      Exec.shell(cmd)
      return true
    }
    if (fallback !== undefined && fallback !== null && String(fallback).trim() !== "") {
      Exec.shell(fallback)
      return true
    }
    return false
  }

  MouseArea {
    id: fillArea

    visible: root.builtinFill
    anchors.fill: parent
    // Raised above default module content (which never raises above z 1),
    // so the click surface covers the whole module. Hover does not follow:
    // a sibling MouseArea above this exits it - content with its own hover
    // must sit above (the tray row is z=2) and OR its hover in.
    z: 1
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: root.fillButtons
    onClicked: mouse => root.clicked(mouse)
  }

}
