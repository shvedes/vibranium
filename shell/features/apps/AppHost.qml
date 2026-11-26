pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../common/text/IpcCatalog.js" as Catalog

// App host: the `app` gateway and the host's declared two-app registry. The
// shell's public surface is the catalog, not an arbitrary member of a
// registered object: the old `call(name, verb, argsJson)` escape hatch and the
// native `app audioMixer` shorthand are gone. Every operation below is a
// constant closure over one of the two ids in `apps`, and no argv text ever
// reaches Registry.call as a method name.
Singleton {
  id: root

  readonly property string tag: "app"

  // The host's claim about every app it can dispatch to. Ids are
  // case-sensitive. `verbs` is the public allowlist published by
  // `app call list` and used by dispatch below; it is not an invitation to
  // call any other member of a facade.
  readonly property var apps: [
    {
      id: "audioMixer",
      title: "Audio mixer",
      description: "per-device and per-application volume with stream routing",
      helpSummary: "Audio mixer: native Pavucontrol replacement, with Pipewire node graph included",
      verbs: ["openTab", "selectTab", "status"]
    },
    {
      id: "imageViewer",
      title: "Image viewer",
      description: "single-image browser with zoom, rotate and a folder picker",
      helpSummary: "A simple, Vibranium-native image viewer",
      verbs: ["openPath", "status"]
    }
  ]

  // The fixed per-app allowlist. One table drives dispatch AND the help page
  // returned by `app call list <ID>`, so a verb that is discoverable is
  // exactly a verb that can be invoked. Every argument states its accepted
  // values and every verb carries a concrete, copyable example.
  readonly property var _callSpec: ({
    audioMixer: {
      openTab: {
        usage: "openTab <TAB>", description: "Open audioMixer with <TAB> focused",
        arguments: [{ name: "TAB", type: "enum",
          values: ["apps", "devices", "recording", "configuration", "graph"],
          summary: "One tab id: apps, devices, recording, configuration or graph" }],
        examples: ["vb-shell app call audioMixer openTab configuration"]
      },
      selectTab: {
        usage: "selectTab <TAB>", description: "Select a <TAB> in existing window",
        arguments: [{ name: "TAB", type: "enum",
          values: ["apps", "devices", "recording", "configuration", "graph"],
          summary: "One tab id: apps, devices, recording, configuration or graph" }],
        examples: ["vb-shell app call audioMixer selectTab devices"]
      },
      status: { usage: "status", description: "audioMixer status", literalSummary: true,
        arguments: [], examples: ["vb-shell app call audioMixer status"] }
    },
    imageViewer: {
      openPath: {
        usage: "openPath <PATH>", description: "Open an image in <PATH>",
        arguments: [{ name: "PATH", type: "ref", summary:
          "One absolute path or `file:` URL, passed as a single argv word" }],
        examples: ["vb-shell app call imageViewer openPath /home/user/Pictures/my-image.png"]
      },
      status: { usage: "status", description: "ImageViewer status",
        arguments: [], examples: ["vb-shell app call imageViewer status"] }
    }
  })

  // Notes and page-level examples are static prose: describing an app never
  // demands a controller, loads a plugin or opens a window.
  readonly property var _callHelpProse: ({
    audioMixer: {
      notes: ["Valid tab ids are: apps, devices, recording, configuration, graph"],
      examples: ["vb-shell app call audioMixer openTab configuration",
        "vb-shell app call audioMixer selectTab devices",
        "vb-shell app call audioMixer status"]
    },
    imageViewer: {
      notes: [],
      examples: ["vb-shell app call imageViewer openPath /home/user/Pictures/my-image.png",
        "vb-shell app call imageViewer status"]
    }
  })

  Component.onCompleted: {
    Registry.offer("app", {
      title: "Apps",
      description: "Manage Vibranium's Quickshell apps",
      verbNames: Catalog.topLevelVerbs("app")
    })
    Registry.register("app", root)
    IpcRouter.register("app", root, {
      "app.list": function () { return root._list() },
      "app.open": function (a) { return root._open(a.ID) },
      "app.close": function (a) { return root._close(a.ID) },
      "app.toggle": function (a) { return root._toggle(a.ID) },
      "app.call.list": function (a) { return root._callList(a.ID) },
      "app.call.imageViewer.openPath": function (a) { return root._openPath(a.PATH) },
      "app.call.audioMixer.openTab": function (a) { return root._openTab(a.TAB) },
      "app.call.audioMixer.selectTab": function (a) { return root._selectTab(a.TAB) },
      "app.call.audioMixer.status": function () { return root._appStatus("audioMixer") },
      "app.call.imageViewer.status": function () { return root._appStatus("imageViewer") },
      "app.status": function () { return root._status() },
      "app.ping": function () { return root._pong() }
    }, root._describeApp)
  }
  Component.onDestruction: {
    IpcRouter.unregister("app", root)
    Registry.unregister("app")
  }

  // Gateway owners answer complete v1 frames: typed data, never a human
  // reply to parse. Errors carry only a code and a fixed message.
  function _ok(data, format) {
    const frame = { v: 1, ok: true }
    if (data !== undefined) frame.data = data
    if (format) frame.format = format
    return frame
  }
  function _error(code, message) {
    return { v: 1, ok: false, error: { code: code, message: message } }
  }

  // The table row an id names, or null when no row claims it. Case-sensitive:
  // a padded or differently cased name is a typo rather than an app.
  function _row(id) {
    if (typeof id !== "string") return null
    for (let i = 0; i < root.apps.length; i++) {
      if (root.apps[i].id === id) return root.apps[i]
    }
    return null
  }

  function _registered(id) {
    return Registry.registeredIds().indexOf(id) !== -1
  }

  function _visible(id) {
    return root._registered(id) && Registry.get(id, "visible") === true
  }

  function _call(id, method) {
    const argv = [id, method].concat(Array.prototype.slice.call(arguments, 2))
    return Registry.call.apply(Registry, argv)
  }

  // `app list` reads the host table and each facade's visibility projection.
  // A facade that is not registered yet is not open, and neither controller
  // is demanded to answer a discovery.
  function _list() {
    const rows = []
    for (let i = 0; i < root.apps.length; i++) {
      const app = root.apps[i]
      rows.push({
        id: app.id,
        name: app.title,
        description: app.description,
        open: root._visible(app.id)
      })
    }
    return _ok(rows, { kind: "table", columns: [
      { key: "id", heading: "ID" },
      { key: "name", heading: "Name" },
      { key: "description", heading: "Description" },
      { key: "open", heading: "Open" }
    ] })
  }

  // `app open` presents: a closed app is shown, an open one is focused.
  // Success is silent; only a refusal is reported.
  function _open(id) {
    if (root._row(id) === null) return _error("not-found", "unknown app")
    if (!root._registered(id)) return _error("unavailable", "app facade not registered")
    const answer = root._call(id, "present")
    if (answer !== true) return _error("unavailable", "app refused to present")
    return _ok()
  }

  // Validate every id before the first hide, dedupe in order, then hide at
  // most once per app. Closing when nothing is open is a silent no-op:
  // success still means the requested apps are closed. Unknown ids keep
  // their normal diagnostic.
  function _close(ids) {
    const list = Array.isArray(ids) ? ids : [ids]
    const wanted = []
    for (let i = 0; i < list.length; i++) {
      if (root._row(list[i]) === null) return _error("not-found", "unknown app")
      if (wanted.indexOf(list[i]) === -1) wanted.push(list[i])
    }
    let open = 0
    for (let i = 0; i < wanted.length; i++) {
      if (!root._visible(wanted[i])) continue
      open++
    }
    if (open === 0) return _ok()
    for (let i = 0; i < wanted.length; i++) {
      if (!root._registered(wanted[i])) continue
      root._call(wanted[i], "hide")
    }
    return _ok()
  }

  // One id. Success is silent; read the app's own status for the resulting
  // open state.
  function _toggle(id) {
    if (root._row(id) === null) return _error("not-found", "unknown app")
    if (!root._registered(id)) return _error("unavailable", "app facade not registered")
    const open = root._visible(id)
    const answer = open ? root._call(id, "hide") : root._call(id, "present")
    if (answer !== true && answer !== false && answer !== undefined) {
      // hide() answers undefined; present() answers true. Anything else is a
      // facade that refused the operation.
      if (answer !== undefined) return _error("unavailable", "app refused to toggle")
    }
    return _ok()
  }

  // The canonical help descriptor for one app. Both `app call list <ID>`
  // (a help-kind data reply) and `app call <ID> help` (a describe reply) use
  // this one builder, so the two spellings stay byte-identical.
  function _callHelp(id) {
    const app = root._row(id)
    const spec = root._callSpec[id]
    const prose = root._callHelpProse[id]
    if (!app || !spec || !prose) return null
    const commands = []
    for (let i = 0; i < app.verbs.length; i++) {
      const verb = app.verbs[i]
      const v = spec[verb]
      commands.push({
        id: "app.call." + id + "." + verb,
        usage: v.usage,
        summary: v.description,
        literalSummary: v.literalSummary === true,
        arguments: JSON.parse(JSON.stringify(v.arguments || [])),
        examples: (v.examples || []).slice()
      })
    }
    return {
      usage: "vb-shell app call " + id,
      summary: app.helpSummary,
      arguments: [],
      options: [],
      commands: commands,
      notes: prose.notes.slice(),
      examples: prose.examples.slice()
    }
  }

  // Describe-only seam. It reads the allowlist table above; no facade is
  // demanded, no controller is leased and no window is opened to answer.
  function _describeApp(rest) {
    if (!rest || rest.length !== 2 || rest[0] !== "call") return null
    return root._callHelp(rest[1])
  }

  function _callList(id) {
    const help = root._callHelp(id)
    if (!help) return _error("not-found", "unknown app")
    return _ok(help, { kind: "help" })
  }

  // Path validation reuses the facade's own `_asUrl` wrapper; it demands no
  // controller and constructs no window on a refused path. Success is silent.
  function _openPath(path) {
    if (!root._registered("imageViewer")) return _error("unavailable", "viewer facade not registered")
    const url = root._call("imageViewer", "asUrl", path)
    if (typeof url !== "string" || url === "") return _error("invalid-argument", "absolute path or file: URL required")
    const answer = root._call("imageViewer", "openPath", path)
    if (!answer || typeof answer !== "object") return _error("unavailable", "viewer did not accept the path")
    if (answer.error === "unavailable") return _error("unavailable", "viewer unavailable")
    if (answer.error) return _error("refused", "viewer refused the path")
    return _ok()
  }

  function _openTab(tab) {
    if (!root._registered("audioMixer")) return _error("unavailable", "mixer facade not registered")
    const answer = root._call("audioMixer", "openTab", tab)
    if (answer !== true) return _error("invalid-argument", "unknown mixer tab")
    return _ok()
  }

  function _selectTab(tab) {
    if (!root._visible("audioMixer")) return _error("unavailable", "mixer is not open")
    if (root._call("audioMixer", "selectTab", tab) !== true) {
      return _error("invalid-argument", "unknown mixer tab")
    }
    return _ok()
  }

  // The facade already projects a status object as JSON. No controller is
  // demanded: a facade that has never been used still answers its own state.
  function _appStatus(id) {
    if (root._row(id) === null) return _error("not-found", "unknown app")
    if (!root._registered(id)) return _error("unavailable", "app facade not registered")
    const text = root._call(id, "status")
    if (typeof text !== "string") return _error("unavailable", "app has no status projection")
    try {
      return _ok(JSON.parse(text), { kind: "record" })
    } catch (e) {
      return _error("internal", "unreadable status")
    }
  }

  // Root status reports the list fields plus readiness, not a positional
  // app name.
  function _status() {
    const rows = []
    for (let i = 0; i < root.apps.length; i++) {
      const app = root.apps[i]
      rows.push({
        id: app.id,
        name: app.title,
        description: app.description,
        open: root._visible(app.id),
        ready: root._registered(app.id)
      })
    }
    return _ok({
      unit: root.tag,
      apps: rows,
      live: Registry.registeredIds().filter(function (id) { return root._row(id) !== null })
    }, { kind: "record" })
  }

  function _pong() { return _ok("pong", { kind: "text" }) }
}
