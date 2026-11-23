pragma ComponentBehavior: Bound

import QtQml
import QtQuick
import qs.common
import "CalendarLib.js" as CalendarLib

// Calendar widget (qs.common). A fixed six-by-seven month grid with a year
// progress bar, all geometry explicit so it never depends on implicit-size
// propagation.
//
// - Clicking a day selects it: the year progress bar (share of the year
//   behind that day) updates live. Right-clicking slides back to today.
// - The month is scrollable: the mouse wheel, the header chevrons, and the
//   arrow keys (when focused) step it. Month changes are immediate: the
//   grid swaps in place with no slide or fade.
// - Today is marked with an accent underline (accent fill when selected).
Item {
  id: root

  // Selected day, driving the year progress bar. Defaults to today.
  property date selectedDate: new Date()
  // Today reference; the host keeps it honest across midnight (SystemClock).
  property date today: new Date()
  // First day of the week: 0 = Sunday ... 6 = Saturday, default Monday.
  property int weekStart: 1

  // Month currently on screen. Bindings seed them from selectedDate; any
  // step/select below assigns explicitly, which takes over from the
  // binding, so browsing never fights the selection.
  property int viewYear: selectedDate.getFullYear()
  property int viewMonth: selectedDate.getMonth()

  // The view as the grid and the title consume it: the declared ints above are
  // the input, and an out-of-range write is rolled into the month it names
  // rather than compared raw. `new Date(2024, 12, 1)` has always meant January
  // 2025, but the grid compares each cell against the month it is handed, so a
  // raw 12 matched no cell at all and painted the whole grid as neighbouring
  // days. Deriving the pair keeps every write usable without making the
  // properties read-only or fighting the host with a write-back handler.
  readonly property int viewMonthIndex: ((root.viewMonth % 12) + 12) % 12
  readonly property int viewYearRolled: root.viewYear + Math.floor(root.viewMonth / 12)

  signal daySelected(date date)
  // The month title is the view switch: hosts wire this to their month/year
  // transition, so the title stays the single affordance for changing scale.
  signal viewToggleRequested()

  // ---- geometry -----------------------------------------------------------
  // Painted from the CalendarLib layout constants - the single source of
  // truth, shared with hosts (ClockIsland) that size their card from the
  // lib values without an instantiated calendar, so the two never drift.

  readonly property int cellW: CalendarLib.cellW
  readonly property int cellH: CalendarLib.cellH
  readonly property int cellGap: CalendarLib.cellGap
  readonly property int gridW: CalendarLib.gridW
  readonly property int gridH: CalendarLib.gridH
  readonly property int titleH: CalendarLib.titleH
  readonly property int yearBlockH: CalendarLib.yearBlockH
  readonly property int weekdayRowH: CalendarLib.weekdayRowH

  // Deterministic outer size, independent of this item's own (lazily
  // evaluated) width/height - hosts size their surfaces from these so the
  // card is never derived from a not-yet-evaluated binding.
  readonly property int desiredWidth: gridW
  readonly property int desiredHeight: CalendarLib.contentHeight
  readonly property int yearBlockY: CalendarLib.yearBlockY
  readonly property int weekdayRowY: CalendarLib.weekdayRowY
  readonly property int gridY: CalendarLib.gridY

  width: root.desiredWidth
  implicitWidth: root.desiredWidth
  height: root.desiredHeight
  implicitHeight: root.desiredHeight

  // ---- derived state ------------------------------------------------------

  // Memoized month grid: monthGrid builds 42 cells, and a naive binding
  // rebuilds them on every `today` object reassignment even when the
  // viewed month and the day key are unchanged. The cache keys on
  // (viewYear, viewMonth, weekStart, todayKey) and rebuilds only when
  // one moves.
  //
  // `cells` is a plain property refreshed imperatively, never a binding:
  // the old binding read `root._gridCache.key` and wrote
  // `root._gridCache` in the same evaluation, which is a write-during-eval
  // binding loop (it only settled by accident on the second pass).
  // _refreshCells runs on the key change and once at completion, and the
  // cache check inside keeps the same-key -> no rebuild memoization.
  property var _gridCache: ({ key: "", cells: [] })
  readonly property string _gridKey: root.viewYearRolled + "-" + root.viewMonthIndex + "-"
    + root.weekStart + "-" + CalendarLib.keyForDate(root.today)
  property var cells: []

  function _refreshCells() {
    const k = root._gridKey
    if (root._gridCache.key !== k) {
      root._gridCache = {
        key: k,
        cells: CalendarLib.monthGrid(root.viewYearRolled, root.viewMonthIndex,
          root.weekStart, CalendarLib.keyForDate(root.today))
      }
    }
    if (root.cells !== root._gridCache.cells) root.cells = root._gridCache.cells
  }

  on_GridKeyChanged: root._refreshCells()
  Component.onCompleted: root._refreshCells()
  readonly property string selectedKey: CalendarLib.keyForDate(root.selectedDate)

  readonly property int dayOfYear: CalendarLib.dayOfYear(root.selectedDate.getFullYear(),
    root.selectedDate.getMonth(), root.selectedDate.getDate())
  readonly property int daysInYear: CalendarLib.daysInYear(root.selectedDate.getFullYear())
  readonly property int yearProgress: CalendarLib.yearProgressPercent(root.selectedDate.getFullYear(),
    root.selectedDate.getMonth(), root.selectedDate.getDate())

  // ---- behavior -----------------------------------------------------------

  // The animated flag is for explicit chevron navigation: the grid slides
  // in from the travel side while fading up. Wheel and keys stay instant.
  property real monthShiftY: 0

  function stepMonth(delta, animated) {
    if (!isFinite(delta) || delta === 0) return
    const next = CalendarLib.stepMonth(root.viewYearRolled, root.viewMonthIndex, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
    if (animated === true) {
      monthShiftY = delta > 0 ? 36 : -36
      gridHost.opacity = 0
      monthSlide.restart()
    }
  }

  function selectDay(year, month, day) {
    root.selectedDate = new Date(year, month, day)
    root.viewYear = year
    root.viewMonth = month
    root.daySelected(root.selectedDate)
  }

  function goToToday() {
    root.selectedDate = root.today
    root.viewYear = root.today.getFullYear()
    root.viewMonth = root.today.getMonth()
    root.daySelected(root.selectedDate)
  }

  // Arrows walk the selection by day and by week. selectDay keeps the view
  // on the new date, so crossing a month boundary navigates as expected.
  function stepDay(delta) {
    if (!isFinite(delta) || delta === 0) return
    const d = root.selectedDate
    const next = new Date(d.getFullYear(), d.getMonth(), d.getDate() + delta)
    root.selectDay(next.getFullYear(), next.getMonth(), next.getDate())
  }

  // First render must match selectedDate even if a host assigned it after
  // construction; the binding already covers that, this keeps both paths.
  focus: true
  Keys.onLeftPressed: (event) => {
    if (event.modifiers & Qt.ControlModifier) root.stepMonth(-1)
    else root.stepDay(-1)
  }
  Keys.onRightPressed: (event) => {
    if (event.modifiers & Qt.ControlModifier) root.stepMonth(1)
    else root.stepDay(1)
  }
  Keys.onUpPressed: (event) => {
    if (event.modifiers & Qt.ControlModifier) root.stepMonth(-12)
    else root.stepDay(-7)
  }
  Keys.onDownPressed: (event) => {
    if (event.modifiers & Qt.ControlModifier) root.stepMonth(12)
    else root.stepDay(7)
  }

  // ---- month title (with prev/next chevrons) ------------------------------

  Item {

    y: 0
    width: root.gridW
    height: root.titleH

    Text {

      anchors.centerIn: parent
      text: Qt.formatDate(new Date(root.viewYearRolled, root.viewMonthIndex, 1), "MMMM yyyy")
      color: monthTitleHover.containsMouse
        ? Ui.solid("accent") : Ui.solid("foreground_0")
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      font.bold: true

      MouseArea {
        id: monthTitleHover

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.viewToggleRequested()
      }
    }

    Text {

      width: 24
      height: root.titleH
      anchors.left: parent.left
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: "\u2039"
      color: prevMouse.containsMouse ? Ui.solid("accent") : Ui.solid("foreground_0")
      font.pixelSize: Ui.fontL
      font.family: Ui.fontFamily

      MouseArea {
        id: prevMouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.stepMonth(-1, true)
      }
    }

    Text {

      width: 24
      height: root.titleH
      anchors.right: parent.right
      horizontalAlignment: Text.AlignHCenter
      verticalAlignment: Text.AlignVCenter
      text: "\u203A"
      color: nextMouse.containsMouse ? Ui.solid("accent") : Ui.solid("foreground_0")
      font.pixelSize: Ui.fontL
      font.family: Ui.fontFamily

      MouseArea {
        id: nextMouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.stepMonth(1, true)
      }
    }
  }

  // ---- year progress, under the title -------------------------------------

  Item {

    y: root.yearBlockY
    width: root.gridW
    height: root.yearBlockH

    Title {
      level: 2
      anchors.left: parent.left
      anchors.top: parent.top
      text: "YEAR PROGRESS"
    }

    ProgressBar {

      width: root.gridW - 44
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.topMargin: 16
      dimWhenEmpty: false
      value: root.yearProgress
    }

    Text {

      width: 36
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: 16
      horizontalAlignment: Text.AlignRight
      text: root.yearProgress + "%"
      color: Ui.solid("accent")
      font.pixelSize: Ui.fontS
      font.family: Ui.fontFamily
      font.bold: true
    }
  }

  // ---- weekday labels -----------------------------------------------------

  Item {
    y: root.weekdayRowY
    width: root.gridW
    height: root.weekdayRowH

    Repeater {
      model: 7

      delegate: Text {
        required property int index

        readonly property int weekday: CalendarLib.weekdayOrder(root.weekStart)[index]

        x: index * (root.cellW + root.cellGap)
        width: root.cellW
        height: root.weekdayRowH
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: Qt.locale().dayName(weekday, Locale.ShortFormat).toUpperCase()
        color: weekday === 0 || weekday === 6
          ? Ui.tint("red", 0.7) : Ui.tint("foreground_0", 0.5)
        font.pixelSize: Ui.fontXs
      font.family: Ui.fontFamily
        font.letterSpacing: 0.5
      }
    }
  }

  // ---- day grid -----------------------------------------------------------

  Item {
    id: gridHost

    y: root.gridY + root.monthShiftY
    width: root.gridW
    height: root.gridH

    // Right-click on the grid background (between cells) returns to today;
    // it sits below the cells so it never steals their wheel or clicks.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.RightButton
      onClicked: root.goToToday()
    }

    Repeater {
      model: 42

      delegate: Item {
        required property int index

        readonly property var cell: root.cells[index]
        readonly property bool selected: cell.key === root.selectedKey

        x: (index % 7) * (root.cellW + root.cellGap)
        y: Math.floor(index / 7) * (root.cellH + root.cellGap)
        width: root.cellW
        height: root.cellH

        Rectangle {
          anchors.fill: parent
          visible: parent.selected
          color: parent.cell.inMonth ? Ui.solid("accent") : Ui.tint("accent", 0.5)
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 2
          visible: parent.cell.today && !parent.selected
          color: parent.cell.inMonth ? Ui.solid("accent") : Ui.tint("accent", 0.5)
        }

        Text {
          anchors.centerIn: parent
          text: parent.cell.day
          color: parent.selected ? Ui.solid("background_0")
            : parent.cell.today ? (parent.cell.inMonth ? Ui.solid("accent") : Ui.tint("accent", 0.5))
            : parent.cell.inMonth
              ? (parent.cell.weekend ? Ui.tint("red", 0.85) : Ui.solid("foreground_0"))
              : (parent.cell.weekend ? Ui.tint("red", 0.4) : Ui.tint("foreground_0", 0.3))
          font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
          font.bold: parent.selected || parent.cell.today
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          // Explicit function params: signal-parameter injection is
          // deprecated in Qt 6.
          onClicked: (mouse) => mouse.button === Qt.RightButton
            ? root.goToToday()
            : root.selectDay(parent.cell.year, parent.cell.month, parent.cell.day)
          onWheel: (wheel) => root.stepMonth(wheel.angleDelta.y > 0 ? -1 : 1)
        }
      }
    }
  }

  ParallelAnimation {
    id: monthSlide

    NumberAnimation {
      target: root
      property: "monthShiftY"
      to: 0
      duration: Ui.fastMs
      easing.type: Easing.OutCubic
    }
    NumberAnimation {
      target: gridHost
      property: "opacity"
      to: 1
      duration: Ui.fastMs
    }
  }
}
