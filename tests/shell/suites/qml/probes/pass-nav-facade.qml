// Probe: Pass navigation single-writer facade (LNC-7).
//
// PassPanel cannot be constructed offscreen (it needs the Pass singleton, a
// PanelWindow-backed card and a screen). This probe reads the two real sources
// and evaluates the FACADE VERBS extracted from Pass.qml in a headless
// QtObject. Only names that cross a component boundary are stubbed
// (root -> m, Model.navigationBack -> m.navBack with SU.dirname -> m.dirname,
// root.hidePanel -> m.hidePanel); the verb bodies themselves are the file's
// bytes, while navigationBack is restated locally (Qt refuses a third GET).
//
// Two contracts are pinned:
//   * mode/currentDir/selectedPath have exactly one writer, navigate(), and
//     the panel never writes them directly - every panel transition calls the
//     facade;
//   * a panel gesture cleanup (previously `Pass.mode = "browse"` straight from
//     PassPanel) and the equivalent Esc/back verb publish an identical state
//     trace from the same starting state, so no gesture can reach a state the
//     IPC path never sees.

import QtQuick

Item {
  id: root
  width: 1
  height: 1

  property string error: ""
  property string passSource: ""
  property string panelSource: ""
  property var navMachine: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // One whole `function name(...) { ... }`, with strings and line comments
  // skipped so a quote or a comment cannot close the block early.
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

  function bodies() {
    return {
      navigate: extract(root.passSource, "navigate"),
      showPanel: extract(root.passSource, "showPanel"),
      browseTo: extract(root.passSource, "browseTo"),
      select: extract(root.passSource, "select"),
      back: extract(root.passSource, "back")
    }
  }

  // Put the real verb bodies on a QtObject. Missing functions get inert
  // placeholders so the probe still runs and reports the source-level reds.
  function buildMachine(b) {
    let parts = ""
    for (const name of ["navigate", "browseTo", "select", "back"]) {
      let body = b[name]
      if (body === "") body = "function " + name + "() { return false }"
      parts += "\n" + body + "\n"
    }
    // Only cross-component names are rewritten; no control flow changes.
    parts = parts.replace(/\broot\./g, "m.")
      .replace(/\bModel\.navigationBack\(/g, "m.navBack(")

    // navigationBack is Model.js's pure step rule, restated here because Qt
    // refuses a third local GET in this probe. Only the action -> browse step
    // is exercised below; the full rule is out of LNC-7's scope.
    const navBack = [
      'function navBack(mode, dir) {',
      '  if (mode === "action" || mode === "create") return { mode: "browse" }',
      '  if (mode === "browse") {',
      '    const d = String(dir || "")',
      '    return d === "" ? { mode: "menu" } : { mode: "browse", dir: m.dirname(d) }',
      '  }',
      '  return { close: true }',
      '}'
    ].join("\n")

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: m',
      '  property string mode: "menu"',
      '  property string currentDir: ""',
      '  property string selectedPath: ""',
      '  property var trace: []',
      '  property int hides: 0',
      '  function record() { m.trace.push(m.mode + "|" + m.currentDir + "|" + m.selectedPath) }',
      '  onModeChanged: m.record()',
      '  onCurrentDirChanged: m.record()',
      '  onSelectedPathChanged: m.record()',
      '  function hidePanel() { m.hides++ }',
      '  function dirname(p) { const i = String(p || "").lastIndexOf("/"); return i < 0 ? "" : String(p).slice(0, i) }',
      navBack,
      parts,
      '}'
    ]
    const m = Qt.createQmlObject(lines.join("\n"), root, "pass_nav_facade_slice.qml")
    m.trace = []
    root.navMachine = m
    return m
  }

  // Reset state and observer, both off the record, without rebuilding.
  function reset(m) {
    m.mode = "menu"
    m.currentDir = ""
    m.selectedPath = ""
    m.hides = 0
    m.trace = []
  }

  function drive() {
    root.passSource = read("features/pass/Pass.qml")
    root.panelSource = read("features/pass/PassPanel.qml")
    const b = bodies()

    kv("slice.sourcesRead", root.passSource.length > 0 && root.panelSource.length > 0)
    kv("slice.facadeFnsFound", b.navigate.length > 0 && b.browseTo.length > 0
      && b.select.length > 0 && b.back.length > 0)

    // --- single writer: every field assignment lives inside navigate() ---
    const rest = root.passSource.replace(b.navigate, "")
      .replace(b.showPanel, "").replace(b.browseTo, "")
      .replace(b.select, "").replace(b.back, "")
    const outside = (rest.match(/\broot\.(mode|currentDir|selectedPath)\s*=[^=]/g) || []).length
    kv("facade.singleWriter", b.navigate.length > 0 && outside === 0
      && /\broot\.mode\s*=[^=]/.test(b.navigate)
      && /\broot\.currentDir\s*=[^=]/.test(b.navigate)
      && /\broot\.selectedPath\s*=[^=]/.test(b.navigate))

    // Every existing verb funnels through the one writer.
    kv("facade.verbsFunnel", /\broot\.navigate\(/.test(b.showPanel)
      && /\broot\.navigate\(/.test(b.browseTo)
      && /\broot\.navigate\(/.test(b.select)
      && /\broot\.navigate\(/.test(b.back))

    // No direct field write remains in the panel; its transitions call in.
    const panelWrites = (root.panelSource.match(/\bPass\.(mode|currentDir|selectedPath)\s*=[^=]/g) || []).length
    kv("facade.noPanelWrites", panelWrites === 0)
    kv("facade.panelUsesNavigate", (root.panelSource.match(/\bPass\.navigate\(/g) || []).length >= 2)

    const m = buildMachine(b)

    // Existing verbs keep their exact state effects.
    reset(m)
    m.browseTo("mail/gmail")
    kv("verb.browseState", m.mode + "|" + m.currentDir + "|" + m.selectedPath)
    m.select("mail/gmail/acc")
    kv("verb.selectState", m.mode + "|" + m.currentDir + "|" + m.selectedPath)

    // Gesture vs verb, from the same action state: the panel's entry-vanished
    // cleanup (`navigate({mode:"browse"})`) and the Esc verb `back()` must
    // publish the same sequence of field changes. Pre-fix the panel wrote
    // Pass.mode directly and this trace had no facade route at all.
    reset(m)
    m.mode = "action"
    m.currentDir = "mail/gmail"
    m.selectedPath = "mail/gmail/acc"
    m.trace = []
    m.back()
    const verbTrace = JSON.stringify(m.trace)
    kv("equivalence.verbTrace", verbTrace)
    kv("equivalence.verbEnd", m.mode + "|" + m.currentDir + "|" + m.selectedPath)

    reset(m)
    m.mode = "action"
    m.currentDir = "mail/gmail"
    m.selectedPath = "mail/gmail/acc"
    m.trace = []
    m.navigate({ mode: "browse" })
    const gestureTrace = JSON.stringify(m.trace)
    kv("equivalence.gestureTrace", gestureTrace)
    kv("equivalence.gestureEnd", m.mode + "|" + m.currentDir + "|" + m.selectedPath)

    kv("equivalence.traceEqual", verbTrace === gestureTrace && verbTrace.indexOf("browse|mail/gmail|mail/gmail/acc") >= 0)
  }

  Component.onCompleted: {
    try {
      drive()
    } catch (e) {
      root.error = String(e && e.message ? e.message : e)
    }
    kv("probe.error", root.error)
    console.log("##DONE##")
  }
}
