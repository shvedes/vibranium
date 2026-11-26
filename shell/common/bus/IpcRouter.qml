pragma Singleton

import QtQml
import Quickshell
import qs.common

// The common dispatch mechanism for the public `vb-shell` surface.
//
// Owners register explicit maps from catalog row IDs to constant functions.
// No feature or service is imported here, no function is selected by an
// incoming name, and no arbitrary Registry member is adapted. Everything that
// crosses the wire is a `v1:` envelope validated by IpcProtocol.
//
// This is a singleton, not a `.pragma library`; the two JS modules below are
// library imports.

import "../text/IpcCatalog.js" as Catalog
import "../text/IpcProtocol.js" as Protocol

Singleton {
  id: root

  // Generation identifier: process, startup instant and an ASCII nonce. It is
  // a reference, not a secret: cursors are opaque, not authorization tokens.
  readonly property string incarnation: String(Quickshell.processId) + "-"
    + String(Date.now()) + "-" + String(Math.random()).slice(2).replace(/\D/g, "")

  // target -> { owner, map, describer }. Null-prototype maps, own keys only.
  property var _owners: Object.create(null)
  property var _maps: Object.create(null)
  property var _describers: Object.create(null)
  property var _dispatchRows: Object.create(null)

  // Only these fixed word lists may be invoked from the compositor event bus.
  readonly property var _shortcutWords: ({
    "session.lock": ["session", "lock"],
    "session.lockForSleep": ["session", "lockForSleep"],
    "colorPicker.pick": ["colorPicker", "pick"],
    "power.toggle": ["power", "toggle"],
    "wallpaperPicker.toggle": ["wallpaperPicker", "toggle"],
    "themePicker.toggle": ["themePicker", "toggle"],
    "appLauncher.toggle": ["appLauncher", "toggle"],
    "menu.main": ["menu", "toggle", "file", Paths.settingsCatalogPath + "#main"],
    "menu.utilities": ["menu", "toggle", "file", Paths.settingsCatalogPath + "#utilities"],
    "emojiPicker.toggle": ["emojiPicker", "toggle"],
    "clipboard.window.toggle": ["clipboard", "window", "toggle"],
    "clipboard.clear": ["clipboard", "clear"],
    "screenshots.picker": ["screenshots", "picker"],
    "screenshots.region": ["screenshots", "capture", "region"],
    "screenshots.screen": ["screenshots", "capture", "screen"],
    "audio.volume.down": ["audio", "volume", "down"],
    "audio.volume.up": ["audio", "volume", "up"],
    "audio.volume.toggle": ["audio", "volume", "toggle"],
    "audio.microphone.toggle": ["audio", "microphone", "toggle"],
    "powerProfile.next": ["powerProfile", "next"],
    "bar.showToggle": ["bar", "showToggle"]
  })

  function invokeShortcut(data: string): void {
    const prefix = "vibranium:shortcut:"
    if (!data.startsWith(prefix)) return
    const action = data.slice(prefix.length)
    if (!Object.prototype.hasOwnProperty.call(root._shortcutWords, action)) return
    const result = Protocol.decode(root._invokeWords(root._shortcutWords[action]))
    if (result && !result.ok) Log.warn("shortcut", action, result.error.code)
  }

  // Immutable snapshot paging: at most eight, 4 MiB each, 10 s TTL.
  // _cursors maps an opaque issued cursor to its snapshot id; a consumed
  // cursor is deleted, so reuse and wrong-instance cursors are stale.
  property var _snapshots: Object.create(null)
  property var _cursors: Object.create(null)
  property int _sequence: 0

  // Quickshell's ElapsedTimer starts at construction; one shared clock for
  // every snapshot means a single monotonic source for all TTL decisions.
  ElapsedTimer { id: clock }

  // Deep copy of catalog records: descriptors and snapshots must never alias
  // the catalog's shared arrays. Prose is authored in its final form; the
  // router projects it verbatim.
  function _plainCopy(value) {
    if (Array.isArray(value)) {
      var list = []
      for (var a = 0; a < value.length; a++) list.push(_plainCopy(value[a]))
      return list
    }
    if (value && typeof value === "object") {
      var copy = {}
      var keys = Object.keys(value)
      for (var i = 0; i < keys.length; i++) copy[keys[i]] = _plainCopy(value[keys[i]])
      return copy
    }
    return value
  }

  function error(code, message) {
    return Protocol.encode(Protocol.error(code, message))
  }

  function reply(frame) {
    var text = Protocol.encode(frame)
    if (Protocol.asciiBytes(text) > Protocol.MAX_REPLY_BYTES) {
      return error("oversize", "reply too large")
    }
    return text
  }

  // --- registration --------------------------------------------------------

  function register(target, owner, map, describeInstance) {
    var t = Catalog.findTarget(target)
    if (!t || owner === null || owner === undefined || !map || typeof map !== "object") return false
    var flat = Object.create(null)
    var keys = Object.keys(map)
    for (var i = 0; i < keys.length; i++) {
      var id = keys[i]
      if (typeof map[id] !== "function") return false
      if (!Object.prototype.hasOwnProperty.call(map, id)) return false
      var r = Catalog.findRow(id)
      if (!r || r.id.slice(0, target.length + 1) !== target + ".") return false
      if (r.route === "injected" && r.id !== target + ".status" && r.id !== target + ".ping") return false
      if (r.route === "clipboard-copy" || r.route === "log-read") return false
      flat[id] = map[id]
    }
    root._owners[target] = owner
    root._maps[target] = flat
    root._describers[target] = typeof describeInstance === "function" ? describeInstance : null
    return true
  }

  // Removal is conditional on owner identity: a late destruction hook from a
  // previous generation must not retire the replacement's registration.
  function unregister(target, owner) {
    if (root._owners[target] !== owner) return false
    delete root._owners[target]
    delete root._maps[target]
    delete root._describers[target]
    return true
  }

  function registered(target) {
    return root._owners[target] !== undefined && root._owners[target] !== null
  }

  // --- descriptors and paging ----------------------------------------------

  function rowForPath(t, path) {
    var i, j
    for (i = 0; i < t.rows.length; i++) {
      var r = t.rows[i]
      if (r.helpOnly === true) continue
      if (r.id === t.id + "." + path.join(".")) return r
    }
    for (i = 0; i < t.rows.length; i++) {
      var row = t.rows[i]
      if (row.helpOnly === true) continue
      var literals = []
      for (j = 0; j < row.words.length; j++) {
        if (typeof row.words[j] !== "string") break
        literals.push(row.words[j])
      }
      if (literals.length !== path.length) continue
      var same = true
      for (j = 0; j < path.length; j++) if (literals[j] !== path[j]) same = false
      if (same) return row
    }
    return null
  }

  // Branch keys use named placeholders (`module.ID.island`). A concrete help
  // path supplies real instance ids (`module volume island`); matching literal
  // segments exactly and treating upper-case segments as wildcards keeps every
  // branch page to its own children. Exact keys win over placeholder keys.
  function _branchFor(t, rest) {
    var keys = Object.keys(t.branches)
    var fallback = null
    for (var i = 0; i < keys.length; i++) {
      var parts = keys[i].split(".")
      if (parts.length !== rest.length) continue
      var exact = true
      var match = true
      for (var j = 0; j < parts.length; j++) {
        var wildcard = /^[A-Z][A-Z0-9_]*$/.test(parts[j])
        if (!wildcard) {
          if (parts[j] !== rest[j]) { match = false; break }
        } else {
          exact = false
        }
      }
      if (!match) continue
      var found = { key: keys[i], value: t.branches[keys[i]] }
      if (exact) return found
      if (!fallback) fallback = found
    }
    return fallback
  }

  // Project a row's words below a branch path. Literal words must match the
  // concrete spelling; arguments consume one path word each. A row that does
  // not belong to this branch keeps its own full signature, which is what
  // makes a branch such as `printers job` able to list hold/release/cancel.
  function _tailWords(row, rest) {
    var wi = 0
    var ri = 0
    while (ri < rest.length && wi < row.words.length) {
      var w = row.words[wi]
      if (w && Array.isArray(w.optional)) break
      if (typeof w === "string") {
        if (w !== rest[ri]) return null
      }
      ri++
      wi++
    }
    if (ri !== rest.length) return null
    return row.words.slice(wi)
  }

  // A discoverable-but-incomplete path earns a help hint. Only catalog words
  // and simple instance ids are echoed; anything else falls back to the fixed
  // unknown-command diagnostic.
  function _safeHintWord(w) {
    return typeof w === "string" && w !== "" && w.charAt(0) !== "-"
      && /^[A-Za-z0-9_.:/@+-]+$/.test(w)
  }

  function _usageHint(t, argv) {
    for (var len = argv.length; len >= 1; len--) {
      var part = argv.slice(0, len)
      var safe = true
      for (var s = 0; s < part.length; s++) {
        if (!_safeHintWord(part[s])) { safe = false; break }
      }
      if (!safe) continue
      if (_branchFor(t, part)) return part
      for (var i = 0; i < t.rows.length; i++) {
        var row = t.rows[i]
        if (row.route === "injected") continue
        var literals = []
        for (var j = 0; j < row.words.length && typeof row.words[j] === "string"; j++) {
          literals.push(row.words[j])
        }
        if (literals.length < len) continue
        var same = true
        for (var k = 0; k < len; k++) {
          if (literals[k] !== part[k]) { same = false; break }
        }
        if (same) return part
      }
    }
    return null
  }

  // An informational reply: the same canonical descriptor `<target> help`
  // renders, delivered as a help-kind data result so the terminal shows the
  // page immediately. No owner is invoked and no view is opened.
  function _helpReply(path) {
    var d = descriptorFor(path)
    if (!d) return error("unknown-command", "no such command")
    if (d.usageOnly === true) {
      return reply({
        v: Protocol.VERSION,
        ok: true,
        data: { usage: d.usage },
        format: { kind: "usage" }
      })
    }
    return reply({
      v: Protocol.VERSION,
      ok: true,
      data: d,
      format: { kind: "help" }
    })
  }

  function _branchCommands(t, branch, rest) {
    var out = []
    var wanted = branch.commands || []
    for (var i = 0; i < wanted.length; i++) {
      var id = wanted[i]
      var r = typeof id === "string" ? Catalog.findRow(id) : id
      if (!r) continue
      var tail = _tailWords(r, rest)
      if (!tail || tail.length === 0) tail = r.words
      // Rows author a full path from the target root (`copy entry ...`), so a
      // branch page must project that path into its own command table instead
      // of repeating the branch keyword (`copy copy entry ...`).
      var usage = typeof r.usage === "string" ? r.usage : Protocol.usage(tail)
      var branchPrefix = rest.join(" ") + " "
      if (usage.indexOf(branchPrefix) === 0) usage = usage.slice(branchPrefix.length)
      out.push({
        id: r.id,
        usage: usage,
        summary: r.summary,
        arguments: r.arguments || [],
        examples: r.examples || []
      })
    }
    return out
  }

  // A path prefix selects rows by their LEADING LITERAL words, not by slicing
  // that many words off every row. `plugin color` must show only color's verb,
  // never calc's or unit's. Rows marked parentHidden stay dispatchable but do
  // not repeat inside a parent page; help-only signatures do appear there.
  function commandsOf(t, prefix) {
    var pre = Array.isArray(prefix) ? prefix : []
    var out = []
    for (var i = 0; i < t.rows.length; i++) {
      var r = t.rows[i]
      if ((r.route === "injected" && r.visible !== true) || r.parentHidden === true) continue
      var literals = []
      for (var j = 0; j < r.words.length && typeof r.words[j] === "string"; j++) {
        literals.push(r.words[j])
      }
      if (pre.length > literals.length) continue
      var same = true
      for (var k = 0; k < pre.length; k++) {
        if (literals[k] !== pre[k]) { same = false; break }
      }
      if (!same) continue
      // A help-only signature is written from the target root on every page
      // it appears on, so the generic branch still reads `plugin [<PLUGIN>]`.
      // Nested placeholders carry a `parent` branch key: they belong to that
      // branch's page, never to the root index or target page.
      if (r.helpOnly === true && r.parent) {
        var owner = _branchFor(t, pre)
        if (!owner || owner.key !== r.parent) continue
      }
      var tail = r.helpOnly === true ? r.words : r.words.slice(pre.length)
      if (tail.length === 0) continue
      out.push({
        id: r.id,
        usage: (function () {
          var u = typeof r.usage === "string" ? r.usage : Protocol.usage(tail)
          var prefix = pre.length > 0 ? pre.join(" ") + " " : ""
          return u.indexOf(prefix) === 0 ? u.slice(prefix.length) : u
        })(),
        summary: r.labelSummary || r.summary,
        // The index shows literal words only; placeholders belong to scoped
        // help. Build the literal form here from the same catalog words rather
        // than letting the client scrub rendered usage strings.
        literal: tail.filter(function (w) { return typeof w === "string" }).join(" "),
        route: r.route,
        output: _plainCopy(r.output)
      })
    }
    return out
  }

  function descriptorFor(path) {
    if (!path || path.length === 0) return null
    var t = Catalog.findTarget(path[0])
    if (!t) return null
    var rest = path.slice(1)
    var branch = rest.length > 0 ? _branchFor(t, rest) : null
    var branchPath = branch ? branch.key : ""
    // A branch with an explicit command table owns this page. Without this,
    // a row whose leading literal equals the branch (e.g. `dump` or `set`)
    // would be mistaken for the leaf and hide the branch's children.
    var row = rest.length > 0 && !(branch && Array.isArray(branch.value.commands))
      ? rowForPath(t, rest) : null
    var usage = "vb-shell " + t.id
    var summary = t.summary
    var arguments_ = []
    var options = []
    var commands = commandsOf(t, rest)
    var output = null
    var notes = t.notes ? t.notes.slice() : []
    var examples = []
    var noExamples = t.noExamples === true
    var usageOnly = false
    if (branch) {
      var b = branch.value
      // Use the concrete spelling from argv, never a dotted internal key.
      usage += " " + rest.join(" ")
      summary = b.summary || summary
      if (Array.isArray(b.arguments)) arguments_ = b.arguments.slice()
      if (Array.isArray(b.options)) options = b.options.slice()
      if (Array.isArray(b.commands)) commands = _branchCommands(t, b, rest)
      if (b.output && typeof b.output === "object") output = b.output
      if (Array.isArray(b.notes)) notes = b.notes.slice()
      if (Array.isArray(b.examples)) examples = b.examples.slice()
      if (b.noExamples === true) noExamples = true
      if (typeof b.usage === "string") usage = b.usage
    }
    if (row) {
      usage += " " + (typeof row.usage === "string" ? row.usage : Protocol.usage(row.words))
      summary = row.summary
      arguments_ = row.arguments || []
      options = row.options || []
      output = row.output || null
      notes = row.notes || []
      examples = row.examples || []
      commands = []
      usageOnly = row.usageOnly === true
    }
    // Examples are authored, never synthesized from the command the caller
    // just typed. A target root never prints an Examples section at all.
    if (path.length <= 1) examples = []
    var describer = root._describers[t.id]
    if (describer && !row) {
      // Presentation only. A failure to describe a dynamic instance keeps the
      // generic page; it must never run plugin or window code.
      try {
        var extra = describer(rest)
        if (extra && typeof extra === "object") {
          if (typeof extra.usage === "string") usage = extra.usage
          if (typeof extra.summary === "string") summary = extra.summary
          if (Array.isArray(extra.commands)) commands = extra.commands
          if (Array.isArray(extra.arguments)) arguments_ = extra.arguments
          if (Array.isArray(extra.options)) options = extra.options
          if (Array.isArray(extra.notes)) notes = extra.notes
          if (Array.isArray(extra.examples) && extra.examples.length > 0) examples = extra.examples
          if (extra.output && typeof extra.output === "object") output = extra.output
        }
      } catch (e) { /* generic help stays available */ }
    }
    return _plainCopy({
      path: path.slice(),
      usage: usage,
      summary: summary,
      arguments: arguments_,
      options: options,
      commands: commands,
      output: output,
      notes: notes,
      examples: examples,
      usageOnly: usageOnly
    })
  }

  function _dropCursorsFor(id) {
    var keys = Object.keys(root._cursors)
    for (var i = 0; i < keys.length; i++) {
      if (root._cursors[keys[i]] === id) delete root._cursors[keys[i]]
    }
  }

  function _evict() {
    var keys = Object.keys(root._snapshots)
    while (keys.length > Protocol.MAX_SNAPSHOTS) {
      _dropCursorsFor(keys[0])
      delete root._snapshots[keys[0]]
      keys.shift()
    }
  }

  function _snapshot(items, meta, kind) {
    var frozen = JSON.parse(JSON.stringify({ items: items, meta: meta === undefined ? null : meta }))
    var encoded = Protocol.asciiJson(frozen)
    if (Protocol.asciiBytes(encoded) > Protocol.MAX_SNAPSHOT_BYTES) return null
    root._sequence++
    var id = String(root._sequence)
    root._snapshots[id] = {
      data: frozen,
      kind: kind,
      seq: 0,
      at: clock.elapsedMs()
    }
    _evict()
    return { id: id, snapshot: root._snapshots[id] }
  }

  function _page(s, id, seq, cursor) {
    if (s.seq !== seq) return error("stale", "cursor already consumed")
    if (clock.elapsedMs() - s.at > Protocol.SNAPSHOT_TTL_MS) {
      _dropCursorsFor(id)
      delete root._snapshots[id]
      return error("stale", "snapshot expired")
    }
    if (cursor) delete root._cursors[cursor]
    var all = s.data.items
    var part = all.slice(seq, seq + Protocol.PAGE_ITEMS)
    var nextCursor = seq + part.length < all.length
      ? Protocol.cursor(root.incarnation, seq + part.length) : null
    var frame = Protocol.page(part, s.data.meta, nextCursor)
    if (nextCursor) root._cursors[nextCursor] = id
    s.seq = seq + part.length
    if (s.seq >= all.length) {
      _dropCursorsFor(id)
      delete root._snapshots[id]
    }
    return reply(frame)
  }

  function _indexPage() {
    var items = []
    var ids = Catalog.targetIds()
    for (var i = 0; i < ids.length; i++) {
      var t = Catalog.findTarget(ids[i])
      var literals = []
      var summaries = []
      // The index is the root parent page: it uses the same leading-literal
      // projection as root help, so hidden child commands are not repeated.
      var children = commandsOf(t, [])
      for (var j = 0; j < children.length; j++) {
        literals.push(children[j].literal)
        summaries.push(children[j].summary || "")
      }
      items.push({
        id: t.id,
        title: t.title,
        summary: t.summary,
        literals: literals,
        summaries: summaries
      })
    }
    var common = []
    var c = Catalog.commonRows()
    for (var j = 0; j < c.length; j++) {
      common.push({ id: c[j].id, usage: Protocol.usage(c[j].words), summary: c[j].summary })
    }
    var s = _snapshot(items, { common: common }, "index")
    if (!s) return error("oversize", "index too large")
    return _page(s.snapshot, s.id, 0, null)
  }

  function _helpPage(path) {
    var d = descriptorFor(path)
    if (!d) {
      if (path.length > 0 && !Catalog.findTarget(path[0])) return error("unknown-target", "no such target")
      return error("unknown-command", "no such command")
    }
    var meta = {
      path: d.path,
      usage: d.usage,
      summary: d.summary,
      arguments: d.arguments,
      options: d.options,
      output: d.output,
      notes: d.notes,
      examples: d.examples
    }
    var s = _snapshot(d.commands, meta, "help")
    if (!s) return error("oversize", "help too large")
    return _page(s.snapshot, s.id, 0, null)
  }

  // --- dispatch ------------------------------------------------------------

  function _closureFor(target, row) {
    var map = root._maps[target]
    if (!map || !Object.prototype.hasOwnProperty.call(map, row.id)) return null
    return map[row.id]
  }

  function _run(target, row, args, tokens, words) {
    var fn = _closureFor(target, row)
    if (!fn) return error("unknown-command", "owner did not register this command")
    var ctx = {
      target: target,
      id: row.id,
      args: args || {},
      tokens: tokens || {},
      words: words || [],
      incarnation: root.incarnation
    }
    var value
    try {
      value = fn(args || {}, ctx)
    } catch (e) {
      return error("internal", "owner failed")
    }
    if (value && typeof value === "object" && typeof value.ok === "boolean"
        && (row.route === "gateway" || (row.route === "injected" && value.v === Protocol.VERSION))) {
      // A successful gateway answer to an order carries no public projection,
      // even when the owner returned one for its own convenience. Errors keep
      // their frame: only ok=true is stripped.
      if (value.ok === true && row.output && row.output.kind === "none") {
        return reply({ v: Protocol.VERSION, ok: true })
      }
      if (value.ok === true && value.format && value.format.kind === "help"
          && value.data && typeof value.data === "object") {
        return reply({ v: Protocol.VERSION, ok: true, data: _plainCopy(value.data),
          format: value.format })
      }
      return reply(value)
    }
    // Injected status rows are owner projections. Most owners still answer
    // with one JSON string (the retained-surface convention); parse it here so
    // status is typed on the wire instead of arriving as a quoted blob. Genuine
    // text statuses fail the parse and keep the ordinary text adapter.
    if (row.route === "injected" && row.id === target + ".status"
        && typeof value === "string") {
      var parsedStatus = null
      try { parsedStatus = JSON.parse(value) } catch (e) { parsedStatus = null }
      if (parsedStatus !== null && typeof parsedStatus === "object") {
        return reply({ v: Protocol.VERSION, ok: true, data: parsedStatus,
          format: { kind: Array.isArray(parsedStatus) ? "table" : "record" } })
      }
    }
    var a = Protocol.adapt(row.reply || { kind: "text" }, value)
    if (!a.ok) return error(a.error, a.message || "action failed")
    var frame = { v: Protocol.VERSION, ok: true }
    // A row that declares no output is silent in both text and JSON, even
    // when a legacy owner still returns a string for its own convenience.
    if (a.data !== undefined && !(row.output && row.output.kind === "none")) {
      frame.data = a.data
      frame.format = Protocol.formatOf(row, a.data)
      if (frame.format.kind === "help" && frame.data && typeof frame.data === "object") {
        frame.data = _plainCopy(frame.data)
      }
    }
    return reply(frame)
  }

  function _invokeCommon(target, row, verb) {
    if (row.route === "clipboard-copy" || row.route === "log-read") {
      return error("unsupported", "this route is client-owned")
    }
    if (verb === "help") {
      return _helpPage([target])
    }
    if (!registered(target)) return error("unavailable", "owner not registered")
    if (verb === "ping") {
      if (_closureFor(target, row)) return _run(target, row, {}, {})
      return reply(Protocol.ok("pong"))
    }
    if (verb === "status") {
      if (!_closureFor(target, row)) return error("unavailable", "no status projection")
      return _run(target, row, {}, {})
    }
    return error("unknown-command", "unknown common command")
  }

  function _rowsFor(target) {
    var dispatch = root._dispatchRows[target.id]
    if (dispatch) return dispatch
    dispatch = []
    for (var i = 0; i < target.rows.length; i++) {
      var row = target.rows[i]
      if (row.route === "injected" || row.helpOnly === true) continue
      var lead = 0
      while (lead < row.words.length && typeof row.words[lead] === "string") lead++
      dispatch.push({ row: row, lead: lead, grammar: Protocol.compile(row.words) })
    }
    // Prefer fixed keywords over placeholders while preserving catalog order on ties.
    dispatch.sort(function (a, b) { return b.lead - a.lead })
    root._dispatchRows[target.id] = dispatch
    return dispatch
  }

  // True when a row's leading literal words are present at the same argv
  // positions. A row whose literals match but whose typed token fails is a
  // bad argument, not an unknown command: the caller named a real leaf.
  function _literalPrefixMatches(row, argv) {
    var at = 0
    for (var i = 0; i < row.words.length; i++) {
      var w = row.words[i]
      if (typeof w === "string") {
        if (at >= argv.length || argv[at] !== w) return false
        at++
      } else if (w && Array.isArray(w.optional)) {
        // Optional literals have no fixed argv position; stop after the
        // literals that do.
        break
      } else {
        at++
      }
    }
    return argv.length >= at
  }

  function invoke(requestText) {
    if (typeof requestText !== "string"
        || Protocol.asciiBytes(requestText) > Protocol.MAX_REQUEST_BYTES) {
      return error("oversize", "request too large")
    }
    var request = Protocol.decode(requestText)
    if (!request) return error("invalid-argument", "invalid envelope")
    var validated = Protocol.validateRequest("invoke", request)
    if (!validated.ok) return error(validated.error, "invalid request")
    if (validated.kind === "next") {
      // A cursor is only ever a key we issued for this incarnation. Reuse and
      // a foreign generation both miss here before any snapshot is read.
      var id = root._cursors[validated.cursor]
      var s = id ? root._snapshots[id] : null
      if (!s) return error("stale", "unknown or consumed cursor")
      var seq = Protocol.parseCursor(validated.cursor, root.incarnation)
      if (seq === null) return error("stale", "wrong instance")
      return _page(s, id, seq, validated.cursor)
    }
    return _invokeWords(validated.argv)
  }

  function _invokeWords(argv) {
    if (argv.length === 0) return error("usage", "no command")
    var target = argv[0]
    var t = Catalog.findTarget(target)
    if (!t) return error("unknown-target", "no such target")
    var rest = argv.slice(1)
    if (rest.length === 0) {
      // A known target with no words is a discoverable page, not an error.
      // The Python client handles a truly empty argv locally.
      return _helpReply([target])
    }

    // The injected verbs are matched before owner rows so `help` can never be
    // captured by a feature row of the same spelling.
    var verb = rest[0]
    if (rest.length === 1 && (verb === "help" || verb === "status" || verb === "ping")) {
      var cr = Catalog.findRow(target + "." + verb)
      if (cr) return _invokeCommon(target, cr, verb)
    }

    var rows = _rowsFor(t)
    var chosen = null
    var m = null
    var badArgument = false
    var namedTypedFailure = false
    var namedArgumentFailure = ""
    for (var i = 0; i < rows.length; i++) {
      var entry = rows[i]
      var candidate = entry.row
      if (entry.lead > 0 && candidate.words[0] !== verb) continue
      var matched = Protocol.matchCompiled(entry.grammar, rest)
      if (matched.ok) {
        chosen = candidate
        m = matched
        break
      }
      // Keep the failure detail: a validation failure on a row whose literal
      // prefix the argv actually named is an argument error. A shape miss on
      // any other row stays an unknown command.
      // Enum and ref leaves keep their existing word-miss classification; a
      // JSON token is the typed value that loses an otherwise named row.
      if (matched.error === "invalid-argument" && _literalPrefixMatches(candidate, rest)) {
        namedTypedFailure = true
        if (matched.badType === "json") badArgument = true
        if ((matched.badType === "enum" || matched.badType === "ref")
          && typeof matched.badName === "string" && matched.badName !== "") {
          // Remember it, but keep looking: a more specific leaf may still
          // match these words (e.g. `opt list` beside `opt <KEY>`).
          if (namedArgumentFailure === "") namedArgumentFailure = matched.badName
        }
      }
    }
    if (!chosen) {
      if (badArgument) return error("invalid-argument", "argument has the wrong type")
      if (namedArgumentFailure !== "") {
        return error("invalid-argument", "unknown " + namedArgumentFailure)
      }
      if (namedTypedFailure) return error("unknown-command", "no such command")
      var hint = _usageHint(t, rest)
      if (hint) return _helpReply([target].concat(hint))
      return error("unknown-command", "no such command")
    }
    if (chosen.route === "clipboard-copy" || chosen.route === "log-read") {
      return error("unsupported", "this route is client-owned")
    }
    if (!registered(target)) return error("unavailable", "owner not registered")
    return _run(target, chosen, m.args, m.tokens, rest)
  }

  function describe(requestText) {
    if (typeof requestText !== "string"
        || Protocol.asciiBytes(requestText) > Protocol.MAX_REQUEST_BYTES) {
      return error("oversize", "request too large")
    }
    var request = Protocol.decode(requestText)
    if (!request) return error("invalid-argument", "invalid envelope")
    var validated = Protocol.validateRequest("describe", request)
    if (!validated.ok) return error(validated.error, "invalid request")
    if (validated.kind === "next") {
      var id = root._cursors[validated.cursor]
      var s = id ? root._snapshots[id] : null
      if (!s) return error("stale", "unknown or consumed cursor")
      var seq = Protocol.parseCursor(validated.cursor, root.incarnation)
      if (seq === null) return error("stale", "wrong instance")
      return _page(s, id, seq, validated.cursor)
    }
    if (validated.kind === "index") return _indexPage()
    return _helpPage(validated.path)
  }
}
