pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.common
import qs.features.menu
import "../../../common/text/UnitIpc.js" as UnitIpc

// Keybindings browser service. Reads `hyprctl -j binds` and formats every
// binding for display (modmask names, mouse/scroll naming, submap tags,
// XF86/Lid Switch filtered out), shown as a menu page under Menu -> Help
// -> Keybindings. Rows are expandable reference rows: Enter/Ctrl+I reveals
// the dispatcher detail, nothing ever closes the menu or runs a command.
Singleton {
  id: root

  readonly property string tag: "keybindings"
  readonly property string pageId: "keybindings"

  // Last formatted rows; null = never scanned.
  property var _cached: null
  property bool _scanRunning: false
  // false = silent, true = live refresh, "open" = land the page when done.
  property var _pendingShow: null

  Component.onCompleted: {
    Registry.offer("keybindings", {
      title: "Keybindings",
      description: "hyprland keybinding cheatsheet",
      verbNames: [
        "close",
        "open",
        "refresh",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    // Registry.call routes runCall specs ("keybindings open") here;
    // offer() alone only feeds the IPC manifest.
    Registry.register("keybindings", root)
    Hyprland.rawEvent.connect(root.onRawEvent)
  }
  Component.onDestruction: {
    Hyprland.rawEvent.disconnect(root.onRawEvent)
    Registry.unregister("keybindings")
  }

  // --- one-shot scan process (created per run, destroyed after) ---

  Component {
    id: scanProcComp

    Process {
      // var, not bool: callers pass "open" (land when done), true (live
      // refresh) or false (silent). A bool would coerce "open" to true and
      // demote the first summon to a refresh that no-ops on a closed menu.
      property var wantShow: false

      stdout: StdioCollector {
        waitForEnd: true
      }
      stderr: StdioCollector {}

      onExited: (code, status) => {
        root._scanRunning = false
        const show = wantShow
        if (code !== 0) {
          root._pendingShow = null
          // Surface the failure instead of an empty page on first summon.
          if (show === "open" || root._pendingShow === "open") {
            root._pendingShow = null
            root._cached = []
            root._cachedError = true
            root.open()
          }
          destroy()
          return
        }
        root._applyScan(stdout.text, show)
        destroy()
      }
    }
  }

  property bool _cachedError: false

  function _scan(show) {
    if (root._scanRunning) {
      // Concurrent requests: the strongest wins and is never clobbered by
      // a weaker one ("open" > live refresh > silent).
      if (show === "open") root._pendingShow = "open"
      else if (root._pendingShow !== "open" && show === true) root._pendingShow = true
      return
    }
    root._scanRunning = true
    const proc = scanProcComp.createObject(root, {
      wantShow: show === undefined ? false : show,
      command: ["hyprctl", "-j", "binds"]
    })
    proc.running = true
  }

  // Numeric modmask -> human-readable modifier names: bitwise ORs of
  // SHIFT=1, CTRL=4, ALT=8, SUPER=64.
  function _modName(mask) {
    switch (Number(mask)) {
      case 0: return ""
      case 1: return "SHIFT"
      case 4: return "CTRL"
      case 5: return "SHIFT CTRL"
      case 8: return "ALT"
      case 9: return "SHIFT ALT"
      case 12: return "CTRL ALT"
      case 13: return "SHIFT CTRL ALT"
      case 64: return "SUPER"
      case 65: return "SUPER SHIFT"
      case 68: return "SUPER CTRL"
      case 69: return "SUPER SHIFT CTRL"
      case 72: return "SUPER ALT"
      case 73: return "SUPER SHIFT ALT"
      case 76: return "SUPER CTRL ALT"
      case 77: return "SUPER SHIFT CTRL ALT"
      default: return "MOD" + mask
    }
  }

  function _applyScan(text, show) {
    let binds
    try {
      binds = JSON.parse(text)
    } catch (e) {
      binds = []
    }
    if (!Array.isArray(binds)) binds = []
    const seen = {}
    const rows = []
    for (let i = 0; i < binds.length; i++) {
      const b = binds[i] || {}
      const key = String(b.key ?? "")
      const desc = String(b.description ?? "")
      // Ignore script-defined cases: lid switch + media keys.
      if (key.indexOf("XF86") !== -1 || desc.indexOf("XF86") !== -1) continue
      if (key.indexOf("Lid Switch") !== -1 || key.indexOf("switch:") === 0) continue
      if (desc.indexOf("Lid Switch") !== -1) continue
      const keycode = Number(b.keycode || 0)
      let k = key
      if (k === "" && keycode !== 0) k = "code:" + keycode
      if (k === "") continue
      // Normalize mouse and scroll naming (same as the script).
      k = k.replace(/mouse_down/g, "Scroll down")
        .replace(/mouse_up/g, "Scroll up")
        .replace(/mouse:272/g, "Left click")
        .replace(/mouse:273/g, "Right click")
      const mod = root._modName(b.modmask)
      let combo = mod !== "" ? mod + " + " + k : k
      combo = combo.replace(/^[ \t]*\+?[ \t]*/, "").replace(/[ \t]+$/, "")
        .replace(/[ \t]+/g, " ")
      // Action: the description when set, else dispatcher + arg (exec
      // prefix stripped, like the script's awk pass). `__lua` with a
      // numeric arg is an internal Lua callback pointer, not a command:
      // label the two stock mouse gestures and mark any other
      // undescribed one honestly instead of printing "__lua N".
      let action = desc
      const dispatcher = String(b.dispatcher ?? "")
      const arg = String(b.arg ?? "").replace(/^uwsm app -- /, "")
      if (action === "") {
        if (dispatcher === "__lua") {
          if (k === "Left click") action = "Drag window"
          else if (k === "Right click") action = "Resize window"
          else action = "Custom action"
        } else if (dispatcher === "exec") action = arg
        else action = (dispatcher + " " + arg).trim()
      }
      if (action === "") continue
      const submap = String(b.submap ?? "")
      const sub = (submap !== "" ? "[" + submap + "] " : "") + action
      const dedup = combo + "\n" + sub
      if (seen[dedup]) continue
      seen[dedup] = true
      // Reference rows carry no expandable detail: the sub line already
      // says everything (dispatchers are internal __lua pointers, the
      // submap tag is in the sub). Rows without detail show no chevron
      // and Enter is a no-op - the page is a cheatsheet, not a menu.
      rows.push({ combo: combo, sub: sub })
    }
    rows.sort((a, b) => a.combo.localeCompare(b.combo) || a.sub.localeCompare(b.sub))
    root._cached = rows
    root._cachedError = false
    // Consume whichever request(s) arrived while the scan ran: an open
    // request lands the page, a live refresh only recomposes it.
    const wantOpen = show === "open" || root._pendingShow === "open"
    const wantLive = show === true || root._pendingShow === true
    root._pendingShow = null
    if (wantOpen) root.open()
    else if (wantLive && Menu.open && Menu.frame && Menu.frame.id === root.pageId) root._compose()
  }

  // --- page composition ---

  function _compose() {
    const rows = root._cached || []
    const items = []
    if (root._cachedError || (root._cached !== null && rows.length === 0)) {
      items.push({
        type: "action",
        id: "keybindings-none",
        label: root._cachedError ? "Could not read keybindings" : "No keybindings found",
        sub: "Run: hyprctl -j binds",
        command: "",
        selectable: false
      })
    }
    for (let i = 0; i < rows.length; i++) {
      items.push({
        type: "expandable",
        id: "",
        label: rows[i].combo,
        sub: rows[i].sub,
        selectable: true
      })
    }
    Menu.injectPage(Menu.buildDynamicPage(root.pageId, "Keybindings", 400, items), null)
  }

  // --- open / close / refresh ---

  // Landing sequence defers one tick: seat the main bundle, re-inject the
  // dynamic page onto it, then push. close() preserves injected pages, so a
  // Help-entry click survives its own navigation.
  function open() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return "ok"
    if (root._cached === null) {
      // First summon: scan, then land when it completes (_pendingShow).
      root._scan("open")
      return "ok"
    }
    root._compose()
    Qt.callLater(() => {
      // Re-entrancy guard: a double summon queues two landings; the
      // second must not push a duplicate frame of the same page.
      if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return
      if (!Menu.open) Menu.openFile(Paths.vibraniumHome + "/default/vibranium/menus/main.jsonc")
      if (!Menu.hasDynamicPage(root.pageId)) root._compose()
      Menu.push(root.pageId)
      // Refresh behind the landed page so binds edited since the last
      // scan show up without another summon.
      root._scan(true)
    })
    return "ok"
  }

  function close() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) Menu.close()
    return "ok"
  }

  function toggle() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return root.close()
    return root.open()
  }

  // Invalidates the cache and rescans; silent unless the page is open,
  // which recomposes live.
  function refresh() {
    root._cached = null
    root._cachedError = false
    root._scan(Menu.open && Menu.frame && Menu.frame.id === root.pageId)
    return "ok"
  }

  // Auto-refresh on config reload (same rawEvent precedent as
  // Workspaces): binds edited live re-scan silently, the open page
  // recomposes through the normal pending path.
  function onRawEvent(event) {
    if (!event || event.name !== "configreloaded") return
    root.refresh()
  }

  function status() {
    return JSON.stringify({
      cached: root._cached ? root._cached.length : 0,
      open: Menu.open && Menu.frame ? Menu.frame.id : ""
    })
  }

  IpcHandler {
    target: "keybindings"
    function help(command: string): string {
      return UnitIpc.help("keybindings", "Keybindings", "hyprland keybinding cheatsheet", [
        { name: "close", help: "hide the cheatsheet" },
        { name: "open", help: "show the cheatsheet" },
        { name: "refresh", help: "rescan hyprland binds" },
        { name: "toggle", help: "show/hide" },
      ], command)
    }
    function ping(): string { return "pong" }
    function open(): string { return root.open() }
    function close(): string { return root.close() }
    function toggle(): string { return root.toggle() }
    function refresh(): string { return root.refresh() }
    function status(): string { return root.status() }
  }
}
