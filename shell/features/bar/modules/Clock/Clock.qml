pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import qs.features.bar
import "../../../../common/text/Clock.js" as ClockFmt

// Clock module. Minute precision: the label only re-renders when the
// minute ticks. Clicking it opens the calendar island anchored to this
// module (clicking again, or outside, closes it). The label always shows
// the time - the open calendar carries the date itself.
BarModule {
  id: root

  // "Show seconds" + "Time format" settings (shell.statusbar.*): live,
  // like every other managed option. Toggling re-renders onDateChanged.
  readonly property bool showSeconds: Settings.value("shell.statusbar.clockSeconds") === true
  readonly property bool showSecondsInTooltip: Settings.value("shell.statusbar.clockSecondsTooltip") === true
  readonly property bool use12h: TimeFormat.use12h
  readonly property bool fullDate: Settings.value("shell.statusbar.clockFullDate") === true
  // The global motion switch, and the only one: a bar-local settings key
  // cannot gate this, because SettingsLib drops every key the schema does not
  // name, so an undeclared key resolves to undefined and `!== false` is a term
  // that is never false - a gate that is always open. Workspaces.qml records
  // the same reasoning for the same key.
  readonly property bool animOn: MotionPolicy.enabled

  // Computed at call time, not readonly bindings: a readonly text that
  // read these sibling readonly flags would cache stale/sticky values when
  // the format toggles. Functions always reflect the current flags.
  function dayPart() {
    if (root.fullDate) return Qt.formatDateTime(clock.date, "ddd, MMM d ")
    return ""
  }
  function timePart(withSeconds) {
    // Qt's "hh" only reads as 12-hour when "AP" rides along in the same
    // format string - and the suffix lives in its own segment here - so
    // 12h is folded into the date itself through the shared
    // common/text/Clock.js fold both clocks use: hour 0 becomes 12, 13
    // becomes 1.
    const d = new Date(clock.date)
    if (root.use12h) d.setHours(ClockFmt.foldHour12(d.getHours()))
    return Qt.formatDateTime(d, "hh:mm" + (withSeconds ? ":ss" : ""))
  }
  function suffixPart() {
    // The marker stays inside Qt's format parser: "AP" renders as
    // AM/PM, a literal suffix would print "AP".
    return root.use12h ? Qt.formatDateTime(clock.date, " AP") : ""
  }
  readonly property real restingY: (root.height - segments.height) / 2

  // Bar.slotInset on both sides: the zone row has zero gap and an icon-only
  // slot keeps (slot - canvas) / 2 of air at each edge, so the text module
  // boxes itself with the same inset instead of riding flush against the
  // next module.
  implicitWidth: segments.implicitWidth + Bar.slotInset * 2

  // Clips the segments to the module slot while its width tracks them.
  clip: true

  property string tipText: ""

  // Refresh the time.
  function refreshLabel() {
    dayText.text = root.dayPart()
    timeText.text = root.timePart(root.showSeconds && !root.showSecondsInTooltip)
    suffixText.text = root.suffixPart()
    tipText = root.showSeconds && root.showSecondsInTooltip
      ? root.dayPart() + root.timePart(root.showSecondsInTooltip) + root.suffixPart()
      : ""
  }

  SystemClock {
    id: clock

    precision: root.showSeconds && (!root.showSecondsInTooltip || root.hovered)
      ? SystemClock.Seconds : SystemClock.Minutes
    onDateChanged: root.refreshLabel()
  }

  // The clock's own date, handed to the island as a property. An island must
  // not reach back into this file's scope for it: the reference would compile
  // only because the Component block below parents the island's context onto
  // this one, which is invisible at the island's call site and disappears the
  // moment the island is built any other way.
  property date today: clock.date

  // Toggling the time format / seconds should reflect immediately, not
  // on the next minute tick (the clock otherwise only re-renders on time
  // changes).
  onShowSecondsChanged: refreshLabel()
  onShowSecondsInTooltipChanged: refreshLabel()
  onUse12hChanged: refreshLabel()
  onFullDateChanged: refreshLabel()
  onHoveredChanged: if (root.showSeconds && root.showSecondsInTooltip) refreshLabel()

  // First paint: refreshLabel() reads clock.date + renders the time.
  Component.onCompleted: refreshLabel()

  // The label as segments: day/date, time, am/pm suffix. Toggling a
  // segment's setting grows or retracts its holder (width Glide) while
  // the text slide-fades in, the same entrance language as NowPlaying.
  // Every Title is level 1 at Bar.textScale and opts out of the level's bold,
  // which the bar's other text modules do as well.
  Row {
    id: segments

    anchors.horizontalCenter: parent.horizontalCenter
    y: root.restingY
    spacing: 0

    Item {
      id: daySeg

      property bool shown: root.fullDate
      clip: true
      implicitWidth: width
      width: shown ? dayText.implicitWidth : 0
      height: dayText.height
      Behavior on width { enabled: root.animOn; Glide { duration: Ui.fastMs } }
      onShownChanged: if (shown && root.animOn) {
        daySlide.restart()
        dayFade.restart()
      }

      Title {
        id: dayText
        level: 1
        font.pixelSize: Math.round(Ui.fontM * root.textScale)
        font.bold: false
        text: ""
      }

      NumberAnimation {
        id: daySlide
        target: dayText
        property: "x"
        from: 24
        to: 0
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: dayFade
        target: dayText
        property: "opacity"
        from: 0
        to: 1
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }

    Item {
      id: timeSeg

      clip: true
      implicitWidth: width
      width: timeText.implicitWidth
      height: timeText.height
      Behavior on width { enabled: root.animOn; Glide { duration: Ui.fastMs } }

      Title {
        id: timeText
        level: 1
        font.pixelSize: Math.round(Ui.fontM * root.textScale)
        font.bold: false
        text: ""
      }
    }

    Item {
      id: suffixSeg

      property bool shown: root.use12h
      clip: true
      implicitWidth: width
      width: shown ? suffixText.implicitWidth : 0
      height: suffixText.height
      Behavior on width { enabled: root.animOn; Glide { duration: Ui.fastMs } }
      onShownChanged: if (shown && root.animOn) {
        suffixSlide.restart()
        suffixFade.restart()
      }

      Title {
        id: suffixText
        level: 1
        font.pixelSize: Math.round(Ui.fontM * root.textScale)
        font.bold: false
        text: ""
      }

      NumberAnimation {
        id: suffixSlide
        target: suffixText
        property: "x"
        from: 24
        to: 0
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }

      NumberAnimation {
        id: suffixFade
        target: suffixText
        property: "opacity"
        from: 0
        to: 1
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }
  }

  fillButtons: Qt.LeftButton | Qt.RightButton
  onClicked: mouse => {
    if (mouse.button === Qt.RightButton) {
      root.clickCommand("rightClick")
      return
    }
    root.openIsland()
  }

  ToolTipBind {
    active: root.hovered && root.showSeconds && root.showSecondsInTooltip
      && !root.barWindow.islandHost.isOpenFor(root)
    text: root.tipText
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    ClockIsland {
      today: root.today
    }
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp
}
