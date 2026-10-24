// Shared number/size formatting (qs.common.text).
//
// Single source for the historically duplicated helpers: CalendarLib /
// ClipboardLib / NotificationsLib pad2, Network formatBytes/formatRate,
// Battery formatWatts, Clipboard trim1. Pure JS, pragma library, no Qt
// imports - unit-testable and importable from any .js module via
// `.import "Format.js" as Format`, or from QML via `import ... as Format`.
.pragma library

// Two-digit zero padding. Canonical home of the CalendarLib /
// ClipboardLib / NotificationsLib pad2 triple.
function pad2(value) {
  var n = Number(value)
  return (n < 10 ? "0" : "") + n
}

// One decimal unless it rounds away ("1024.0 KB" -> "1024 KB").
// Canonical home of ClipboardLib trim1.
function trim1(n) {
  var s = Number(n).toFixed(1)
  return s.endsWith(".0") ? s.substring(0, s.length - 2) : s
}

// Byte counters -> "12 B" / "1.5 KB" / "2.0 MB" / "3.25 GB".
// Canonical home of Network formatBytes. Floors hostile input at 0 so a
// missing counter reads as empty rather than NaN.
function formatBytes(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n < 0) n = 0
  if (n < 1024) return Math.round(n) + " B"
  if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB"
  if (n < 1024 * 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " MB"
  return (n / (1024 * 1024 * 1024)).toFixed(2) + " GB"
}

// Throughput form of formatBytes. Canonical home of Network formatRate;
// Network/Model.js keeps formatRate as a wrapper over this.
function formatByteRate(bytesPerSec) {
  return formatBytes(bytesPerSec) + "/s"
}

// Watts (UPower changeRate: positive while charging, negative while
// discharging) -> "8.4 W" / "-2.1 W". Canonical home of Battery
// formatRate. Zero/non-finite means "no reading" and renders as "" so
// callers can skip the fragment.
function formatWatts(watts) {
  var w = Number(watts)
  if (!isFinite(w) || w === 0) return ""
  var r = Math.round(w * 10) / 10
  if (r === 0) return ""
  return r.toFixed(1) + " W"
}

if (typeof module !== "undefined") {
  module.exports = {
    pad2: pad2,
    trim1: trim1,
    formatBytes: formatBytes,
    formatByteRate: formatByteRate,
    formatWatts: formatWatts
  }
}
