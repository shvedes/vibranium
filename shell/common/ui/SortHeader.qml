pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// One table column header: the column's label, whether it is the sorted one,
// and the click that cycles it.
//
// No arrow. A chevron in a 1930s-style table header is noise on every table
// that has one, and the active column already says which column it is - it
// reads brighter than its neighbours. Direction is the consumer's state; the
// only thing worth showing at a glance is WHICH column is in charge.
//
// Consumers own the sort state and the comparator - a format row sorts by
// pixels, a package by name - because only they know what their rows mean.
// `sortable: false` is for a column whose order says nothing useful (a version
// column in an update list): it renders as a plain label and ignores the
// pointer entirely.
Item {
  id: root

  property string text: ""
  // The key this column sorts by, and the consumer's current key.
  property string sortKey: ""
  property string activeKey: ""
  // Whether the column can be sorted at all. False = plain label.
  property bool sortable: true
  // Numeric columns put their label against the right edge, where their
  // values sit.
  property bool alignRight: false

  readonly property bool active: root.sortable && root.sortKey !== ""
    && root.sortKey === root.activeKey

  signal clicked()

  implicitWidth: label.implicitWidth
  implicitHeight: label.implicitHeight

  Title {
    id: label

    width: parent.width
    anchors.verticalCenter: parent.verticalCenter
    level: 5
    text: root.text
    elide: Text.ElideNone
    horizontalAlignment: root.alignRight ? Text.AlignRight : Text.AlignLeft
    // The active column is the whole of the indication, so it has to be a
    // real step: a muted label that is one shade brighter than its
    // neighbours is not something anyone finds.
    color: root.active ? Ui.solid("foreground_0")
      : root.sortable && area.containsMouse ? Ui.tint("foreground_1", 0.85)
      : Ui.tint("foreground_1", 0.6)
    font.pixelSize: Ui.fontXs
    font.bold: true

    Behavior on color {
      enabled: MotionPolicy.enabled
      ColorAnim {}
    }
  }

  MouseArea {
    id: area

    anchors.fill: parent
    // A plain label is not a target: no hover delivery, no hand cursor, no
    // click. `enabled` is what drops it out of hit testing entirely.
    enabled: root.sortable
    hoverEnabled: root.sortable
    cursorShape: root.sortable ? Qt.PointingHandCursor : Qt.ArrowCursor
    onClicked: root.clicked()
  }
}
