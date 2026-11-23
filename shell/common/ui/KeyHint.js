.pragma library

.import "../text/StringUtils.js" as SU

// The three small helpers behind a footer legend: a key rendered in the
// palette, the same legend with its tags stripped for a screen reader, and
// the escape a runtime string needs before it is put into styled text.
// Pure JS, no Qt import - the key names and their colors stay at the call
// sites, only the markup recipe is shared by the two picker panels.
function key(name, color) {
  return "<font color=\"" + color + "\">" + name + "</font>"
}

function plain(styled) {
  return String(styled).replace(/<[^>]*>/g, "")
}

// The confirm legend splices a file name into styled text. Delegate rather
// than spell out a third escape: StringUtils owns this implementation.
function escape(text) {
  return SU.escapeHtml(text)
}

if (typeof module !== "undefined") {
  module.exports = { key: key, plain: plain, escape: escape }
}
