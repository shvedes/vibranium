pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import "../../../../common/text/Clock.js" as ClockFmt
import "../../../../common/ui/CalendarLib.js" as CalendarLib
import "../../../../common/ui/MoonPhaseLib.js" as MoonLib
import "../../../../common/ui/SunLib.js" as SunLib

// The clock's island content, laid out as Month | Sun | Moon: a month grid
// on the left, a hairline divider, then the selected day's sun and moon on
// the right. Clicking a date moves both right-hand sections with it. Today
// stays honest across midnight through the module's SystemClock, which ticks
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
  // The day whose sun and moon the right pane describes. goToToday() emits
  // daySelected on open, so both sections agree with the grid from frame one.
  property date selectedDate: new Date()

  readonly property bool moonEnabled: Settings.value("shell.statusbar.clockMoonPhase") === true
  readonly property bool animOn: MotionPolicy.enabled

  // One scalar owns the crossfade. Both views read it, so neither can
  // finish early or late; easing lives at this one source.
  property real viewSwap: 0
  readonly property bool viewAnimating: viewAnim.running
  readonly property bool yearView: root.viewSwap >= 1
  property int yearViewYear: selectedDate.getFullYear()
  // One scalar for year navigation: the new months enter from the side the
  // chevron pointed toward and fade up while sliding to rest.
  property real yearSlide: 0
  readonly property real yearSlideOpacity: Math.max(0,
    1 - Math.abs(root.yearSlide) / 24)

  function changeYear(delta) {
    if (!isFinite(delta) || delta === 0) return
    root.yearSlide = delta * 24
    root.yearViewYear += delta
    if (root.animOn) yearSlideAnim.restart()
    else root.yearSlide = 0
  }

  NumberAnimation {
    id: yearSlideAnim
    target: root
    property: "yearSlide"
    to: 0
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
  }

  readonly property int yearCols: 3
  readonly property int yearRows: 4
  readonly property real miniW: (root.calendarW + 2 * root.leftPad) / root.yearCols
  readonly property real miniH: (root.calendarH + 2 * root.leftPad - root.titleH)
    / root.yearRows

  function toggleView() {
    if (root.viewAnimating) return
    const to = root.yearView ? 0 : 1
    if (!root.animOn) {
      root.viewSwap = to
      return
    }
    viewAnim.to = to
    viewAnim.restart()
  }

  NumberAnimation {
    id: viewAnim
    target: root
    property: "viewSwap"
    duration: Ui.slowMs
    easing.type: Easing.OutQuart
    to: 1
  }

  property int islandContentWidth: (root.calendarW + 2 * root.leftPad) + (root.moonEnabled
    ? 2 * root.paneGap + root.separatorW + root.moonPaneW : 0) + 2 * Ui.outerPad
  property int islandContentHeight: root.calendarH + 2 * root.leftPad + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null

  readonly property int calendarW: CalendarLib.gridW
  readonly property int calendarH: CalendarLib.contentHeight
  readonly property int leftPad: 6
  readonly property int miniPad: 8
  readonly property int paneGap: 10
  readonly property int separatorW: 1
  readonly property int moonPaneW: 210
  readonly property int titleH: CalendarLib.titleH
  readonly property int heroDisc: 44
  readonly property int rowDisc: 22
  readonly property int rowGap: 8
  readonly property int heroY: 108
  readonly property int rowsY: 160
  readonly property int rowH: 24
  readonly property int rowTextX: root.rowDisc + root.rowGap
  readonly property int rowPhaseX: root.rowTextX + 32

  readonly property var forecast: MoonLib.forecast(root.selectedDate, 6)
  readonly property var hero: root.forecast.length > 0 ? root.forecast[0] : null
  readonly property var nextEvent: MoonLib.nextPrincipal(root.selectedDate, 14)
  // The event instant uses the shared clock label so the 12/24-hour setting
  // applies here exactly as it does to the bar and lock.
  readonly property string eventTime: root.nextEvent
    ? ClockFmt.clockLabel(root.nextEvent.at.getTime(), TimeFormat.use12h) : ""

  function clock(at) {
    return at ? ClockFmt.clockLabel(at.getTime(), TimeFormat.use12h) : ""
  }

  // A miniature month has no room for a hover card, so hovering lifts the
  // day's own color instead. Selected and today stay accent so the current
  // day never disappears into a dark background fill.
  function miniDayColor(cell, hovered) {
    if (cell.key === CalendarLib.keyForDate(root.selectedDate) || cell.today)
      return hovered ? Ui.mix("accent", "foreground_0", 0.35) : Ui.solid("accent")
    if (cell.weekend)
      return Ui.tint("red", hovered ? (cell.inMonth ? 1 : 0.65)
        : (cell.inMonth ? 0.85 : 0.4))
    if (cell.inMonth)
      return hovered ? Ui.mix("foreground_0", "accent", 0.25)
        : Ui.solid("foreground_0")
    return Ui.tint("foreground_0", hovered ? 0.62 : 0.3)
  }

  // The weather service persists its configured location into shell state;
  // reading that section here avoids importing the whole services module
  // (whose singletons need a window backend) into an island. No coordinates
  // means no made-up times: the pane says so instead.
  readonly property var weatherSection: ShellState.section("weather") || ({})
  readonly property var sunLocation: SunLib.validPair(
    weatherSection.latitude, weatherSection.longitude)
  readonly property var sun: root.sunLocation
    ? SunLib.forDate(root.selectedDate, root.sunLocation.latitude,
      root.sunLocation.longitude) : null
  readonly property string riseText: root.sun && root.sun.sunrise
    ? root.clock(root.sun.sunrise) : "\u2014"
  readonly property string setText: root.sun && root.sun.sunset
    ? root.clock(root.sun.sunset) : "\u2014"
  readonly property string sunLength: !root.sun ? "Set a location in Weather"
    : root.sun.polar === "day" ? "24h of daylight"
    : root.sun.polar === "night" ? "No daylight"
    : SunLib.span(root.sun.dayLengthMinutes) + " of daylight"

  Row {
    anchors.fill: parent

    Item {
      width: root.calendarW + 2 * root.leftPad
      height: root.calendarH + 2 * root.leftPad

      Calendar {
        id: calendar

        x: root.leftPad
        y: root.leftPad
        width: root.calendarW
        height: root.calendarH
        today: root.today
        opacity: 1 - root.viewSwap
        enabled: !root.yearView
      }

      Item {
        id: yearGrid

        x: 0
        y: root.titleH
        width: parent.width
        height: parent.height - root.titleH
        opacity: root.viewSwap
        visible: opacity > 0.01
        enabled: root.yearView

        MouseArea {
          anchors.fill: parent
          onWheel: wheel => root.changeYear(wheel.angleDelta.y > 0 ? 1 : -1)
        }

        Repeater {
          model: 12

          delegate: Item {
            required property int index

            readonly property var days: CalendarLib.monthGrid(
              root.yearViewYear, index, 1, CalendarLib.keyForDate(root.today))
            readonly property int col: index % root.yearCols
            readonly property int row: Math.floor(index / root.yearCols)

            x: col * root.miniW + root.yearSlide
            y: row * root.miniH
            width: root.miniW
            height: root.miniH
            opacity: root.yearSlideOpacity

            Text {
              x: root.miniPad
              y: 1
              text: Qt.locale().monthName(parent.index, Locale.ShortFormat)
              color: monthHover.containsMouse
                ? Ui.solid("accent") : Ui.tint("accent", 0.6)
              font.pixelSize: Ui.fontXs
              font.bold: true

              Behavior on color {
                enabled: root.animOn
                ColorAnim {}
              }
            }

            Repeater {
              model: parent.days

              delegate: Text {
                required property int index
                required property var modelData

                x: root.miniPad + (index % 7) * 14
                y: root.miniPad + 9 + Math.floor(index / 7) * 8
                width: 13
                height: 8
                horizontalAlignment: Text.AlignHCenter
                text: modelData.day
                color: root.miniDayColor(modelData, monthHover.containsMouse)
                font.pixelSize: 8
                font.bold: modelData.key === CalendarLib.keyForDate(root.selectedDate)
                  || modelData.today
                font.underline: modelData.today
                  && modelData.key !== CalendarLib.keyForDate(root.selectedDate)

                Behavior on color {
                  enabled: root.animOn
                  ColorAnim {}
                }
              }
            }

            MouseArea {
              id: monthHover

              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                calendar.selectDay(root.yearViewYear, parent.index, 1)
                root.toggleView()
              }
            }
          }
        }
      }

      Item {
        y: 0
        width: parent.width
        height: root.titleH
        opacity: root.viewSwap
        visible: opacity > 0.01
        enabled: root.yearView

        Text {
          width: 24
          height: parent.height
          anchors.left: parent.left
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "\u2039"
          color: yearPrevHover.containsMouse
            ? Ui.solid("accent") : Ui.solid("foreground_0")
          font.pixelSize: Ui.fontL
          font.family: Ui.fontFamily

          MouseArea {
            id: yearPrevHover

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.changeYear(-1)
          }
        }

        Text {
          anchors.centerIn: parent
          text: String(root.yearViewYear)
          color: yearLabelHover.containsMouse
            ? Ui.solid("accent") : Ui.solid("foreground_0")
          font.pixelSize: Ui.fontM
          font.family: Ui.fontFamily
          font.bold: true

          MouseArea {
            id: yearLabelHover

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleView()
          }
        }

        Text {
          width: 24
          height: parent.height
          anchors.right: parent.right
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          text: "\u203A"
          color: yearNextHover.containsMouse
            ? Ui.solid("accent") : Ui.solid("foreground_0")
          font.pixelSize: Ui.fontL
          font.family: Ui.fontFamily

          MouseArea {
            id: yearNextHover

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.changeYear(1)
          }
        }
      }
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

      // ---- Sun: the selected day's light ---------------------------------

      Title {
        level: 2
        y: 0
        text: "DAYLIGHT"
      }

      Icon {
        x: 0
        y: 24
        width: 16
        height: 16
        name: "sunrise"
        colorKey: "foreground_0"
        accentKey: "#ffb454"
      }

      Text {
        x: 22
        y: 24
        text: root.riseText
        color: Ui.solid("foreground_0")
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
        font.bold: true
      }

      Icon {
        x: 98
        y: 24
        width: 16
        height: 16
        name: "sunset"
        colorKey: "foreground_0"
        accentKey: "#ff6b5a"
      }

      Text {
        x: 120
        y: 24
        text: root.setText
        color: Ui.solid("foreground_0")
        font.pixelSize: Ui.fontS
        font.family: Ui.fontFamily
        font.bold: true
      }

      Icon {
        x: 0
        y: 44
        width: 14
        height: 14
        name: "weather-clear-day"
        colorKey: "#ffd34d"
      }

      Text {
        x: 20
        y: 44
        width: root.moonPaneW - 20
        elide: Text.ElideRight
        text: root.sunLength
        color: Ui.solid("foreground_0")
        font.pixelSize: Ui.fontXs
        font.family: Ui.fontFamily
      }

      // ---- Moon: the selected day and the five after it ------------------

      Title {
        level: 2
        y: 76
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
        spacing: 1

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

      Repeater {
        model: root.forecast.slice(1)

        delegate: Item {
          required property int index
          required property var modelData

          x: 0
          y: root.rowsY + index * root.rowH
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
            anchors.verticalCenter: parent.verticalCenter
            text: Qt.formatDate(parent.modelData.date, "ddd")
            color: Ui.solid("foreground_0")
            font.pixelSize: Ui.fontXs
            font.family: Ui.fontFamily
            font.bold: true
          }

          Text {
            x: root.rowPhaseX
            anchors.verticalCenter: parent.verticalCenter
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

    function onViewToggleRequested() {
      root.toggleView()
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
