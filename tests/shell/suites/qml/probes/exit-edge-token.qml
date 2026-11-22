// Probe: notification fallback token and OSD exit edge (APP-3 / APP-6).
//
// Neither singleton can be constructed offscreen: Notifications owns a
// NotificationServer and a LazyLoader surface, and OSD is bound to a
// LayerSurface view. So the probe reads the three real source files and
// evaluates their OWN function/handler bodies in a headless QtObject with the
// backend-facing names stubbed (timers, reflow, icon host). Every machine
// below is the file's bytes, brace-balanced out of the source, with a single
// set of stubs; a rewrite the probe no longer understands is reported by the
// `missing` keys rather than silently passing.
//
// APP-3: one global fallback timer is armed on the first release. It must drop
// only the entry it was armed for, never the whole leaving set, and the live
// fade edge (noteExitDone) must clear and disarm it.
//
// APP-6: the OSD surface must be retained by the card's live opacity edge; the
// exit timer is only the ceiling for a delegate that never published one. The
// card's handler calls OSD._keepSurface(); the timer calls the same funnel.

import QtQuick

Item {
  id: root

  width: 1
  height: 1

  property string error: ""
  property string notifSource: ""
  property string osdSource: ""
  property string cardSource: ""
  property string notifMissing: ""
  property bool notifFireFound: false
  property var notifMachine: null
  property var notifMachine2: null
  property string osdMissing: ""
  property bool osdFireFound: false
  property bool osdKeepInstrumented: false
  property var osdMachine: null
  property var osdMachine2: null
  property var osdMachine3: null
  property var osdCard: null
  property bool cardHandlerFound: false

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      kv(key + ".threw", "" + (e && e.message ? e.message : e))
    }
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // extract() returns one whole `function name(...) { ... }` from the source.
  // Braces in strings and comments are skipped so a comment cannot close the
  // block early. Empty result means the file no longer has that function.
  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    let depth = 0
    let quote = ""
    let lineComment = false
    let blockComment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (lineComment) { if (ch === "\n") lineComment = false; continue }
      if (blockComment) {
        if (ch === "*" && src[j + 1] === "/") { blockComment = false; j++ }
        continue
      }
      if (quote) { if (ch === "\\") { j++; continue } if (ch === quote) quote = ""; continue }
      if (ch === "/" && src[j + 1] === "/") { lineComment = true; j++; continue }
      if (ch === "/" && src[j + 1] === "*") { blockComment = true; j++; continue }
      if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) return src.slice(m.index, j + 1)
      }
    }
    return ""
  }

  // handlerAfter() returns the body of `name:` found after `anchor`. It
  // handles both a brace block and a single expression, which is why both
  // forms of onTriggered in the tree are readable here.
  function handlerAfter(src, anchor, name) {
    const a = src.indexOf(anchor)
    if (a < 0) return ""
    const re = new RegExp("\\b" + name + "\\s*:", "g")
    re.lastIndex = a
    const m = re.exec(src)
    if (!m) return ""
    let i = m.index + m[0].length
    while (i < src.length && /\s/.test(src[i])) i++
    if (src[i] === "{") {
      let depth = 0
      let quote = ""
      let lineComment = false
      let blockComment = false
      for (let j = i; j < src.length; j++) {
        const ch = src[j]
        if (lineComment) { if (ch === "\n") lineComment = false; continue }
        if (blockComment) {
          if (ch === "*" && src[j + 1] === "/") { blockComment = false; j++ }
          continue
        }
        if (quote) { if (ch === "\\") { j++; continue } if (ch === quote) quote = ""; continue }
        if (ch === "/" && src[j + 1] === "/") { lineComment = true; j++; continue }
        if (ch === "/" && src[j + 1] === "*") { blockComment = true; j++; continue }
        if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
        if (ch === "{") depth++
        else if (ch === "}") {
          depth--
          if (depth === 0) return src.slice(i, j + 1)
        }
      }
      return ""
    }
    let j = i
    while (j < src.length && src[j] !== "\n" && src[j] !== "\r") j++
    return src.slice(i, j).trim()
  }

  // The notification machine: real _release / noteExitDone / _dropLeaving and
  // the real exitFallback.onTriggered body, with the two controller helpers
  // and the timer stubbed by counters.
  function buildNotifMachine() {
    const names = ["_release", "noteExitDone", "_dropLeaving"]
    const missing = []
    let bodies = ""
    for (let i = 0; i < names.length; i++) {
      const fn = extract(root.notifSource, names[i])
      if (fn === "") missing.push(names[i])
      else bodies += "\n" + fn + "\n"
    }
    root.notifMissing = missing.join(",")
    const fire = handlerAfter(root.notifSource, "id: exitFallback", "onTriggered")
    root.notifFireFound = fire !== ""
    const lines = [
      'import QtQml',
      'import QtQuick',
      'QtObject {',
      '  id: root',
      '  property var _tracked: []',
      '  property var _fallbackEntry: null',
      '  property int reflowCalls: 0',
      '  property int armCalls: 0',
      '  property int restartCalls: 0',
      '  property int stopCalls: 0',
      '  property int fireCalls: 0',
      '  property QtObject exitFallback: QtObject {',
      '    property bool running: false',
      '    function restart() { running = true; root.restartCalls++ }',
      '    function stop() { running = false; root.stopCalls++ }',
      '    function fire() { root.fireCalls++; ' + fire + ' }',
      '  }',
      '  function _reflowSlots() { root.reflowCalls++ }',
      '  function _armDeadline() { root.armCalls++ }',
      bodies,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "notif_machine_slice.qml")
  }

  // The OSD machine: real hide() and _keepSurface(), with the exitTimer's
  // onTriggered body as a callable fallback and the three timers stubbed.
  function buildOsdMachine() {
    const names = ["hide", "_keepSurface"]
    const missing = []
    let bodies = ""
    for (let i = 0; i < names.length; i++) {
      let fn = extract(root.osdSource, names[i])
      if (fn === "") {
        missing.push(names[i])
        continue
      }
      // Instrument the one funnel with a call counter: the body is the
      // file's own bytes plus this single probe-side statement.
      if (names[i] === "_keepSurface") {
        const head = "function _keepSurface() {"
        if (fn.indexOf(head) >= 0) {
          fn = fn.replace(head, head + " root.keepCalls++; ")
          root.osdKeepInstrumented = true
        }
      }
      bodies += "\n" + fn + "\n"
    }
    root.osdMissing = missing.join(",")
    const fire = handlerAfter(root.osdSource, "id: exitTimer", "onTriggered")
    root.osdFireFound = fire !== ""
    const lines = [
      'import QtQml',
      'import QtQuick',
      'QtObject {',
      '  id: root',
      '  property bool visible: false',
      '  property bool dismissing: false',
      '  property bool _lingering: false',
      '  property bool desktopSuppressed: false',
      '  property bool animationsEnabled: true',
      '  property int keepCalls: 0',
      '  property int hideStops: 0',
      '  property int exitRestarts: 0',
      '  property int exitStops: 0',
      '  property int lingerRestarts: 0',
      '  property QtObject hideTimer: QtObject {',
      '    property bool running: false',
      '    function stop() { running = false; root.hideStops++ }',
      '    function restart() { running = true }',
      '  }',
      '  property QtObject exitTimer: QtObject {',
      '    property bool running: false',
      '    function restart() { running = true; root.exitRestarts++ }',
      '    function stop() { running = false; root.exitStops++ }',
      '    function fire() { ' + fire + ' }',
      '  }',
      '  property QtObject lingerTimer: QtObject {',
      '    function restart() { root.lingerRestarts++ }',
      '  }',
      bodies,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "osd_machine_slice.qml")
  }

  // The card stub: real onOpacityChanged body from OSDCard, with `root` being
  // the card and `OSD` pointing at the machine above.
  function buildCard(machine) {
    const handler = handlerAfter(root.cardSource, "", "onOpacityChanged")
    root.cardHandlerFound = handler !== ""
    // QML property names cannot start upper case, so the singleton alias the
    // real handler reads is rewritten from OSD to osd in this one stub.
    const injected = handler.replace(/\bOSD\./g, "osd.")
    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: root',
      '  property real opacity: 1',
      '  property var osd: null',
      '  function noteOpacity() { ' + injected + ' }',
      '}'
    ]
    const c = Qt.createQmlObject(lines.join("\n"), root, "osd_card_slice.qml")
    c.osd = machine
    return c
  }

  function drive() {
    root.error = ""
    try {
      root.notifSource = read("features/notifications/Notifications.qml")
      root.osdSource = read("features/osd/OSD.qml")
      root.cardSource = read("features/osd/OSDCard.qml")
      kv("slice.notifSource", root.notifSource.length > 0)
      kv("slice.osdSource", root.osdSource.length > 0)
      kv("slice.cardSource", root.cardSource.length > 0)

      // ---------------- APP-3 ----------------
      const nm = buildNotifMachine()
      root.notifMachine = nm
      kv("notif.missing", root.notifMissing)
      kv("notif.fireFound", root.notifFireFound)
      const a = { notifId: 1, leaving: false, alive: false }
      const b = { notifId: 2, leaving: false, alive: false }
      nm._tracked = [a, b]

      nm._release(a)
      kv("notif.release.setsFallbackToA", nm._fallbackEntry === a)
      kv("notif.release.armedTimer", nm.exitFallback.running === true && nm.restartCalls === 1)
      nm._release(b)
      kv("notif.release.keepsFallbackA", nm._fallbackEntry === a)
      kv("notif.release.noRearm", nm.restartCalls === 1)

      // The fallback fires while both cards are still leaving: only the
      // armed one may go, the late-arriving b must keep its fade.
      nm.exitFallback.fire()
      kv("notif.fire.droppedA", nm._tracked.indexOf(a) < 0)
      kv("notif.fire.keptB", nm._tracked.indexOf(b) >= 0)
      kv("notif.fire.count", nm._tracked.length)

      // Fresh machine: the live fade edge drops its own entry and disarms
      // the ceiling when it is the armed one.
      const nm2 = buildNotifMachine()
      root.notifMachine2 = nm2
      const c = { notifId: 3, leaving: false, alive: false }
      const d = { notifId: 4, leaving: false, alive: false }
      nm2._tracked = [c, d]
      nm2._release(c)
      nm2._release(d)
      kv("notif.edge.armedC", nm2._fallbackEntry === c)
      nm2.noteExitDone(c)
      kv("notif.edge.droppedC", nm2._tracked.indexOf(c) < 0)
      kv("notif.edge.keptD", nm2._tracked.indexOf(d) >= 0)
      kv("notif.edge.clearedFallback", nm2._fallbackEntry === null || nm2._fallbackEntry === undefined)
      kv("notif.edge.stoppedTimer", nm2.exitFallback.running === false && nm2.stopCalls === 1)
      // A late fallback must now be a no-op, not a sweep of d.
      nm2.exitFallback.fire()
      kv("notif.edge.lateFireKeptD", nm2._tracked.indexOf(d) >= 0)

      // ---------------- APP-6 ----------------
      const om = buildOsdMachine()
      root.osdMachine = om
      kv("osd.missing", root.osdMissing)
      kv("osd.fireFound", root.osdFireFound)
      kv("osd.keepInstrumented", root.osdKeepInstrumented)
      const card = buildCard(om)
      root.osdCard = card
      kv("osd.cardHandlerFound", root.cardHandlerFound)

      // A live payload hides: the fade starts and the ceiling is armed, but
      // the surface is still held by `dismissing` while the card fades.
      om.visible = true
      om.dismissing = false
      om.hide()
      kv("osd.hide.armedCeiling", om.exitTimer.running === true && om.exitRestarts === 1)
      kv("osd.hide.dismissing", om.dismissing === true)
      kv("osd.hide.notLingeringYet", om._lingering === false)

      // The card's live opacity crosses the visible end. Retention must
      // follow this edge, with no timer fired.
      card.opacity = 0.01
      card.noteOpacity()
      kv("osd.edge.keepCalled", om.keepCalls === 1)
      kv("osd.edge.dismissingCleared", om.dismissing === false)
      kv("osd.edge.lingering", om._lingering === true)
      kv("osd.edge.lingerRestarted", om.lingerRestarts === 1)
      kv("osd.edge.ceilingDisarmed", om.exitStops === 1 && om.exitTimer.running === false)
      kv("osd.edge.noTimerFired", om.keepCalls === 1)

      // The ceiling still works on its own for a card that never published.
      const om2 = buildOsdMachine()
      root.osdMachine2 = om2
      om2.visible = true
      om2.hide()
      om2.exitTimer.fire()
      kv("osd.ceiling.keepCalled", om2.keepCalls === 1)
      kv("osd.ceiling.dismissingCleared", om2.dismissing === false)
      kv("osd.ceiling.lingering", om2._lingering === true)

      // A suppressed (locked) desktop never lingers, even through the funnel.
      const om3 = buildOsdMachine()
      root.osdMachine3 = om3
      om3.desktopSuppressed = true
      om3.visible = true
      om3.hide()
      card.osd = om3
      card.opacity = 0.01
      card.noteOpacity()
      kv("osd.suppressed.noLinger", om3._lingering === false)

      kv("probe.error", root.error)
    } catch (e) {
      root.error = "" + (e && e.message ? e.message : e)
      kv("probe.error", root.error)
    }
    console.log("##DONE##")
  }

  Component.onCompleted: drive()
}
