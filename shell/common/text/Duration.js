// Shared duration formatting (qs.common.text).
//
// Single source for the two formatDuration contracts plus the clipboard
// mediainfo form: Battery "2h 15m", Timer "1h 2m 3s", Clipboard "0:02.038".
// The three contracts disagree on purpose (a battery estimate, a countdown
// readout, a media timestamp), so they keep three names instead of one
// function with a flag. Pure JS, pragma library, no Qt imports.
.pragma library

.import "Format.js" as Format

// Seconds (UPower timeToEmpty/timeToFull) -> "2h 15m" / "40m" / "<1m".
// Canonical home of BatteryModel formatDuration. Zero/negative/non-finite
// means "no estimate" and renders as "" so callers can skip the fragment.
function formatDuration(seconds) {
  var s = Number(seconds)
  if (!isFinite(s) || s <= 0) return ""
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) return m > 0 ? h + "h " + m + "m" : h + "h"
  if (m > 0) return m + "m"
  return "<1m"
}

// Countdown readout -> "1h 2m 3s" / "2m 5s" / "0s".
// Canonical home of Timer.qml formatDuration. Floor semantics: a
// countdown shows whole seconds remaining, never a fraction.
function formatVerboseDuration(secs) {
  var s = Math.max(0, Math.floor(Number(secs)))
  if (!(s > 0)) return "0s"
  var h = Math.floor(s / 3600)
  s %= 3600
  var m = Math.floor(s / 60)
  var sec = s % 60
  var out = ""
  if (h > 0) out += h + "h "
  if (m > 0 || h > 0) out += m + "m "
  out += sec + "s"
  return out.trim()
}

// "2 s 38 ms" -> "0:02.038", "12 min 3 s" -> "12:03", "1 h 2 min" ->
// "1:02:00". Canonical home of ClipboardLib formatMediaDuration.
// Sub-second precision only survives below 10 s; longer media round down.
function formatMediaDuration(s) {
  var txt = String(s)
  var sec = 0
  var h = /(\d+)\s*h/.exec(txt)
  var m = /(\d+)\s*min/.exec(txt)
  var secM = /(\d+(?:\.\d+)?)\s*s/.exec(txt)
  var ms = /(\d+)\s*ms/.exec(txt)
  if (h !== null) sec += parseInt(h[1], 10) * 3600
  if (m !== null) sec += parseInt(m[1], 10) * 60
  if (secM !== null) sec += parseFloat(secM[1])
  if (ms !== null) sec += parseInt(ms[1], 10) / 1000
  if (!(sec > 0)) return ""
  var total = Math.floor(sec)
  var hh = Math.floor(total / 3600)
  var mm = Math.floor((total % 3600) / 60)
  var ss = total % 60
  var sub = Math.round((sec - total) * 1000)
  if (hh > 0) return hh + ":" + Format.pad2(mm) + ":" + Format.pad2(ss)
  if (total >= 10 || sub === 0) return mm + ":" + Format.pad2(ss)
  return mm + ":" + Format.pad2(ss) + "."
    + (sub < 10 ? "00" + sub : sub < 100 ? "0" + sub : String(sub))
}

if (typeof module !== "undefined") {
  module.exports = {
    formatDuration: formatDuration,
    formatVerboseDuration: formatVerboseDuration,
    formatMediaDuration: formatMediaDuration
  }
}
