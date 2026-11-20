pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import qs.features.bar
import "../../../../common/text/Clock.js" as ClockFmt
import "../../../../common/ui/CalendarLib.js" as CalendarLib

// Clock module. Minute precision: the label only re-renders when the
// minute ticks. Clicking it opens the calendar island anchored to this
// module (clicking again, or outside, closes it).
//
// With "Show full date" off the label carries the time, hovering reports
// the detailed date in a bubble, and the wheel cycles time, short date and
// year progress. With it on the date is already in the clock face, so the
// cycle drops that stop and runs clock <-> year progress only. Up walks
// forward, down walks back; no setting is written and the face index is the
// record of where the cycle stopped.
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
  // The short date is the bar's own date face: the full-date segment and
  // the scroll preview share it.
  function dateLabel() {
    return Qt.formatDateTime(clock.date, "ddd, MMM d")
  }
  // The bubble carries what the label cannot fit: full weekday and month
  // names plus the year, rather than the short form shown in the bar.
  function detailedDate() {
    return Qt.formatDateTime(clock.date, "dddd, MMMM d, yyyy")
  }
  // The year face already prints the share, so the bubble skips that and
  // adds only what the label cannot fit: the day's ordinal and days left.
  function yearTipText() {
    const d = clock.date
    const year = d.getFullYear()
    const month = d.getMonth()
    const day = CalendarLib.dayOfYear(year, month, d.getDate())
    const total = CalendarLib.daysInYear(year)
    return "Day " + day + " of " + total
      + " \u00b7 " + (total - day) + " days left"
  }
  function dayPart() {
    if (root.fullDate) return root.dateLabel()
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
  // Same optical correction as Title's verticalCenterOffset (see
  // common/ui/Title.qml): the segments Row is placed by y, not by a
  // vertical-center anchor, so the Title offset never applies to it and
  // the correction rides here instead.
  readonly property real restingY: (root.height - segments.height) / 2 + Math.round(Ui.fontM * root.textScale * 0.08)

  // Bar.slotInset on both sides: the zone row has zero gap and an icon-only
  // slot keeps (slot - canvas) / 2 of air at each edge, so the text module
  // boxes itself with the same inset instead of riding flush against the
  // next module.
  implicitWidth: segments.implicitWidth + Bar.slotInset * 2

  // Clips the segments to the module slot while its width tracks them.
  clip: true

  property string tipText: ""

  // Scroll cycle: 0 = time, 1 = short date, 2 = year progress. The index is
  // the record of the stopped position and never writes clockFullDate.
  property int previewIndex: 0
  // The face the last swap brought forward, so the next one knows what to
  // slide out even when a swap was interrupted mid-flight.
  property int lastFaceIndex: 0
  // True when the incoming face enters from above (the wheel rolled down).
  property bool previewFromTop: false
  // A trackpad gesture arrives as many small wheel events; bank them so one
  // gesture advances the cycle once instead of stepping on every event.
  property int wheelBank: 0
  readonly property int wheelNotch: 120
  // Number of stacked face layers, not the cycle length: the mode decides
  // which of them the wheel actually visits.
  readonly property int faceCount: 3
  // With the full date in the label the date face would be a duplicate, so
  // that mode cycles clock and year progress only.
  readonly property var faceCycle: root.fullDate ? [0, 2] : [0, 1, 2]
  // The indexed face drives the label in every mode. The full-date setting
  // only adds the date segment and rule while the cycle sits on the clock.
  readonly property int faceIndex: root.previewIndex
  // The full-date label says everything itself; only a cycle face that
  // hides it still has something to report in a bubble.
  readonly property bool tipWanted: root.faceIndex === 2
    || (root.faceIndex === 0 && !root.fullDate)

  function faceAt(i) { return i === 0 ? timeText : i === 1 ? previewText : yearText }
  function slideFor(i) { return i === 0 ? slide0 : i === 1 ? slide1 : slide2 }
  function fadeFor(i) { return i === 0 ? fade0 : i === 1 ? fade1 : fade2 }

  // step is +1 on scroll up, -1 on scroll down: the direction walks the
  // mode's cycle instead of always advancing, and the sign steers the
  // entrance. The step index is kept separately from the face index so a
  // mode change cannot make the wheel jump to an unrelated face.
  function cyclePreview(step) {
    root.wheelBank = 0
    root.previewFromTop = step < 0
    const steps = root.faceCycle
    let pos = steps.indexOf(root.previewIndex)
    if (pos < 0) pos = 0
    pos = (pos + step + steps.length) % steps.length
    root.previewIndex = steps[pos]
  }

  // Lay the stacked faces out. Each face owns its tweens, so an interrupted
  // swap cannot freeze the face it was taking out as a hidden layer: that
  // face keeps its own animation and either finishes or reverses cleanly.
  function applyPreviewLayers(animate) {
    // Read the raw index, not the faceIndex binding: bindings that depend on
    // previewIndex are still stale when its change handler runs, which would
    // swap in the previous face and leave the label one step behind the index.
    const front = root.previewIndex
    const incoming = faceAt(front)
    if (!animate || front === root.lastFaceIndex) {
      for (let i = 0; i < root.faceCount; i++) {
        slideFor(i).stop()
        fadeFor(i).stop()
        const f = faceAt(i)
        f.opacity = i === front ? 1 : 0
        f.y = 0
      }
      root.lastFaceIndex = front
      return
    }
    const outgoing = faceAt(root.lastFaceIndex)
    const travel = Math.round(timeText.height * 0.7)
    const enterY = root.previewFromTop ? -travel : travel
    const inSlide = slideFor(front)
    const inFade = fadeFor(front)
    if (incoming.opacity > 0) {
      inSlide.from = incoming.y
      inFade.from = incoming.opacity
    } else {
      incoming.y = enterY
      incoming.opacity = 0
      inSlide.from = enterY
      inFade.from = 0
    }
    inSlide.to = 0
    inFade.to = 1
    inSlide.restart()
    inFade.restart()

    const outSlide = slideFor(root.lastFaceIndex)
    const outFade = fadeFor(root.lastFaceIndex)
    outSlide.from = outgoing.y
    outSlide.to = -enterY
    outFade.from = outgoing.opacity
    outFade.to = 0
    outSlide.restart()
    outFade.restart()

    // The face outside this swap is parked; a tween left on it by an earlier
    // interruption must not repaint it over the two live faces.
    for (let i = 0; i < root.faceCount; i++) {
      if (i === front || i === root.lastFaceIndex) continue
      slideFor(i).stop()
      fadeFor(i).stop()
      faceAt(i).opacity = 0
      faceAt(i).y = 0
    }
    root.lastFaceIndex = front
  }

  // Refresh the time and the bubble together: both read clock.date and the
  // same settings, so one pass keeps them in step.
  function refreshLabel() {
    dayText.text = root.dayPart()
    timeText.text = root.timePart(root.showSeconds && !root.showSecondsInTooltip)
    suffixText.text = root.suffixPart()
    previewText.text = root.dateLabel()
    const year = clock.date.getFullYear()
    const pct = CalendarLib.yearProgressPercent(year, clock.date.getMonth(), clock.date.getDate())
    yearText.text = pct + "% of " + year

    // The full-date label says it all, and the year face describes its own
    // figure. Otherwise the detailed date leads and tooltip-only seconds
    // ride along on a second line.
    if (root.fullDate && root.previewIndex === 0) {
      tipText = ""
      return
    }
    if (root.previewIndex === 2) {
      tipText = root.yearTipText()
      return
    }
    const parts = [root.detailedDate()]
    if (root.showSeconds && root.showSecondsInTooltip)
      parts.push(root.timePart(true) + root.suffixPart())
    tipText = parts.join("\n")
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
  onFullDateChanged: {
    // The date face drops out of the cycle in this mode; its position folds
    // back to the clock, while progress keeps its remembered place.
    if (root.fullDate && root.previewIndex === 1) root.previewIndex = 0
    refreshLabel()
  }
  onHoveredChanged: if (root.showSeconds && root.showSecondsInTooltip) refreshLabel()

  onPreviewIndexChanged: {
    refreshLabel()
    root.applyPreviewLayers(root.animOn)
  }

  // First paint: refreshLabel() reads clock.date + renders the time, and
  // the layers start with the clock in front.
  Component.onCompleted: {
    refreshLabel()
    root.applyPreviewLayers(false)
  }

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

      property bool shown: root.fullDate && root.previewIndex === 0
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

    // Faint hairline between the date and the time, present only while the
    // date is shown. Its holder carries the air on both sides and glides open
    // with the date segment, so toggling "Show full date" slides the rule in
    // with the text instead of snapping it into place.
    Item {
      readonly property int ruleGap: 10
      property bool shown: root.fullDate && root.previewIndex === 0
      clip: true
      implicitWidth: width
      width: shown ? ruleGap + rule.width + ruleGap : 0
      height: timeText.height
      Behavior on width { enabled: root.animOn; Glide { duration: Ui.fastMs } }
      onShownChanged: if (shown && root.animOn) ruleFade.restart()

      Rectangle {
        id: rule
        anchors.centerIn: parent
        width: 1
        height: Math.round(timeText.height * 0.7)
        color: Ui.tint("foreground_1", 0.45)
      }

      NumberAnimation {
        id: ruleFade
        target: rule
        property: "opacity"
        from: 0
        to: 1
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }

    // The clock, the short date and the year progress share one slot. Only
    // the indexed front face is opaque; each swap slidefades one face out
    // and another in along the scroll axis while the holder glides between
    // their widths.
    Item {

      id: timeSlot

      clip: true
      implicitWidth: width
      width: root.faceIndex === 0 ? timeText.implicitWidth
        : root.faceIndex === 1 ? previewText.implicitWidth
        : yearText.implicitWidth
      height: timeText.height
      Behavior on width { enabled: root.animOn; Glide { duration: Ui.fastMs } }

      Title {
        id: timeText
        level: 1
        font.pixelSize: Math.round(Ui.fontM * root.textScale)
        font.bold: false
        text: ""
      }

      Title {
        id: previewText
        level: 1
        font.pixelSize: Math.round(Ui.fontM * root.textScale)
        font.bold: false
        text: ""
      }

      Title {
        id: yearText
        level: 1
        font.pixelSize: Math.round(Ui.fontM * root.textScale)
        font.bold: false
        text: ""
      }

      NumberAnimation {
        id: slide0
        target: timeText
        property: "y"
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: fade0
        target: timeText
        property: "opacity"
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: slide1
        target: previewText
        property: "y"
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: fade1
        target: previewText
        property: "opacity"
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: slide2
        target: yearText
        property: "y"
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        id: fade2
        target: yearText
        property: "opacity"
        duration: Ui.fastMs
        easing.type: Easing.OutCubic
      }
    }

    Item {

      property bool shown: root.use12h && root.faceIndex === 0
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

  // Up walks forward through the faces, down walks back, in either date mode.
  // Both the step and the index are remembered; no setting is written.
  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    onWheel: event => {
      if (event.angleDelta.y === 0) return
      event.accepted = true
      root.wheelBank += event.angleDelta.y
      if (Math.abs(root.wheelBank) < root.wheelNotch) return
      // Qt's positive delta is the wheel rolled up; negative is down.
      root.cyclePreview(root.wheelBank > 0 ? 1 : -1)
    }
  }

  // A date already on the label needs no bubble, whether it got there from
  // the setting or from a scroll step.
  barTipActive: root.hovered && root.tipWanted && !root.islandOpen
  barTipText: root.tipText

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
