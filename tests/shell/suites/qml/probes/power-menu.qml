// Probe: power-menu reset/dispatch epochs and the query's single source.
//
// PowerMenu.qml is a pragma Singleton and owns a live OverlayWindow through
// PowerMenuView, and Session.dispatch / Session.requestDestructive can end a
// real session. Neither can be driven here. So the probe reads the real source
// (handed in by the suite) and evaluates its OWN function bodies in a headless
// QtObject. Only the backend-facing names are stubbed (Session, Bus,
// SurfaceClaim, MenuLib); every function under test is the file's bytes,
// brace-balanced out of the source. The onVisibleChanged handler is extracted
// the same way, so removing the deferred reset from the source removes it from
// the machine too.
//
// The contract under test:
//   OVL-7  reset() lands in close(), not on a later turn where a close->open
//          in one turn lets the old reset wipe the new session's query.
//   OVL-8  a dispatch carries the generation of the intent that armed it.
//          A newer open/activate retires an earlier queued dispatch, but the
//          close() that belongs to the same activation must NOT bump it.
//   OVL-9  InputField.value is the one guarded bridge from an owning source
//          into the control; edited() is the way the control writes back,
//          and a source write never emits edited(). PowerMenuPanel holds no
//          imperative copy of the query into searchField.text.
//
// The event loop is pumped by a Timer: Qt.callLater callbacks posted in one
// turn are drained before the next tick, exactly as in the shell.

import QtQuick
import Quickshell
import qs.common

Item {
  id: probe

  width: 1
  height: 1

  property string error: ""
  property string pmSrc: Quickshell.env("POWERMENU_SRC") || ""
  property string panelSrc: Quickshell.env("PANEL_SRC") || ""
  property string inputSrc: Quickshell.env("INPUTFIELD_SRC") || ""

  property int turn: 0
  property bool done: false

  property var actions: [
    { id: "alpha", label: "Alpha", action: "alpha" },
    { id: "beta", label: "Beta", action: "beta" },
    { id: "poweroff", label: "Power off", action: "poweroff" }
  ]

  property var m1: null
  property var m2: null
  property var m3: null
  property var m4: null
  property var m5: null
  property var m6: null

  // The bridge under test, instantiated for real. `value` does not exist on
  // the pre-fix control, so the probe binds it defensively in drive().
  property string sourceText: ""
  property int edits: 0
  property string bridgeError: ""
  InputField {
    id: bridgeField
    width: 120
    height: 32
  }

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  // extract() returns one whole `function name(...) { ... }` from the source.
  // Braces in strings and // comments are skipped so neither can close the
  // block early. Empty means the file no longer has that function.
  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    let start = m.index
    while (start > 0 && (src[start - 1] === " " || src[start - 1] === "\t")) start--
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    let depth = 0
    let quote = ""
    let comment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (comment) {
        if (ch === "\n") comment = false
        continue
      }
      if (quote) {
        if (ch === "\\") { j++; continue }
        if (ch === quote) quote = ""
        continue
      }
      if (ch === "/" && src[j + 1] === "/") { comment = true; j++; continue }
      if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) return src.slice(start, j + 1)
      }
    }
    return ""
  }

  // The visible edge is a handler, not a function. Extract it the same way so
  // the fix (which deletes it) removes it from the machine rather than leaving
  // a hand-written copy that keeps failing after the source is corrected.
  function extractHandler(src, name) {
    const re = new RegExp("^[ \\t]*" + name + "\\s*:", "m")
    const m = re.exec(src)
    if (!m) return ""
    let start = m.index
    while (start > 0 && (src[start - 1] === " " || src[start - 1] === "\t")) start--
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) {
      const end = src.indexOf("\n", m.index)
      return src.slice(start, end < 0 ? src.length : end)
    }
    let depth = 0
    let quote = ""
    let comment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (comment) {
        if (ch === "\n") comment = false
        continue
      }
      if (quote) {
        if (ch === "\\") { j++; continue }
        if (ch === quote) quote = ""
        continue
      }
      if (ch === "/" && src[j + 1] === "/") { comment = true; j++; continue }
      if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) return src.slice(start, j + 1)
      }
    }
    return ""
  }

  property var fnNames: ["open", "close", "reset", "submit", "clearQuery",
    "activate", "isDestructive", "_armConfirmation", "_clearConfirmation",
    "confirmPending", "_dispatchConfirmed", "_recordDispatchFault",
    "_execute", "_recompute", "_publishState"]

  function makeMachine() {
    let bodies = ""
    const missing = []
    for (let i = 0; i < probe.fnNames.length; i++) {
      let fn = extract(probe.pmSrc, probe.fnNames[i])
      if (fn === "") missing.push(probe.fnNames[i])
      fn = fn.replace(/\bSession\./g, "root.session.")
        .replace(/\bBus\./g, "root.bus.")
        .replace(/\bSurfaceClaim\./g, "root.claim.")
        .replace(/\bMenuLib\./g, "root.menuLib.")
      bodies += "\n" + fn + "\n"
    }
    kv("slice.missing", missing.join(","))

    const lines = [
      "import QtQml",
      "import QtQuick",
      "QtObject {",
      "  id: root",
      "  property bool visible: false",
      "  property string query: \"\"",
      "  property var results: []",
      "  property int matchedCount: 0",
      "  property int totalCount: 0",
      "  property var _actions: []",
      "  property var _claimToken: null",
      "  property var destructiveActions: [\"poweroff\", \"reboot\", \"uefi-reboot\", \"logout\"]",
      "  property string _confirmationAction: \"\"",
      "  property string _confirmationLabel: \"\"",
      "  property string _dispatchFault: \"\"",
      "  property int _dispatchGen: 0",
      "  property var bus: null",
      "  property var session: null",
      "  property var claim: null",
      "  property var menuLib: null",
      bodies,
      extractHandler(probe.pmSrc, "onVisibleChanged"),
      "}"
    ]
    const m = Qt.createQmlObject(lines.join("\n"), probe, "power_menu_slice.qml")
    m.bus = { publish: function () { } }
    m.session = {
      calls: [],
      destructive: [],
      dispatch: function (a) { this.calls.push(a); return a !== "bad" },
      requestDestructive: function (a) { this.destructive.push(a); return "ok" }
    }
    m.claim = {
      claim: function () { return "tok" },
      release: function () { },
      releaseOwner: function () { }
    }
    m.menuLib = {
      filterCounter: function (actions, query) {
        const q = String(query || "").toLowerCase()
        const rows = (Array.isArray(actions) ? actions : []).filter(function (a) {
          return String((a && a.label) || "").toLowerCase().indexOf(q) >= 0
        })
        return { rows: rows, matched: rows.length, total: (actions || []).length }
      }
    }
    m._actions = probe.actions
    return m
  }

  function drive() {
    // --- OVL-7: a close->open in one turn must not let the old reset wipe
    // the new session's query.
    probe.m1 = makeMachine()
    probe.m1.open()
    probe.m1.submit("first")
    probe.m1.close()
    kv("reset.inCloseTurn", probe.m1.query === "")
    probe.m1.open()
    probe.m1.submit("second")
    kv("reset.beforeDrain", probe.m1.query === "second")

    // --- OVL-8: two open+activate pairs before the drain.
    probe.m2 = makeMachine()
    probe.m2.open()
    probe.m2.activate(probe.actions[0])
    probe.m2.open()
    probe.m2.activate(probe.actions[1])

    // --- OVL-8: one honest activation must not be cancelled by its own
    // dismiss close().
    probe.m3 = makeMachine()
    probe.m3.open()
    probe.m3.activate(probe.actions[0])

    // --- OVL-8: the confirm path publishes its verdict after dismissal.
    probe.m4 = makeMachine()
    probe.m4.open()
    probe.m4.activate(probe.actions[2])
    probe.m4.confirmPending()

    // --- OVL-8: a new intent retires a queued confirmation too.
    probe.m5 = makeMachine()
    probe.m5.open()
    probe.m5.activate(probe.actions[2])
    probe.m5.confirmPending()
    probe.m5.open()

    // --- OVL-8: _execute keeps its destructive-family gate.
    probe.m6 = makeMachine()
    probe.m6._execute(probe.actions[2], probe.m6._dispatchGen)

    // --- OVL-9: the guarded value bridge on a real InputField.
    kv("bridge.hasValue", "value" in bridgeField)
    let bound = false
    try {
      bridgeField.value = Qt.binding(function () { return probe.sourceText })
      bound = true
    } catch (e) {
      probe.bridgeError = String(e && e.message ? e.message : e)
    }
    kv("bridge.bindAccepted", bound)
    bridgeField.edited.connect(function (t) { probe.sourceText = t; probe.edits++ })
    probe.sourceText = "hello"
    kv("bridge.sourceToField", bridgeField.text === "hello")
    kv("bridge.noEditOnSourceWrite", probe.edits === 0)
    bridgeField.type("world")
    kv("bridge.editWritesSource", probe.sourceText === "world")
    kv("bridge.editCount", probe.edits)

    kv("drive.error", probe.error)
  }

  function observeDrained() {
    kv("reset.afterDrain", probe.m1.query === "second")
    kv("dispatch.stale", probe.m2.session.calls.join(","))
    kv("dispatch.single", probe.m3.session.calls.join(","))
    kv("confirm.single", probe.m4.session.destructive.join(","))
    kv("confirm.stale", probe.m5.session.destructive.join(","))
    kv("gate.fault", probe.m6._dispatchFault)
    kv("gate.noDispatch", probe.m6.session.calls.length === 0)
  }

  function structural() {
    const pm = probe.pmSrc
    const panel = probe.panelSrc
    const input = probe.inputSrc
    kv("source.loaded", pm.length > 0 && panel.length > 0 && input.length > 0)
    // The five imperative resyncs are gone: the source owns the query and the
    // field follows it through value.
    const writes = panel.match(/searchField\.text\s*=/g) || []
    kv("panel.fieldWrites", writes.length)
    kv("panel.valueBinding", /value\s*:\s*PowerMenu\.query/.test(panel))
    // One guarded bridge in InputField: value writes input.text, edited() is
    // the user-edit path, and nothing else writes the source on a value set.
    kv("input.valueProperty", /property\s+string\s+value/.test(input))
    kv("input.valueHandler", /onValueChanged\s*:/.test(input))
    const vh = input.indexOf("onValueChanged:")
    const seg = vh < 0 ? "" : input.slice(vh, vh + 320)
    kv("input.guardedWrite", /input\.text\s*=\s*value/.test(seg)
      && /input\.text\s*===\s*value/.test(seg))
    kv("input.noEditedInBridge", !/edited\(/.test(seg))
  }

  Timer {
    interval: 40
    repeat: true
    running: !probe.done
    onTriggered: {
      probe.turn++
      const t = probe.turn
      if (t === 3) {
        try {
          probe.drive()
        } catch (e) {
          probe.error = String(e && e.message ? e.message : e)
          kv("drive.error", probe.error)
        }
      } else if (t === 4) {
        observeDrained()
      } else if (t === 5) {
        structural()
        console.log("##DONE##")
        probe.done = true
      }
    }
  }
}
