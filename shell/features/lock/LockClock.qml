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
// time format never shifts the digits.
//
// Every changing value uses the same bottom-to-top slidefade: the outgoing
// string rises and fades out while the incoming one rises from below and
// fades in. Each hour, minute and second DIGIT owns a swap, so 11 -> 12 moves
// only the ones digit while 09 -> 10 moves both; seconds ride the same cells
// when the option is on, and the AM/PM initial owns its own swap too. The date
// is one line, so a day change slides the weekday, comma, day and month
// together; the comma cannot be left behind by a separate box resizing.
// The suffix's `M` is static - only `A`/`P` alternates, the way a
// bedroom clock flips just the one flap. Each swap clips to one line, so a
// mid-swap string cannot paint into the digits above.
Item {
  id: root

  // Band the block may occupy, measured from the item's top.
  property real maxWidth: 0
  property real maxHeight: 0

  // Date line: an option, and conditional even when asked for. A band that
  // cannot hold a readable line under the clock drops it rather than squeezing
  // both into the same space.
  property bool withDate: false

  // `showSeconds` follows the lockscreen setting; the preview pins it so the
  // extra movement can be watched on demand. The fixed date and format hooks
  // are the preview's other way to drive the same derivation as the live clock.
  property var fixedDate: null
  property bool use12h: TimeFormat.use12h
  property bool showSeconds: Settings.lockscreenSeconds

  readonly property var sourceDate: root.fixedDate !== null ? root.fixedDate : clock.date

  // Time without the suffix, split so hour and minute each own their swap.
  // Both dials lead with a zero ("04:01"); the 12-hour dial still prints hour
  // 0 as 12, so midnight and noon read "12:00" rather than "00:00".
  readonly property string hourText: {
    const d = new Date(root.sourceDate)
    if (root.use12h) d.setHours(ClockFmt.foldHour12(d.getHours()))
    return Qt.formatDateTime(d, "hh")
  }
  readonly property string minuteText: Qt.formatDateTime(root.sourceDate, "mm")
  readonly property string secondsText: Qt.formatDateTime(root.sourceDate, "ss")
  // Each position owns its own swap: 11 -> 12 moves only the ones digit, while
  // 09 -> 10 moves both. A whole-field swap would animate both on every tick.
  readonly property string hourTens: root.hourText.charAt(0)
  readonly property string hourOnes: root.hourText.charAt(1)
  readonly property string minuteTens: root.minuteText.charAt(0)
  readonly property string minuteOnes: root.minuteText.charAt(1)
  readonly property string secondTens: root.secondsText.charAt(0)
  readonly property string secondOnes: root.secondsText.charAt(1)
  // Only the first letter alternates; the trailing `M` is a static glyph.
  readonly property string suffixInitialText: {
    if (!root.use12h) return ""
    return new Date(root.sourceDate).getHours() < 12 ? "A" : "P"
  }

  // The whole date line is one value: on a day change the weekday, comma, day
  // and month rise and fade together. Keeping the punctuation inside the same
  // string is what stops a gap opening between the weekday and its comma.
  readonly property string dateText: Qt.formatDateTime(root.sourceDate, "dddd, d MMMM")

  // A local alias of the shared slow token: every swap reads this one value,
  // and none of them carries a private copy of a tween's length.
  readonly property int flipDuration: Ui.slowMs

  // One measurement at a fixed probe size, against a FIXED reference string:
  // measuring the live dials would resize the whole clock whenever a glyph's
  // advance differed, which is exactly the drift a fixed-pitch face must not
  // show. The display size follows from the band without iterating a Fit.
  TextMetrics {
    id: timeMetrics

    font.family: Ui.fontFamily
    font.bold: true
    font.weight: Font.Black
    font.pixelSize: 100
    font.letterSpacing: -2
    // Fixed references, never the live dials: a glyph's advance must not
    // resize the clock. The second metrics is the same line with seconds.
    text: "88:88"
  }

  TextMetrics {
    id: secondsMetrics

    font.family: Ui.fontFamily
    font.bold: true
    font.weight: Font.Black
    font.pixelSize: 100
    font.letterSpacing: -2
    text: "88:88:88"
  }

  // A colon at the probe size splits the full measurement into digit cells.
  // Fixed cells keep the remaining digits still when one changes.
  TextMetrics {
    id: colonMetrics

    font.family: Ui.fontFamily
    font.weight: Font.Black
    font.pixelSize: 100
    font.letterSpacing: -2
    text: ":"
  }
  readonly property int digitCount: root.showSeconds ? 6 : 4
  readonly property int colonCount: root.showSeconds ? 2 : 1
  readonly property real refLineW: root.showSeconds
    ? secondsMetrics.width : timeMetrics.width
  // Adding seconds adds cells, not screen space: the whole clock scales by
  // the ratio of the two fixed reference lines, so the extra digits make the
  // line denser instead of larger. Derived, not a tuned magic number.
  readonly property real lineScale: root.showSeconds
    ? timeMetrics.width / secondsMetrics.width : 1
  readonly property real digitW: Math.max(1, Math.ceil(
    (root.refLineW - root.colonCount * colonMetrics.width)
      * root.timePx / (100 * root.digitCount)))

  // The date hangs just under the digits' baseline, not under the time's line
  // box: that box carries the font's descent, which at display sizes left a
  // gap wide enough to read as a separate block.
  readonly property real dateGap: Math.round(root.maxHeight * 0.12)
  readonly property real datePx: Math.max(Ui.fontL, Math.round(root.maxHeight * 0.09))
  readonly property real dateH: Math.round(root.datePx * 1.4)
  readonly property bool dateShown: root.withDate
    && root.dateH + root.dateGap <= Math.round(root.maxHeight * 0.4)
  readonly property int dateFontPx: Math.max(1, Math.round(root.datePx * 1.3))

  TextMetrics {
    id: dateMetrics

    font.family: Ui.fontFamily
    font.weight: Font.Medium
    font.pixelSize: root.dateFontPx
    text: root.dateText
  }

  // Text.Fit cannot report the size it settled on, and the animated parts
  // need one font size they all share. Deriving it from the same full-string
  // measurement keeps the line inside the band without a fit per part.
  readonly property int dateRenderPx: Math.max(1, Math.floor(
    root.dateFontPx * Math.min(1, root.maxWidth / Math.max(1, dateMetrics.width))))
  readonly property real dateTop: hourTensSwap.baselineOffset + root.dateGap
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
    return Math.max(1, Math.floor(Math.min(byWidth, byHeight) * root.lineScale))
  }
  readonly property real suffixPx: Math.max(Ui.fontS, Math.round(root.timePx * 0.26))
  readonly property real suffixGap: Math.round(root.timePx * 0.05)
  // The two suffix letters get the same fixed-pitch cell, scaled from the
  // digit cell, so the A/P flip cannot resize the time group.
  readonly property real suffixCellW: Math.max(1,
    Math.ceil(root.digitW * root.suffixPx / root.timePx))

  implicitWidth: Math.max(timeGroup.width, dateSwap.width)
  implicitHeight: root.dateShown ? root.dateTop + root.dateH : timeGroup.height
  width: root.maxWidth
  height: Math.min(root.implicitHeight, root.maxHeight)

  // Minute precision: the block re-renders once a minute.
  SystemClock {
    id: clock
  }

  // Time group: three slidefades on one baseline, then the suffix against
  // that same baseline. Positioned by hand rather than in a Row so the suffix
  // can sit on the digits' baseline instead of floating at the top of the box.
  Item {
    id: timeGroup

    anchors.top: parent.top
    // The digits, not the digits-plus-suffix, hold the optical centre; the
    // suffix hangs off their right edge. Centring the whole group shifted the
    // time visibly left of the date line underneath it.
    x: Math.round((root.width - timeGroup.digitsW) / 2)
    width: timeGroup.digitsW + (suffixInitial.visible
      ? root.suffixGap + 2 * root.suffixCellW : 0)
    height: digitsRow.height

    readonly property real digitsW: digitsRow.width

    Row {
      id: digitsRow

      x: 0
      y: 0
      width: root.digitCount * root.digitW + root.colonCount * colonLabel.width
      height: digitsRow.implicitHeight
      spacing: 0

      SlideSwap {
        id: hourTensSwap

        width: root.digitW
        height: implicitHeight
        clip: true
        text: root.hourTens
        color: Theme.color("foreground_0")
        fontFamily: Ui.fontFamily
        fontWeight: Font.Black
        fontSize: root.timePx
        // Display tracking: huge type looks loose at the default fit.
        letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
        slide: timeGroup.height
        duration: root.flipDuration
      }

      SlideSwap {
        id: hourOnesSwap

        width: root.digitW
        height: implicitHeight
        clip: true
        text: root.hourOnes
        color: Theme.color("foreground_0")
        fontFamily: Ui.fontFamily
        fontWeight: Font.Black
        fontSize: root.timePx
        letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
        slide: timeGroup.height
        duration: root.flipDuration
      }

      Text {
        id: colonLabel

        width: root.digitW
        text: ":"
        color: Theme.color("foreground_0")
        font.family: Ui.fontFamily
        font.weight: Font.Black
        font.pixelSize: root.timePx
        font.letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
      }

      SlideSwap {
        id: minuteTensSwap

        width: root.digitW
        height: implicitHeight
        clip: true
        text: root.minuteTens
        color: Theme.color("foreground_0")
        fontFamily: Ui.fontFamily
        fontWeight: Font.Black
        fontSize: root.timePx
        letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
        slide: timeGroup.height
        duration: root.flipDuration
      }

      SlideSwap {
        id: minuteOnesSwap

        width: root.digitW
        height: implicitHeight
        clip: true
        text: root.minuteOnes
        color: Theme.color("foreground_0")
        fontFamily: Ui.fontFamily
        fontWeight: Font.Black
        fontSize: root.timePx
        letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
        slide: timeGroup.height
        duration: root.flipDuration
      }

      Text {
        id: secondColonLabel

        visible: root.showSeconds
        width: root.digitW
        text: ":"
        color: Theme.color("foreground_0")
        font.family: Ui.fontFamily
        font.weight: Font.Black
        font.pixelSize: root.timePx
        font.letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
      }

      SlideSwap {
        id: secondTensSwap

        visible: root.showSeconds
        width: root.digitW
        height: implicitHeight
        clip: true
        text: root.secondTens
        color: Theme.color("foreground_0")
        fontFamily: Ui.fontFamily
        fontWeight: Font.Black
        fontSize: root.timePx
        letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
        slide: timeGroup.height
        duration: root.flipDuration
      }

      SlideSwap {
        id: secondOnesSwap

        visible: root.showSeconds
        width: root.digitW
        height: implicitHeight
        clip: true
        text: root.secondOnes
        color: Theme.color("foreground_0")
        fontFamily: Ui.fontFamily
        fontWeight: Font.Black
        fontSize: root.timePx
        letterSpacing: -Math.round(root.timePx * 0.018)
        horizontalAlignment: Text.AlignHCenter
        slide: timeGroup.height
        duration: root.flipDuration
      }
    }

    // Only the initial alternates; the trailing M is one glyph painted once.
    SlideSwap {
      id: suffixInitial

      visible: root.use12h
      x: timeGroup.digitsW + root.suffixGap
      // Baseline alignment: the initial sits on the same line as the digits,
      // not at the top of their line box.
      y: hourTensSwap.baselineOffset - suffixInitial.baselineOffset
      width: root.suffixCellW
      height: implicitHeight
      clip: true
      text: root.suffixInitialText
      color: Ui.tint("foreground_1", 0.8)
      fontFamily: Ui.fontFamily
      fontWeight: Font.Bold
      fontSize: root.suffixPx
      letterSpacing: Math.round(root.suffixPx * 0.06)
      horizontalAlignment: Text.AlignHCenter
      slide: suffixInitial.height
      duration: root.flipDuration
    }

    Text {
      id: suffixM

      visible: root.use12h
      x: suffixInitial.x + root.suffixCellW
      y: hourTensSwap.baselineOffset - suffixM.baselineOffset
      width: root.suffixCellW
      text: "M"
      color: Ui.tint("foreground_1", 0.8)
      font.family: Ui.fontFamily
      font.weight: Font.Bold
      font.pixelSize: root.suffixPx
      font.letterSpacing: Math.round(root.suffixPx * 0.06)
      horizontalAlignment: Text.AlignHCenter
    }
  }

  // One slidefade for the whole date line. A single string keeps the comma
  // glued to the weekday. The box is the full band with centred text, like the
  // original date label: there is no second width animation to fall out of
  // step with the swap, and every layer derives its position from this one box.
  SlideSwap {
    id: dateSwap

    y: root.dateTop
    width: root.maxWidth
    height: root.dateH
    visible: root.dateShown
    clip: true
    text: root.dateText
    color: Ui.tint("foreground_1", 0.75)
    fontFamily: Ui.fontFamily
    fontWeight: Font.Medium
    fontSize: root.dateRenderPx
    horizontalAlignment: Text.AlignHCenter
    slide: root.dateH
    duration: root.flipDuration
  }
}
