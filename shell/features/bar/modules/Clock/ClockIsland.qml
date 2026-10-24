pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../../../../common/ui/CalendarLib.js" as CalendarLib

// The clock's island content: a calendar popup lent to the shared host.
// Every open shows the current month with today selected; clicking a day
// moves the selection and the year progress bar. Today stays honest
// across midnight via the module's SystemClock, which ticks forever in
// Clock.qml so every fresh calendar is born on the right date.
//
// Sizing: Calendar exposes its exact geometry in CalendarLib (the same
// library that paints it), so the content computes its size from the
// lib constants - no instantiated calendar is needed for sizing.
Item {
  id: root

  // The module's live date, handed down rather than read out of Clock.qml:
  // an island has no business resolving an id from its module's file scope.
  property date today: new Date()

  property int islandContentWidth: root.calendarW + 2 * Ui.outerPad
  property int islandContentHeight: root.calendarH + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null

  readonly property int calendarW: CalendarLib.gridW
  readonly property int calendarH: CalendarLib.contentHeight

  // The lib constants are the calendar's painted size; the card adds its
  // own chrome (2 * outerPad), so the island sizes from the sum - the
  // same contract every island's `content + 2 * outerPad` follows.
  Calendar {
    id: calendar

    anchors.fill: parent
    today: root.today
  }

  Component.onCompleted: Qt.callLater(() => {
    calendar.today = root.today
    calendar.goToToday()
    calendar.forceActiveFocus()
  })
}
