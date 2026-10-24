// Shared formatting for the per-unit self-description verbs. Each unit's
// IpcHandler exposes help(command) plus status/ping; this helper builds the
// text so every unit answers one CLI-shaped block.
//
// The verb list stays plain data: { name, help, signature? }. An argument
// group leading the help string - "(path) set the wallpaper" - renders as
// usage "<path>" with the remainder as the description. A signature, when
// present, wins over the paren group ("(id)" renders "<id>") and is printed
// as-is otherwise. Nothing else is interpreted.
//
// All helpers live inside help(): a .pragma library exposes every top-level
// declaration, and this file publishes exactly one name.
.pragma library

function help(target, title, description, verbs, query) {
  // One argument word as a usage placeholder. A word the author already
  // wrapped in brackets names an optional argument and is kept as-is, so
  // "(minutes, [command])" renders "<minutes> [command]".
  function placeholder(word) {
    var w = word.trim()
    if (w === "") return ""
    if (w.charAt(0) === "[" && w.charAt(w.length - 1) === "]") return w
    return "<" + w + ">"
  }

  // "(a, b) rest" -> { usage: "<a> <b>", rest: "rest" }. A string without a
  // leading paren group carries no arguments; the whole string is prose.
  function splitArgs(text) {
    var m = /^\(([^\)]*)\)\s*/.exec(text)
    if (!m) return { usage: "", rest: text }
    var words = m[1].split(",")
    var usage = ""
    for (var i = 0; i < words.length; i++) {
      var ph = placeholder(words[i])
      if (ph !== "") usage += (usage === "" ? "" : " ") + ph
    }
    return { usage: usage, rest: text.slice(m[0].length) }
  }

  // The usage fragment for one verb, with a leading space or empty. A
  // signature wins over the paren group; a falsy signature (the no-argument
  // spelling) falls through to the paren parse.
  function usageOf(verb) {
    var sig = verb.signature
    if (typeof sig === "string" && sig !== "") {
      var trimmed = sig.trim()
      var m = /^\((.*)\)$/.exec(trimmed)
      if (!m) return " " + trimmed
      var parts = m[1].split(",")
      var out = ""
      for (var i = 0; i < parts.length; i++) {
        var p = placeholder(parts[i])
        if (p !== "") out += (out === "" ? "" : " ") + p
      }
      return out === "" ? " " + trimmed : " " + out
    }
    if (sig) return " " + String(sig)
    var split = splitArgs(verb.help || "")
    return split.usage === "" ? "" : " " + split.usage
  }

  // The prose half of one verb. A signature leaves the help string intact;
  // otherwise the leading paren group belongs to the usage column.
  function descOf(verb) {
    if (verb.signature) return verb.help || ""
    return splitArgs(verb.help || "").rest
  }

  // A fragment as one sentence: capitalised, closed with a period unless it
  // already ends with terminal punctuation. Tables keep the verbatim text;
  // only the Description paragraph and the single-verb block read as prose.
  function sentence(text) {
    var s = String(text || "")
    if (s === "") return ""
    var head = s.charAt(0)
    if (head >= "a" && head <= "z") s = head.toUpperCase() + s.slice(1)
    var tail = s.charAt(s.length - 1)
    if (tail !== "." && tail !== "!" && tail !== "?") s += "."
    return s
  }

  // The full row set: the unit's verbs in order, then the fixed suffix. A
  // unit-supplied status or ping line is kept and the standard one appended;
  // the suffix is positional, not a lookup.
  function rowsOf() {
    var rows = []
    for (var i = 0; i < verbs.length; i++) {
      var v = verbs[i]
      rows.push({ name: v.name, usage: usageOf(v), desc: descOf(v) })
    }
    rows.push({ name: "status", usage: "", desc: "health + unit payload" })
    rows.push({ name: "ping", usage: "", desc: "liveness" })
    rows.push({ name: "help", usage: " [command]", desc: "show help for one command" })
    return rows
  }

  // Two-space indent, one padded column, verbatim descriptions. Lines with
  // no description carry no trailing whitespace.
  function table(rows) {
    var width = 0
    for (var i = 0; i < rows.length; i++) {
      var head = String(rows[i].name) + rows[i].usage
      if (head.length > width) width = head.length
    }
    var out = ""
    for (var j = 0; j < rows.length; j++) {
      var h = String(rows[j].name) + rows[j].usage
      var line = "  " + h
      for (var k = h.length; k < width; k++) line += " "
      line += "  " + String(rows[j].desc)
      out += line.replace(/\s+$/, "") + "\n"
    }
    return out
  }

  var rows = rowsOf()
  var q = query === undefined || query === null ? "" : String(query)
  if (q !== "") {
    for (var i = 0; i < rows.length; i++) {
      if (String(rows[i].name) === q) {
        var found = rows[i]
        var block = "Usage: vb-shell " + target + " " + String(found.name) + found.usage + "\n"
        var prose = sentence(found.desc)
        if (prose !== "") block += "\n" + prose + "\n"
        return block + "\nRun `vb-shell " + target + " help` to list all commands.\n"
      }
    }
    return "error: unknown command '" + q + "'\nRun `vb-shell " + target + " help` to list all commands.\n"
  }
  return "Usage: vb-shell " + target + " <command> [args...]\n"
    + "\n" + sentence(description) + "\n"
    + "\nCommands:\n" + table(rows)
    + "\nExamples:\n  vb-shell " + target + " help status\n"
    + "\nRun `vb-shell help` to list all units.\n"
}
