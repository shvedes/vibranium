pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.common
import "../../common/text/Clock.js" as ClockFmt

// The lock screen's time and date.
//
// The time is display type, not a label: it is measured at a probe size and
// fitted to the band in both directions, so the digits fill the space the
// surface hands down instead of a fixed pixel size that overflows one output
// and disappears on another. Both dials lead with a zero, so switching the
// time format never shifts the digits; the AM/PM suffix is its own smaller
// line of type, baseline-aligned with the digits: at the same size in the same
// string it read as one shouted word, and floating at the top of the block it
// read as a stray label.
//
// The date is a quiet companion line: title case, medium weight, dim, and
// sized as a fraction of the band rather than as a second headline. Both lines
// are measured against the band, so neither can leave it.
Item {
  id: root

  // Band the block may occupy, measured from the item's top.
  property real maxWidth: 0
  property real maxHeight: 0

  // Date line: an option, and conditional even when asked for. A band that
  // cannot hold a readable line under the clock drops it rather than squeezing
  // both into the same space.
  property bool withDate: false

  readonly property bool use12h: TimeFormat.use12h

  // Time without the suffix. Both dials lead with a zero ("04:01"); the
  // 12-hour dial still prints hour 0 as 12, so midnight and noon read
  // "12:00" rather than "00:00".
  readonly property string timeText: {
    const d = new Date(clock.date)
    if (root.use12h) d.setHours(ClockFmt.foldHour12(d.getHours()))
    return Qt.formatDateTime(d, "hh:mm")
  }
  readonly property string suffixText: {
    if (!root.use12h) return ""
    return clock.date.getHours() < 12 ? "AM" : "PM"
  }
  readonly property string dateText: Qt.formatDateTime(clock.date, "dddd, d MMMM")

  // One measurement at a fixed probe size: the display size follows from the
  // band in both directions without iterating a Fit text.
  TextMetrics {
    id: timeMetrics

    font.family: Ui.fontFamily
    font.bold: true
    font.weight: Font.Black
    font.pixelSize: 100
    text: root.timeText
  }

  // The date hangs just under the digits' baseline, not under the time
  // label's line box: the box carries the font's descent, which at display
  // sizes left a gap wide enough to read as a separate block.
  readonly property real dateGap: Math.round(root.maxHeight * 0.12)
  readonly property real datePx: Math.max(Ui.fontL, Math.round(root.maxHeight * 0.09))
  readonly property real dateH: Math.round(root.datePx * 1.4)
  readonly property bool dateShown: root.withDate
    && root.dateH + root.dateGap <= Math.round(root.maxHeight * 0.4)
  readonly property real dateTop: timeLabel.baselineOffset + root.dateGap
  readonly property real timeH: Math.max(0,
    root.maxHeight - (root.dateShown ? root.dateGap + root.dateH : 0))

  // The suffix is sized as a share of the digits and reserving its width in
  // the fit is what keeps it from pushing the time off the band. The reserve
  // is a fraction of the resolved size, so it stays correct at every scale.
  readonly property real timePx: {
    const w = timeMetrics.width / 100
    const h = timeMetrics.height / 100
    if (w <= 0 || h <= 0) return 1
    const reserve = root.use12h ? 0.46 : 0
    const byWidth = root.maxWidth / (w + reserve)
    const byHeight = root.timeH / h
    return Math.max(1, Math.floor(Math.min(byWidth, byHeight)))
  }
  readonly property real suffixPx: Math.max(Ui.fontS, Math.round(root.timePx * 0.26))
  readonly property real suffixGap: Math.round(root.timePx * 0.05)

  implicitWidth: Math.max(timeLabel.width, dateLabel.implicitWidth)
  implicitHeight: root.dateShown ? root.dateTop + root.dateH : timeGroup.height
  width: root.maxWidth
  height: Math.min(root.implicitHeight, root.maxHeight)

  // Minute precision: the block re-renders once a minute.
  SystemClock {
    id: clock
  }

  // Time group: digits, then the suffix against the same baseline. Positioned
  // by hand rather than in a Row so the suffix can sit on the digits' baseline
  // instead of floating at the top of the line box.
  Item {
    id: timeGroup

    anchors.top: parent.top
    // The digits, not the digits-plus-suffix, hold the optical centre; the
    // suffix hangs off their right edge. Centring the whole group shifted the
    // time visibly left of the date line underneath it.
    x: Math.round((root.width - timeLabel.width) / 2)
    width: timeLabel.width
      + (suffixLabel.visible ? root.suffixGap + suffixLabel.width : 0)
    height: timeLabel.height

    Text {
      id: timeLabel

      x: 0
      y: 0
      text: root.timeText
      textFormat: Text.PlainText
      color: Theme.color("foreground_0")
      font.family: Ui.fontFamily
      font.bold: true
      // The heaviest weight the family ships. Qt folds an unavailable weight
      // back to the nearest face, so this asks for the boldest variant without
      // naming a font the theme does not have.
      font.weight: Font.Black
      font.pixelSize: root.timePx
      // Display tracking: huge type looks loose at the default fit. The
      // measurement uses no tracking, so the painted string is only ever
      // narrower than the band allows.
      font.letterSpacing: -Math.round(root.timePx * 0.018)
    }

    Text {
      id: suffixLabel

      visible: root.use12h && root.suffixText !== ""
      x: timeLabel.width + root.suffixGap
      // Baseline alignment: the suffix sits on the same line as the digits,
      // not at the top of their line box.
      y: timeLabel.baselineOffset - suffixLabel.baselineOffset
      text: root.suffixText
      textFormat: Text.PlainText
      color: Ui.tint("foreground_1", 0.8)
      font.family: Ui.fontFamily
      font.bold: true
      font.weight: Font.Bold
      font.pixelSize: root.suffixPx
      font.letterSpacing: Math.round(root.suffixPx * 0.06)
    }
  }

  Text {
    id: dateLabel

    y: timeGroup.y + root.dateTop
    anchors.horizontalCenter: parent.horizontalCenter
    width: root.maxWidth
    height: root.dateH
    visible: root.dateShown
    text: root.dateText
    textFormat: Text.PlainText
    color: Ui.tint("foreground_1", 0.75)
    font.family: Ui.fontFamily
    font.weight: Font.Medium
    font.pixelSize: Math.max(1, Math.round(root.datePx * 1.3))
    fontSizeMode: Text.Fit
    minimumPixelSize: 1
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
