// Shared clock labels (qs.common.text).
//
// Single source for the four clocks: NotificationsLib clockLabel, bar
// Clock.qml timePart, ClipboardLib formatTime. The 12-hour fold lives here
// once (foldHour12) so the bar clock and the notification card can never
// disagree by an hour for half the day. Pure JS, pragma library, no Qt
// imports - the QML side keeps Qt.formatDateTime for rendering, this file
// owns the fold and the pure labels.
.pragma library

.import "Format.js" as Format

// Hour fold for 12-hour display: hour 0 is 12, hour 13 is 1.
// Canonical home of the fold Clock.qml:timePart and
// NotificationsLib:clockLabel share.
function foldHour12(hours) {
  let h = Number(hours)
  if (!isFinite(h)) return 12
  return (Math.floor(h) % 12) || 12
}

// Zero-padded clock fields with the AM/PM suffix `use12h` asks for. The
// one place the suffix decision and the field padding are applied, so the
// card clock and the copy clock cannot disagree on either.
function clockText(hours, minutes, use12h) {
  let h = hours
  let suffix = ""
  if (use12h === true) {
    suffix = h < 12 ? " AM" : " PM"
    h = foldHour12(h)
  }
  return Format.pad2(h) + ":" + Format.pad2(minutes) + suffix
}

// The card's clock, in the same format the bar's clock module uses: local
// time, zero-padded hours and minutes, and an AM/PM suffix when `use12h`
// is set. Canonical home of NotificationsLib clockLabel. "" for a time
// that is not a number, which is what an entry that never recorded an
// arrival carries.
function clockLabel(atMs, use12h) {
  let ms = Number(atMs)
  if (!isFinite(ms)) return ""
  let at = new Date(ms)
  return clockText(at.getHours(), at.getMinutes(), use12h)
}

// A wall-clock hour as the weather strip prints it: "9 PM" on the 12-hour
// dial, "21:00" on the 24-hour one. The hour is data, not a Date, because a
// forecast entry carries its target-zone wall hour rather than an instant.
function formatHour(hours, use12h) {
  let h = Number(hours)
  if (!isFinite(h)) return ""
  if (use12h === true) {
    return foldHour12(h) + (Math.floor(h) % 24 < 12 ? " AM" : " PM")
  }
  return Format.pad2(((Math.floor(h) % 24) + 24) % 24) + ":00"
}

// Memoized day labels: one Intl format per calendar day instead of one per
// row. A clipboard history or a notification pile that spans more than one
// day prints the old rows' date with every row, and toLocaleDateString was
// measured at ~48us a call - 14.4ms for 300 rows across five days. The label
// is a function of the calendar day and the locale, neither of which moves
// within a session, so it is cached by day and the cache is emptied whole
// when it fills rather than tracked for eviction.
let DAY_LABEL_MAX = 64
let _dayLabels = ({})
let _dayLabelCount = 0

function dayLabelOf(d) {
  let key = d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
  let hit = _dayLabels[key]
  if (hit !== undefined) return hit
  let day
  try {
    day = d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
  } catch (e) {
    day = Format.pad2(d.getDate()) + "." + Format.pad2(d.getMonth() + 1)
  }
  if (_dayLabelCount >= DAY_LABEL_MAX) {
    _dayLabels = ({})
    _dayLabelCount = 0
  }
  _dayLabels[key] = day
  _dayLabelCount++
  return day
}

// Copy time. Same calendar day -> clock time, otherwise the day rides along.
// `use12h` follows the shell's TimeFormat config (Printers/Weather islands
// do the same); when unset it reads as 24-hour, matching the shell default.
// `now` is injectable so tests stay deterministic.
function formatTime(ts, now, use12h) {
  // A timestamp that is not a number has no clock reading: the label is "",
  // the same answer clockLabel gives, rather than the "Invalid Date NaN:NaN"
  // an invalid Date renders as.
  let ms = Number(ts)
  if (!isFinite(ms)) return ""
  let d = new Date(ms)
  let ref = now !== undefined ? new Date(now) : new Date()
  let sameDay = d.getFullYear() === ref.getFullYear()
    && d.getMonth() === ref.getMonth()
    && d.getDate() === ref.getDate()
  let time = clockText(d.getHours(), d.getMinutes(), use12h)
  if (sameDay) return time
  return dayLabelOf(d) + " " + time
}

if (typeof module !== "undefined") {
  module.exports = {
    foldHour12: foldHour12,
    clockLabel: clockLabel,
    formatHour: formatHour,
    formatTime: formatTime
  }
}
