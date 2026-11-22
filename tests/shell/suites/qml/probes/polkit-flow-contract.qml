// Probe: the polkit conversation's action path and its two reset tokens.
//
// Polkit.qml cannot be imported here: its PolkitAgent registers a second
// authentication agent on the user's session, and PolkitView is a Variants of
// PanelWindow, which has no backend under offscreen. So the probe reads the two
// real source files and evaluates their OWN function bodies in a headless
// shell: every function under test below is the file's bytes, brace-balanced
// out of the source. Only the backend-facing names are stubbed (agent, Svc,
// closeTimer, wireFlow) and the slice reports the one rewrite it makes so a
// source change it no longer understands fails loudly.
//
// The contract under test:
//   * an action uses the flow the observers are wired to, not agent.flow, and
//     a verdict from _apply() that refuses the event forbids the backend call;
//   * beginClose is not a second writer of conv;
//   * the failure flash is owned by a token that only beginRequest bumps,
//     while resetToken keeps owning the text wipe and the refocus.
//
// Driving the pure machine alone would not fail on any of these: PolkitTrace
// refuses a stale submit today. The bug is what the caller does with that
// refusal, which is why the caller's own functions are evaluated.

import QtQuick
import "features/polkit/PolkitTrace.js" as PolkitTrace

Item {
  id: root

  width: 1
  height: 1

  property string error: ""
  property string source: ""
  property string viewSource: ""
  property string missingFns: ""
  property string rewrites: ""
  property int svcSyncs: 0
  property int timerStops: 0
  property int viewClear: 0
  property int viewClearFailure: 0
  property int viewRefocuses: 0
  property var machine: null
  property var machine2: null
  property var machine3: null
  property var view: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // extract() returns one whole `function name(...) { ... }` from the source.
  // Braces in strings and // comments are skipped so a comment cannot close
  // the block early. An empty result means the file no longer has that
  // function, which the driver reads as a contract that moved.
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

  // A flow is the narrow shape the real functions read off the backend, plus
  // two logs that make a backend call observable without a PAM session.
  function flow(name, required) {
    return {
      tag: name,
      message: "msg-" + name,
      inputPrompt: "Password: ",
      supplementaryMessage: "",
      supplementaryIsError: false,
      isResponseRequired: required,
      responseVisible: false,
      actionId: "org.example." + name,
      identities: ["alice"],
      submits: [],
      cancels: [],
      submit: function (text) { this.submits.push(text) },
      cancelAuthenticationRequest: function () { this.cancels.push("cancel") }
    }
  }

  // buildMachine() puts the real functions on a QtObject with stubbed edges.
  // The one rewrite is Svc -> root.svc: QML property names must start lower
  // case, and the stub is otherwise written as the alias was.
  function buildMachine() {
    const names = ["_apply", "isCurrentFlow", "submitPassword", "cancelRequest",
      "beginClose", "beginRequest", "syncFromFlow", "clearMirroredState",
      "_actionId", "_identityCount"]
    const missing = []
    let bodies = ""
    for (let i = 0; i < names.length; i++) {
      const fn = extract(root.source, names[i])
      if (fn === "") missing.push(names[i])
      else bodies += "\n" + fn + "\n"
    }
    root.missingFns = missing.join(",")
    const beginName = "beginRequest"
    const beginRaw = extract(root.source, beginName)
    root.rewrites = beginRaw.indexOf("Svc.Keyboard.sync()") >= 0 ? "svc-alias" : "none"
    bodies = bodies.replace(/\bSvc\./g, "root.svc.")

    const lines = [
      'import QtQml',
      'import QtQuick',
      'import "features/polkit/PolkitTrace.js" as PolkitTrace',
      'QtObject {',
      '  id: root',
      '  property var agent: null',
      '  property var svc: null',
      '  property var closeTimer: null',
      '  property var conv: PolkitTrace.newConversation()',
      '  property string message: ""',
      '  property string prompt: ""',
      '  property string supplementary: ""',
      '  property bool supplementaryIsError: false',
      '  property bool responseRequired: false',
      '  property bool responseVisible: false',
      '  property bool active: false',
      '  property bool closing: false',
      '  property int inFlight: 0',
      '  property int flowEpoch: 0',
      '  property int resetToken: 0',
      '  property int conversationToken: 0',
      '  property var wiredFlow: null',
      '  readonly property bool checking: root.conv.checking',
      '  function wireFlow(f) { root.wiredFlow = f }',
      bodies,
      '}'
    ]
    const m = Qt.createQmlObject(lines.join("\n"), root, "polkit_machine_slice.qml")
    m.agent = { flow: null }
    m.svc = { Keyboard: { sync: function () { root.svcSyncs++ } } }
    m.closeTimer = { stop: function () { root.timerStops++ } }
    return m
  }

  // buildView() evaluates the two Connections handlers from PolkitView with
  // a counting authBox, so "which token clears the flash" is a call count and
  // not a grep. The missing handler prints as absent on the tree that still
  // clears the flash from onVisibleChanged.
  function buildView() {
    const reset = extract(root.viewSource, "onResetTokenChanged")
    const conversation = extract(root.viewSource, "onConversationTokenChanged")
    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: root',
      '  property var authBox: null',
      '  property var win: null',
      '  property int refocusCount: 0',
      reset,
      conversation,
      '}'
    ]
    const v = Qt.createQmlObject(lines.join("\n"), root, "polkit_view_slice.qml")
    v.authBox = {
      clear: function () { root.viewClear++ },
      clearFailure: function () { root.viewClearFailure++ }
    }
    v.win = { refocus: function () { root.viewRefocuses++ } }
    return v
  }

  function drive() {
    root.source = read("features/polkit/Polkit.qml")
    root.viewSource = read("features/polkit/PolkitView.qml")
    kv("slice.sourceStatus", root.source.length > 0)
    kv("slice.viewSourceStatus", root.viewSource.length > 0)

    const m = buildMachine()
    root.machine = m
    kv("slice.missingFns", root.missingFns)
    kv("slice.rewrites", root.rewrites)

    const wired = flow("wired", true)
    const foreign = flow("foreign", true)
    const stale = flow("stale", true)

    // A real request, then the flow pointer moving on behind the card. The
    // observers still own `wired`; agent.flow is the backend's new object.
    m.agent.flow = wired
    m.beginRequest()
    m._apply("prompt")
    m.agent.flow = foreign
    m.submitPassword("secret")
    kv("submit.onWired", wired.submits.length)
    kv("submit.onForeign", foreign.submits.length)

    // A rejected turn leaves active=true, checking=false, waiting=false: the
    // old guard passes, but _apply("submit") refuses. No backend call may
    // follow a refusal.
    m._apply("rejected")
    m.submitPassword("again")
    kv("submit.afterRefusedApply", wired.submits.length + foreign.submits.length - 1)
    kv("submit.convSubmits", m.conv.submits)

    // No wired flow at all: an agent.flow pointer is not a seat to act on.
    m._apply("prompt")
    m.wiredFlow = null
    m.submitPassword("orphan")
    kv("submit.withoutWiredTotal", wired.submits.length + foreign.submits.length - 1)
    kv("submit.withoutWiredForeign", foreign.submits.length)

    // Cancel follows the same identity rule.
    m.wiredFlow = wired
    m.agent.flow = stale
    m._apply("prompt")
    m.cancelRequest()
    kv("cancel.onWired", wired.cancels.length)
    kv("cancel.onForeign", stale.cancels.length)

    // A retired (flow, epoch) pair is refused by the shared guard.
    kv("guard.stale", m.isCurrentFlow(wired, 0))

    // beginClose on a conversation the machine cannot close: the old direct
    // assignment wrote null into conv; the funnel leaves the record intact.
    const m2 = buildMachine()
    root.machine2 = m2
    m2.active = true
    m2.beginClose()
    kv("beginClose.refusedConvNull", m2.conv === null)
    kv("beginClose.refusedClosing", m2.closing)

    // The same verb on a live conversation still closes.
    const m3 = buildMachine()
    root.machine3 = m3
    m3.agent.flow = flow("live", true)
    m3.beginRequest()
    m3.beginClose()
    kv("beginClose.acceptedClosing", m3.closing)

    // Failure feedback must not own the conversation token: a rejection bumps
    // resetToken only, a new request bumps both.
    m._apply("rejected")
    m.resetToken++
    kv("token.afterFailure", m.conversationToken)
    m.agent.flow = flow("next", true)
    m.beginRequest()
    kv("token.afterNewRequest", m.conversationToken)

    // The view's two handlers keep their separate jobs.
    const v = buildView()
    root.view = v
    kv("token.viewHandler", typeof v.onConversationTokenChanged === "function")
    v.onResetTokenChanged()
    kv("token.viewResetWipes", root.viewClear)
    kv("token.viewResetClears", root.viewClearFailure)
    if (typeof v.onConversationTokenChanged === "function") {
      v.onConversationTokenChanged()
    }
    kv("token.viewConversationClears", root.viewClearFailure)
    kv("token.viewRefocuses", root.viewRefocuses)
    const matches = root.viewSource.match(/authBox\.clearFailure\(\)/g) || []
    kv("view.clearFailureCalls", matches.length)

    // LCK-7: shouldShow is the cause, not the owner of the exit fade. The view
    // deliberately omits `closing`, and passing it hid the window on the first
    // closing frame. suppression() still reports it for diagnostics.
    kv("show.closingIgnored", PolkitTrace.shouldShow({
      requested: true, locked: false, screens: 1, primary: true, closing: true
    }))
    kv("show.locked", PolkitTrace.shouldShow({
      requested: true, locked: true, screens: 1, primary: true, closing: true
    }))
    kv("show.noScreen", PolkitTrace.shouldShow({
      requested: true, locked: false, screens: 0, primary: true
    }))
    kv("suppression.closing", PolkitTrace.suppression({
      requested: true, locked: false, screens: 1, primary: true, closing: true
    }))
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
