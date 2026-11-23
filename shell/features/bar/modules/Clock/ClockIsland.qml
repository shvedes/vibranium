pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../../../../common/text/Clock.js" as ClockFmt
import "../../../../common/ui/CalendarLib.js" as CalendarLib
import "../../../../common/ui/MoonPhaseLib.js" as MoonLib

// The clock's island content, split the way GNOME splits its calendar popup:
// a month grid on the left, a hairline divider, and the selected day's moon
// phase on the right. The right side shows that day plus the five after it,
// so clicking any date moves all six entries with the selection. Today stays
// honest across midnight through the module's SystemClock, which ticks
// forever in Clock.qml so every fresh calendar is born on the right date.
//
// Sizing: Calendar and the pane constants are fixed, so the card derives its
// geometry from those numbers without instantiating the layout. The same
// contract every island follows: content + 2 * outerPad of card chrome.
Item {
  id: root

  // The module's live date, handed down rather than read out of Clock.qml:
  // an island has no business resolving an id from its module's file scope.
  property date today: new Date()
  // The day whose moon the right pane describes. goToToday() emits
  // daySelected on open, so the selection and the pane agree from frame one.
  property date selectedDate: new Date()

  readonly property bool moonEnabled: Settings.value("shell.statusbar.clockMoonPhase") === true

  property int islandContentWidth: root.calendarW + (root.moonEnabled
    ? 2 * root.paneGap + root.separatorW + root.moonPaneW : 0) + 2 * Ui.outerPad
  property int islandContentHeight: root.calendarH + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null

  readonly property int calendarW: CalendarLib.gridW
  readonly property int calendarH: CalendarLib.contentHeight
  readonly property int paneGap: 10
  readonly property int separatorW: 1
  readonly property int moonPaneW: 196
  readonly property int heroDisc: 46
  readonly property int rowDisc: 24
  readonly property int rowGap: 8
  readonly property int titleH: CalendarLib.titleH
  readonly property int heroY: root.titleH + Ui.s
  readonly property int heroH: 60
  readonly property int nextY: root.heroY + root.heroH + Ui.s
  readonly property int rowY: root.nextY + 16 + 6
  readonly property int rowH: 28
  readonly property int rowTextX: root.rowDisc + root.rowGap

  readonly property var forecast: MoonLib.forecast(root.selectedDate, 6)
  readonly property var hero: root.forecast.length > 0 ? root.forecast[0] : null
  readonly property var nextEvent: MoonLib.nextPrincipal(root.selectedDate, 14)
  // The event instant is formatted through the shared clock label so the
  // 12/24-hour setting applies here exactly as it does to the bar and lock.
  readonly property string eventTime: root.nextEvent
    ? ClockFmt.clockLabel(root.nextEvent.at.getTime(), TimeFormat.use12h) : ""

  Row {
    anchors.fill: parent

    Calendar {
      id: calendar

      width: root.calendarW
      height: root.calendarH
      today: root.today
    }

    Item {
      width: root.moonEnabled ? root.paneGap : 0
      height: parent.height
    }

    Rectangle {
      width: root.moonEnabled ? root.separatorW : 0
      height: parent.height
      visible: root.moonEnabled
      color: Ui.tint("foreground_0", 0.12)
    }

    Item {
      width: root.moonEnabled ? root.paneGap : 0
      height: parent.height
    }

    Item {
      id: moonPane

      width: root.moonEnabled ? root.moonPaneW : 0
      height: parent.height
      visible: root.moonEnabled
      clip: true

      Title {
        level: 2
        anchors.left: parent.left
        anchors.top: parent.top
        text: "MOON PHASE"
      }

      MoonDisc {
        x: 0
        y: root.heroY
        width: root.heroDisc
        height: root.heroDisc
        phase: root.hero ? root.hero.fraction : 0
      }

      Column {
        x: root.heroDisc + root.rowGap
        y: root.heroY
        width: root.moonPaneW - root.heroDisc - root.rowGap
        spacing: 2

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.hero ? root.hero.name : ""
          color: Ui.solid("foreground_0")
          font.pixelSize: Ui.fontS
          font.family: Ui.fontFamily
          font.bold: true
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: (root.hero ? root.hero.percent : 0) + "% illuminated"
          color: Ui.tint("foreground_0", 0.6)
          font.pixelSize: Ui.fontXs
          font.family: Ui.fontFamily
        }

        Text {
          width: parent.width
          elide: Text.ElideRight
          text: root.nextEvent
            ? (root.nextEvent.days === 0
              ? root.nextEvent.name
              : root.nextEvent.name + " in " + root.nextEvent.days + " day"
                + (root.nextEvent.days === 1 ? "" : "s"))
              + (root.eventTime ? " ~" + root.eventTime : "")
            : ""
          color: Ui.solid("accent")
          font.pixelSize: Ui.fontXs
          font.family: Ui.fontFamily
        }
      }

      Title {
        level: 2
        anchors.left: parent.left
        y: root.nextY
        text: "NEXT 5 DAYS"
      }

      Repeater {
        model: root.forecast.slice(1)

        delegate: Item {
          required property int index
          required property var modelData

          x: 0
          y: root.rowY + index * root.rowH
          width: root.moonPaneW
          height: root.rowH

          MoonDisc {
            x: 0
            anchors.verticalCenter: parent.verticalCenter
            width: root.rowDisc
            height: root.rowDisc
            phase: parent.modelData.fraction
          }

          Text {
            x: root.rowTextX
            y: 1
            text: Qt.formatDate(parent.modelData.date, "ddd")
            color: Ui.solid("foreground_0")
            font.pixelSize: Ui.fontS
            font.family: Ui.fontFamily
            font.bold: true
          }

          Text {
            x: root.rowTextX
            y: 15
            text: parent.modelData.short + " \u00b7 " + parent.modelData.percent + "%"
            color: parent.modelData.principal
              ? Ui.solid("accent") : Ui.tint("foreground_0", 0.6)
            font.pixelSize: Ui.fontXs
            font.family: Ui.fontFamily
          }
        }
      }
    }
  }

  Connections {
    target: calendar

    function onDaySelected(date) {
      root.selectedDate = date
    }
  }

  // Keep the declarative today binding: assigning it here would drop the
  // binding and freeze the highlighted day at the open-time date. goToToday
  // reads the live value, so the open and every later tick agree.
  Component.onCompleted: Qt.callLater(() => {
    calendar.goToToday()
    calendar.forceActiveFocus()
  })
}
