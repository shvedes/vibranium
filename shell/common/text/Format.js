// Shared number/size formatting (qs.common.text).
//
// Single source for the historically duplicated helpers: CalendarLib /
// ClipboardLib / NotificationsLib pad2, Network formatBytes/formatRate,
// Battery formatWatts, Clipboard trim1. Pure JS, pragma library, no Qt
// imports - unit-testable and importable from any .js module via
// `.import "Format.js" as Format`, or from QML via `import ... as Format`.
.pragma library

// A numeric reading, or null when the field is absent or not a number. An
// empty string counts as absent: the providers omit a field by writing ""
// as often as by leaving it out. Canonical home of the parse-and-reject
// guard the weather projections repeat for every measured value.
function numberOrNull(value) {
  if (value === undefined || value === null || value === "") return null
  var n = parseFloat(String(value))
  return isNaN(n) ? null : n
}

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

// A normalized level [0, 1] as the whole-percent label the readouts print
// ("42%"). Rounds once, so the digits and any threshold color comparing to
// the same rounded value cannot disagree. Non-numeric input reads as 0%.
// Canonical home of the Math.round(volume * 100) + "%" readout repeated by
// the volume module, its island and the now-playing surfaces.
function percent(ratio) {
  var n = Number(ratio)
  if (!isFinite(n)) n = 0
  return Math.round(n * 100) + "%"
}

// A normalized level as the integer percent a colour band and a readout
// compare. Unlike percent(), the scale is not clamped: a boosted level may
// legitimately read above 100. Non-numeric input reads as 0.
function percentInt(ratio) {
  var n = Number(ratio)
  if (!isFinite(n)) n = 0
  return Math.round(n * 100)
}

// A numeric field's value at a fixed decimal count. The digit count is
// floored and clamped at zero, matching the step rules the menu's numeric
// editors already apply.
function fixed(value, decimals) {
  var places = Math.max(0, Math.floor(Number(decimals) || 0))
  return Number(value).toFixed(places)
}

// A byte count in binary units: "12 B" / "1.5 KiB" / "2.0 MiB". The byte
// field stays whole, every larger unit keeps one decimal, and a non-positive
// or non-finite count reads as "" so a caller can skip the fragment.
function formatBinaryFileSize(bytes) {
  var n = Number(bytes)
  if (!isFinite(n) || n <= 0) return ""
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var i = 0
  var v = n
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024
    i++
  }
  return (i === 0 ? v : v.toFixed(1)) + " " + units[i]
}

// A stored file's size: "" when there is nothing to report, whole bytes below
// a KiB, one trimmed decimal above it. Canonical home of ClipboardLib
// formatSize. NaN and non-positive input answer "" rather than a zero size.
function formatFileSize(bytes) {
  var b = Number(bytes)
  if (isNaN(b) || b <= 0) return ""
  if (b < 1024) return b + " B"
  if (b < 1024 * 1024) return trim1(b / 1024) + " KB"
  if (b < 1024 * 1024 * 1024) return trim1(b / (1024 * 1024)) + " MB"
  return trim1(b / (1024 * 1024 * 1024)) + " GB"
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

// Every public formatter is exported for a node caller. The QML side reaches
// them through the pragma namespace, but a node test or tool that requires this
// file sees only this map, and a formatter missing from it would be a function
// the library documents and no non-QML caller can reach.
if (typeof module !== "undefined") {
  module.exports = {
    numberOrNull: numberOrNull,
    pad2: pad2,
    trim1: trim1,
    percent: percent,
    percentInt: percentInt,
    fixed: fixed,
    formatBinaryFileSize: formatBinaryFileSize,
    formatFileSize: formatFileSize,
    formatBytes: formatBytes,
    formatByteRate: formatByteRate,
    formatWatts: formatWatts
  }
}
