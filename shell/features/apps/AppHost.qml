pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/UnitIpc.js" as UnitIpc

// App host: the `app` IPC target, and the app table it dispatches from. One
// handle answers for every shell app, so `vb-shell app audioMixer` works and
// the next app costs a row in `apps` instead of a verb, a dispatch branch and a
// manifest line.
//
// Arity is what shapes the surface. Quickshell's IpcHandler enforces exact
// arity - a declared parameter is required and an extra argument is refused -
// so `vb-shell audio set` answers "Too few arguments provided (1 required but 0
// were provided.)" and `vb-shell audio set 10 20` answers "Too many arguments
// provided (1 required but 2 were provided.)". There is no optional parameter
// and no variadic, which is why the generic verb carries its arguments as a
// JSON array inside one always-present string: `call(name, verb, argsJson)` is
// arity 3 whatever arity the app's own verb has.
//
// Three names are one string: the offer below, the IpcHandler target and the
// boot catalog id are all `app`. Boot._audit compares the offered ids against
// the drained unit ids and logs "offered but never drained" for a mismatch, so
// an offer under any other name would be a permanent audit warning on a shell
// that works.
//
// The host imports no app module and names no app type. An app registers
// itself under its own id, and dispatch is `Registry.call(id, verb, ...args)`,
// so an app can never close an import cycle through this file and this file
// does not change when one is added.
Singleton {
  id: root

  readonly property string tag: "app"

  // --- the app table ---
  //
  // The host's claim about every app it can dispatch to: the id, a title, what
  // the app is for, and the verbs `list()` publishes. `status("")` answers the
  // table plus which of its apps are constructed.
  //
  // `verbs` is a publication of the app's own handler, not a gate: `call`
  // reaches anything the app declares, so a verb missing from a row is
  // invisible to a reader rather than unreachable.
  readonly property var apps: [
    {
      id: "audioMixer",
      title: "Audio mixer",
      description: "per-device and per-application volume with stream routing",
      verbs: ["open", "close", "toggle", "status"]
    },
    {
      id: "imageViewer",
      title: "Image viewer",
      description: "single-image browser with zoom, rotate and a folder picker",
      verbs: ["open", "openPath", "close", "toggle", "status"]
    }
  ]

  Component.onCompleted: {
    // The verb list is spelled out because it is a second copy of the handler
    // below: Boot's audit reads verbNames off every offer, and an offered verb
    // the handler does not declare is a row nothing can answer.
    Registry.offer("app", {
      title: "Apps",
      description: "shell apps behind one `app` handle",
      verbNames: [
        "audioMixer",
        "call",
        "close",
        "list",
        "open",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    Registry.register("app", root)
  }
  Component.onDestruction: Registry.unregister("app")

  // --- dispatch ---
  //
  // A dispatch lands three ways, and a caller can act on the difference. A name
  // no row claims is a typo; a row whose app is not registered in-process is a
  // facade that has not been used yet, which is a correct state rather than a
  // fault; a dispatched verb answers whatever the app returned. Collapsing the
  // first two into one refusal would tell a user whose app is fine that they
  // mistyped its name.
  function _dispatch(id, verb, args) {
    // Blank is not a typo, it is no name at all: `status("")` reads the host
    // itself and every other verb needs a row, so it is refused before the
    // table is consulted.
    if (id === "") return "error: no app given"
    if (root._row(id) === null) return "error: unknown app: " + id
    const answer = Registry.call(id, verb, ...args)
    // Registry answers null for two unrelated reasons: nothing registered that
    // id, and the registered object has no such callable member. Both read as
    // unavailable, because the host cannot see inside the registered object to
    // separate them - and a verb the app does not declare is a caller bug
    // either way.
    if (answer === null) return "error: app unavailable: " + id
    return root._text(answer)
  }

  // The table row an id names, or null when no row claims it.
  function _row(id) {
    const rows = root.apps
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].id === id) return rows[i]
    }
    return null
  }

  // An app name as a name: a missing or non-string argument is blank rather
  // than the string "undefined", and trimming keeps padding from turning a real
  // app into an unknown one.
  function _name(value) {
    return String(value === undefined || value === null ? "" : value).trim()
  }

  // A dispatched answer as a string. An app verb may answer its own text, a
  // boolean from a facade open/close, or a record from a list verb, and the
  // socket has one return shape.
  function _text(value) {
    if (typeof value === "string") return value
    if (value === null || value === undefined) return ""
    if (typeof value === "object") {
      try {
        return JSON.stringify(value)
      } catch (e) {
        return "error: unreadable reply"
      }
    }
    return String(value)
  }

  // The `argsJson` payload as an argument list, or null when it is not one.
  // It is caller text off the socket, so it is parsed rather than trusted: a
  // JSON array of strings or a bare JSON string is an argument list, blank text
  // is the empty list, and anything else is a refusal instead of an exception
  // the caller never sees.
  //
  // The bare string is not a convenience. `qs ipc call` JSON-decodes every
  // argument it is given, flattens an array into separate arguments and
  // re-serializes whatever scalar survives, so an array a caller wrote never
  // arrives as one string: a one-element array arrives as its quoted element,
  // and an array of two arrives as two arguments and is refused by the arity
  // check before this file sees it. Accepting the quoted string is what makes
  // `call` reach an app's arguments at all on the only transport it has.
  function _args(text) {
    const raw = String(text === undefined || text === null ? "" : text).trim()
    if (raw === "") return []
    let parsed
    try {
      parsed = JSON.parse(raw)
    } catch (e) {
      return null
    }
    // One argument. `""` is that argument, not the empty list - it is already
    // JSON text by the time it arrives, so nothing distinguishes it here from
    // any other single quoted string.
    if (typeof parsed === "string") return [parsed]
    if (!Array.isArray(parsed)) return null
    const args = []
    for (let i = 0; i < parsed.length; i++) {
      if (typeof parsed[i] !== "string") return null
      args.push(parsed[i])
    }
    return args
  }

  // The host's own payload: the table's ids, and which of them are constructed
  // right now. Liveness is read off the registry rather than tracked here,
  // because an app owns its own lifetime - a facade builds its controller on
  // demand and gives it back when idle, and the host sees only whether the
  // facade object is registered.
  function _hostStatus() {
    const ids = []
    const live = []
    const registered = Registry.registeredIds()
    for (let i = 0; i < root.apps.length; i++) {
      const id = root.apps[i].id
      ids.push(id)
      if (registered.indexOf(id) !== -1) live.push(id)
    }
    return JSON.stringify({ unit: root.tag, apps: ids, live: live })
  }

  // --- the `app` surface ---
  IpcHandler {
    target: "app"

    function help(command: string): string {
      return UnitIpc.help("app", "Apps", "shell apps behind one `app` handle", [
        { name: "audioMixer", help: "toggle the audio mixer" },
        { name: "call", help: "(name, verb, argsJson) dispatch to any app; argsJson a JSON string or array, blank for none" },
        { name: "close", help: "(name) close an app" },
        { name: "list", help: "the app table as JSON" },
        { name: "open", help: "(name) open an app" },
        { name: "toggle", help: "(name) open or close an app" },
      ], command)
    }
    function ping(): string { return "pong" }

    // The zero-arg shorthand, one per app that wants one: `vb-shell app
    // audioMixer` is this verb, and it dispatches exactly what
    // `call("audioMixer", "toggle", "")` dispatches.
    function audioMixer(): string {
      return root._dispatch("audioMixer", "toggle", [])
    }

    function list(): string {
      return JSON.stringify(root.apps)
    }

    // A blank name answers the host itself: `status("")` is the state of the
    // table, and a named app answers its own status.
    function status(name: string): string {
      const id = root._name(name)
      if (id === "") return root._hostStatus()
      return root._dispatch(id, "status", [])
    }

    function open(name: string): string {
      return root._dispatch(root._name(name), "open", [])
    }

    function close(name: string): string {
      return root._dispatch(root._name(name), "close", [])
    }

    function toggle(name: string): string {
      return root._dispatch(root._name(name), "toggle", [])
    }

    // The generic escape hatch, and the reason a further app needs no verb here:
    // arity 3 always, with the app's own arity carried in the JSON array.
    function call(name: string, verb: string, argsJson: string): string {
      const args = root._args(argsJson)
      if (args === null) return "error: argsJson must be a JSON string or an array of strings"
      const target = root._name(verb)
      if (target === "") return "error: no verb given"
      return root._dispatch(root._name(name), target, args)
    }
  }
}