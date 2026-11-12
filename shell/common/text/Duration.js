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
  const s = Number(seconds)
  if (!isFinite(s) || s <= 0) return ""
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  if (h > 0) return m > 0 ? h + "h " + m + "m" : h + "h"
  if (m > 0) return m + "m"
  return "<1m"
}

// Whole, non-negative seconds split into clock fields. Non-finite input
// reads as zero, which is what both clock formatters render.
function clockFields(seconds) {
  const n = Number(seconds)
  const total = isFinite(n) ? Math.max(0, Math.floor(n)) : 0
  return {
    h: Math.floor(total / 3600),
    m: Math.floor((total % 3600) / 60),
    s: total % 60,
  }
}

// Clock-shaped elapsed/remaining time -> "2:05" / "1:02:05".
// Canonical home of the recording pill's elapsed and the inhibitor's
// countdown, which each built the same fields and the same zero padding.
// Whole seconds, floored; non-finite input reads as 0:00.
function formatClock(seconds) {
  const t = clockFields(seconds)
  if (t.h > 0) return t.h + ":" + Format.pad2(t.m) + ":" + Format.pad2(t.s)
  return t.m + ":" + Format.pad2(t.s)
}

// Track clock with an always-padded minutes field: "00:05" / "01:01" /
// "1:01:01". The hour field appears only once the track reaches one, so a
// column reserved from the track's own length keeps its shape across the
// hour boundary. Canonical home of NowPlaying fmtDuration.
function formatTrackClock(seconds) {
  const t = clockFields(seconds)
  const tail = Format.pad2(t.m) + ":" + Format.pad2(t.s)
  return t.h > 0 ? t.h + ":" + tail : tail
}

// Countdown readout -> "1h 2m 3s" / "2m 5s" / "0s".
// Canonical home of Timer.qml formatDuration. Floor semantics: a
// countdown shows whole seconds remaining, never a fraction.
function formatVerboseDuration(secs) {
  let s = Math.max(0, Math.floor(Number(secs)))
  if (!(s > 0)) return "0s"
  const h = Math.floor(s / 3600)
  s %= 3600
  const m = Math.floor(s / 60)
  const sec = s % 60
  let out = ""
  if (h > 0) out += h + "h "
  if (m > 0 || h > 0) out += m + "m "
  out += sec + "s"
  return out.trim()
}

// "2 s 38 ms" -> "0:02.038", "12 min 3 s" -> "12:03", "1 h 2 min" ->
// "1:02:00". Canonical home of ClipboardLib formatMediaDuration.
// Sub-second precision only survives below 10 s; longer media round down.
function formatMediaDuration(s) {
  const txt = String(s)
  let sec = 0
  const h = /(\d+)\s*h/.exec(txt)
  const m = /(\d+)\s*min/.exec(txt)
  const secM = /(\d+(?:\.\d+)?)\s*s/.exec(txt)
  const ms = /(\d+)\s*ms/.exec(txt)
  if (h !== null) sec += parseInt(h[1], 10) * 3600
  if (m !== null) sec += parseInt(m[1], 10) * 60
  if (secM !== null) sec += parseFloat(secM[1])
  if (ms !== null) sec += parseInt(ms[1], 10) / 1000
  if (!(sec > 0)) return ""
  let total = Math.floor(sec)
  let sub = Math.round((sec - total) * 1000)
  // A fraction that rounds up to a full second carries into the seconds
  // field. Without the carry the tail prints four digits - 2.9996 s renders
  // as "0:02.1000" - because the fraction is rounded before the field split.
  if (sub >= 1000) {
    sub = 0
    total += 1
  }
  const hh = Math.floor(total / 3600)
  const mm = Math.floor((total % 3600) / 60)
  const ss = total % 60
  if (hh > 0) return hh + ":" + Format.pad2(mm) + ":" + Format.pad2(ss)
  if (total >= 10 || sub === 0) return mm + ":" + Format.pad2(ss)
  return mm + ":" + Format.pad2(ss) + "."
    + (sub < 10 ? "00" + sub : sub < 100 ? "0" + sub : String(sub))
}

if (typeof module !== "undefined") {
  module.exports = {
    formatDuration: formatDuration,
    formatClock: formatClock,
    formatTrackClock: formatTrackClock,
    formatVerboseDuration: formatVerboseDuration,
    formatMediaDuration: formatMediaDuration
  }
}
