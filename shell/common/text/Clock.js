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
  var h = Number(hours)
  if (!isFinite(h)) return 12
  return (Math.floor(h) % 12) || 12
}

// The card's clock, in the same format the bar's clock module uses: local
// time, zero-padded hours and minutes, and an AM/PM suffix when `use12h`
// is set. Canonical home of NotificationsLib clockLabel. "" for a time
// that is not a number, which is what an entry that never recorded an
// arrival carries.
function clockLabel(atMs, use12h) {
  var ms = Number(atMs)
  if (!isFinite(ms)) return ""
  var at = new Date(ms)
  var hours = at.getHours()
  var suffix = ""
  if (use12h === true) {
    suffix = hours < 12 ? " AM" : " PM"
    hours = foldHour12(hours)
  }
  return Format.pad2(hours) + ":" + Format.pad2(at.getMinutes()) + suffix
}

// Copy time. Same calendar day -> clock time, otherwise the day rides along.
// `use12h` follows the shell's TimeFormat config (Printers/Weather islands
// do the same); when unset it reads as 24-hour, matching the shell default.
// `now` is injectable so tests stay deterministic.
function formatTime(ts, now, use12h) {
  var d = new Date(ts)
  var ref = now !== undefined ? new Date(now) : new Date()
  var sameDay = d.getFullYear() === ref.getFullYear()
    && d.getMonth() === ref.getMonth()
    && d.getDate() === ref.getDate()
  var hours = d.getHours()
  var suffix = ""
  if (use12h === true) {
    suffix = hours < 12 ? " AM" : " PM"
    hours = foldHour12(hours)
  }
  var time = Format.pad2(hours) + ":" + Format.pad2(d.getMinutes()) + suffix
  if (sameDay) return time
  var day
  try {
    day = d.toLocaleDateString(undefined, { month: "short", day: "numeric" })
  } catch (e) {
    day = Format.pad2(d.getDate()) + "." + Format.pad2(d.getMonth() + 1)
  }
  return day + " " + time
}

if (typeof module !== "undefined") {
  module.exports = {
    foldHour12: foldHour12,
    clockLabel: clockLabel,
    formatTime: formatTime
  }
}
