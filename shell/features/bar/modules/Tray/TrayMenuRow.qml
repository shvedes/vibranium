pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Widgets
import qs.common

// One DBusMenu entry row: optional check/radio indicator, icon, label
// and submenu chevron. Mouse-driven (a tray menu is operated by a
// pointer, not the keyboard), so rows paint a hover fill and fire on
// click. Separators collapse to a thin divider.
// Keep-bespoke: pointer-only row by design, not a Button/Toggle adoption.
Item {
  id: row

  required property var entry
  property int rowHeight: Ui.trayRowH
  property int rowWidth: 200

  signal activated(var entry)
  signal submenuRequested(var entry)

  readonly property bool isSep: row.entry.isSeparator === true
  readonly property bool isEnabled: row.entry.enabled !== false
  readonly property bool hasChildren: row.entry.hasChildren === true
  readonly property bool hasIcon: String(row.entry.icon ?? "").length > 0
  readonly property int buttonType: row.entry.buttonType === undefined ? QsMenuButtonType.None : row.entry.buttonType
  readonly property int checkState: row.entry.checkState === undefined ? Qt.Unchecked : row.entry.checkState

  // Column widths: indicator, icon and chevron are fixed; the label gets
  // the rest, with the 8px row spacing only between visible columns.
  readonly property real indicatorW: row.buttonType === QsMenuButtonType.None ? 0 : 16
  readonly property real iconW: row.hasIcon ? 16 : 0
  readonly property real chevronW: row.hasChildren ? 12 : 0
  readonly property real textW: Math.max(0, row.rowWidth - 2 * Ui.m
    - row.indicatorW - row.iconW - row.chevronW - 8
    * ((row.indicatorW > 0 ? 1 : 0) + (row.iconW > 0 ? 1 : 0) + (row.chevronW > 0 ? 1 : 0)))

  width: row.rowWidth
  height: row.isSep ? 1 : row.rowHeight
  implicitWidth: width
  implicitHeight: height
  opacity: row.isSep || row.isEnabled ? 1 : Ui.disabledOpacity

  // Hover fill - instant, no lingering tint (pointer-driven menu).
  Rectangle {
    anchors.fill: parent
    visible: !row.isSep
    color: Ui.tint("foreground_0", 0.07)
    opacity: hoverArea.containsMouse ? 1 : 0

    Behavior on opacity {
      enabled: MotionPolicy.enabled
      NumberAnimation { duration: Ui.fastMs }
    }
  }

  MouseArea {
    id: hoverArea

    anchors.fill: parent
    enabled: !row.isSep && row.isEnabled
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: {
      if (row.hasChildren) row.submenuRequested(row.entry)
      else row.activated(row.entry)
    }
  }

  // Separator divider.
  Rectangle {
    anchors.fill: parent
    visible: row.isSep
    color: Ui.solid("background_3")
    opacity: 0.7
  }

  Row {
    visible: !row.isSep
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Ui.m
    anchors.rightMargin: Ui.m
    spacing: 8

    // Check / radio indicator column.
    Item {
      width: row.indicatorW
      height: 16
      clip: true

      Rectangle {
        anchors.centerIn: parent
        width: 12
        height: 12
        radius: RoundingPolicy.radius
        color: "transparent"
        border.width: 1
        border.color: Ui.solid("foreground_0")
        opacity: 0.7
      }

      // Radio: a filled dot when checked.
      Rectangle {
        anchors.centerIn: parent
        visible: row.buttonType === QsMenuButtonType.RadioButton && row.checkState === Qt.Checked
        width: 6
        height: 6
        radius: RoundingPolicy.radius
        color: Ui.solid("foreground_0")
      }

      // Checkbox: a glyph when checked (indeterminate gets a dash).
      Title {
        level: 5
        anchors.centerIn: parent
        visible: row.buttonType === QsMenuButtonType.CheckBox && row.checkState !== Qt.Unchecked
        text: row.checkState === Qt.PartiallyChecked ? "–" : "✓"
        color: Ui.solid("foreground_0")
      }
    }

    // Icon column.
    Item {
      width: row.iconW
      height: 16
      clip: true

      IconImage {
        anchors.centerIn: parent
        width: 16
        height: 16
        asynchronous: true
        // DBusMenu icons are Image.source-ready URLs (theme-resolved or
        // embedded png data).
        source: row.entry.icon ?? ""
      }
    }

    // Label -> shared Title level 3 (row primary).
    Title {
      level: 3
      width: row.textW
      text: row.entry.text ?? ""
      color: Ui.solid("foreground_0")
      verticalAlignment: Text.AlignVCenter
    }

    // Submenu chevron.
    Title {
      level: 3
      width: row.chevronW
      visible: row.hasChildren
      text: "›"
      color: Ui.solid("foreground_0")
      opacity: 0.6
      verticalAlignment: Text.AlignVCenter
    }
  }
}
