pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import qs.services
// Documented exception (spec phase G): filterCounter is shared UI-pool
// logic, not menu-row building; kill by moving it to a shared lib later.
import "../menu/MenuLib.js" as MenuLib
import "../../common/text/UnitIpc.js" as UnitIpc

// Power menu UI - lists actions from config.json (name, description, icon)
// and delegates every activation to the session service. No
// commands live here.
//
// Two fail-safe states. A config that cannot be read, is blank, or does not
// parse replaces the action list with an explicit fault instead of keeping
// the previous one. A session-ending action does not dispatch from
// activate(): it arms a single confirmation stage, and only confirmPending()
// asks Session to run it, by naming the action to Session.requestDestructive -
// a method of no IPC verb, which accepts only a name in a frozen
// null-prototype allowlist, so this unit passes an action name and never a
// confirmation value. Both states are readable from configFault /
// dispatchFault, from the "powerMenu.bus" topic, and from the status verb.
Singleton {
  id: root

  readonly property string tag: "power"

  property bool visible: false
  property string query: ""
  property var results: []

  property var _panels: []
  // Token for the exclusive-surface claim this open holds, released by
  // close() and by Component.onDestruction.
  property var _claimToken: null

  function _attachPanel(panel) {
    const next = root._panels.slice()
    next.push(panel)
    root._panels = next
  }

  function _detachPanel(panel) {
    root._panels = root._panels.filter(p => p !== panel)
  }

  readonly property string effectiveFocusMode: {
    for (let i = 0; i < root._panels.length; i++) {
      const p = root._panels[i]
      if (p.primarySurface) return p.probeFocus().mode
    }
    return "list"
  }
  readonly property bool effectiveFilterFocused: root.effectiveFocusMode === "filter"

  // Config-driven - loaded from config.json
  property var _actions: []

  // Config fault state. A non-empty code is an explicit fault: the action
  // list is empty and the reason is readable by the view and over IPC,
  // rather than the previous list silently surviving a broken file.
  // "unreadable" - the file could not be read
  // "empty"      - blank file, or no entry survived validation
  // "malformed"  - not JSON, or not an array of actions
  property string _configFault: ""
  readonly property string configFault: root._configFault
  readonly property var _faultText: ({
    unreadable: "Power actions are unreadable",
    empty: "Power actions are empty",
    malformed: "Power actions are malformed"
  })
  readonly property string configFaultMessage: root._configFault === ""
    ? "" : String(root._faultText[root._configFault] ?? root._configFault)

  // Actions that end the session. They never dispatch from activate(): the
  // row arms the confirmation stage and the menu stays open.
  readonly property var destructiveActions: ["poweroff", "reboot", "uefi-reboot", "logout"]
  readonly property string confirmationAction: root._confirmationAction
  readonly property string confirmationLabel: root._confirmationLabel
  readonly property bool confirmationArmed: root._confirmationAction !== ""
  // Verdict of the last confirmed dispatch, kept readable instead of
  // swallowed (same rule as the config fault).
  readonly property string dispatchFault: root._dispatchFault
  property string _confirmationAction: ""
  property string _confirmationLabel: ""
  property string _dispatchFault: ""

  function _hayFor(a) {
    return (String(a.label ?? "") + " " + String(a.sub ?? "") + " " + String(a.desc ?? "")).toLowerCase()
  }

  function _recompute() {
    // Filtering + matched/total come from MenuLib.filterCounter (the same
    // shared counter the launcher uses). No display cap here - the config
    // pool is tiny, so matching over the whole list is always honest.
    const res = MenuLib.filterCounter(root._actions, root.query, root._actions.length)
    root.results = res.rows
    root.matchedCount = res.matched
    root.totalCount = res.total
  }

  FileView {
    id: configView
    path: Paths.vibraniumHome + "/shell/features/powerMenu/config.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root._loadConfig()
  }

  FileView {
    id: configReader
    printErrors: false
  }

  function _readConfigText() {
    configReader.path = ""
    configReader.path = Paths.vibraniumHome + "/shell/features/powerMenu/config.json"
    if (!configReader.waitForJob()) return null
    return configReader.text()
  }

  // Single commit point: the list and the fault always land together, so no
  // fault path can leave a stale action list on screen, and the counters
  // follow the committed list.
  function _commitActions(list, fault) {
    root._actions = list
    root._configFault = fault
    root._recompute()
    root._publishState()
  }

  // Discrete service state for the view, the same shape Session uses to
  // surface a lock refusal: Bus.latest replays it to a reader that binds
  // later, so a fault raised while no panel exists is still shown.
  function _publishState() {
    Bus.publish("powerMenu.bus", {
      fault: root._configFault,
      faultMessage: root.configFaultMessage,
      actionCount: root._actions.length,
      confirmation: root._confirmationAction,
      confirmationLabel: root._confirmationLabel,
      dispatchFault: root._dispatchFault
    })
  }

  function _loadConfig() {
    // A reload invalidates an armed stage: the row it named may be gone.
    root._clearConfirmation()
    const text = root._readConfigText()
    if (text === null) {
      root._commitActions([], "unreadable")
      return
    }
    if (String(text).trim() === "") {
      root._commitActions([], "empty")
      return
    }
    let data = null
    try {
      data = JSON.parse(text)
    } catch (e) {
      root._commitActions([], "malformed")
      return
    }
    const list = Array.isArray(data) ? data
      : (data && typeof data === "object" && Array.isArray(data.actions) ? data.actions : null)
    if (list === null) {
      root._commitActions([], "malformed")
      return
    }
    const out = []
    for (let i = 0; i < list.length; i++) {
      const e = list[i]
      if (!e || typeof e.name !== "string" || e.name.trim() === "") continue
      if (typeof e.description !== "string") continue
      if (typeof e.icon !== "string") continue
      if (typeof e.action !== "string" || e.action.trim() === "") continue
      const rec = {
        id: String(e.id ?? e.name).toLowerCase().replace(/\s+/g, "-"),
        label: String(e.name),
        sub: String(e.description),
        desc: String(e.description),
        icon: String(e.icon),
        action: String(e.action)
      }
      // Same hay the shared matcher indexes on, built once at load.
      rec.hay = root._hayFor(rec)
      rec.words = rec.hay.split(" ")
      out.push(rec)
    }
    if (out.length === 0) {
      root._commitActions([], "empty")
      return
    }
    root._commitActions(out, "")
  }

  Component.onCompleted: {
    Registry.offer("powerMenu", {
      title: "Power menu",
      description: "session power actions",
      verbNames: [
        "close",
        "open",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    root._loadConfig()
    root._recompute()
  }

  Component.onDestruction: {
    SurfaceClaim.releaseOwner(root)
  }

  function open() {
    if (root.visible) return
    // Exclusive surfaces: dismiss whichever menu holds the screen first.
    root.visible = true
    // Claimed once the surface is up, not before: the stored closer is
    // close(), which refuses to run while `visible` is false, so a claim
    // taken earlier would install a closer that provably does nothing and
    // leave a claim nobody can retire.
    root._claimToken = SurfaceClaim.claim("power", root.close, root)
  }

  function close() {
    if (!root.visible) return
    root.visible = false
    // The stage dies with the surface: no armed destructive action outlives
    // its menu.
    root._clearConfirmation()
    SurfaceClaim.release(root._claimToken)
    root._claimToken = null
  }

  function toggle() {
    root.visible ? root.close() : root.open()
  }

  function reset() {
    root.query = ""
    root._recompute()
  }

  onVisibleChanged: {
    if (!root.visible) Qt.callLater(root.reset)
  }

  function submit(text) {
    root.query = text
    root._recompute()
  }

  function clearQuery() {
    if (root.query === "") return
    root.query = ""
    root._recompute()
  }

  function activate(row) {
    if (!row) return
    const action = String(row.action ?? "")
    if (action === "") return
    // A destructive row arms the stage instead of running: the menu stays
    // open and only the confirm path asks Session to act.
    if (root.isDestructive(action)) {
      root._armConfirmation(row)
      return
    }
    root.close()
    Qt.callLater(() => root._execute(row))
  }

  function isDestructive(action) {
    return root.destructiveActions.indexOf(String(action)) >= 0
  }

  // Arm the single destructive stage. Re-arming replaces the armed action,
  // so one activation can never queue two.
  function _armConfirmation(row) {
    root._confirmationAction = String(row.action)
    root._confirmationLabel = String(row.label ?? row.action)
    root._dispatchFault = ""
    root._publishState()
  }

  function _clearConfirmation() {
    if (root._confirmationAction === "" && root._confirmationLabel === "") return
    root._confirmationAction = ""
    root._confirmationLabel = ""
    root._publishState()
  }

  function cancelPending() {
    root._clearConfirmation()
  }

  // The only path that runs a destructive action. The authority is
  // Session.requestDestructive itself: a method declared outside the
  // IpcHandler, so no IPC verb reaches it, and accepting only a name the
  // frozen allowlist holds, so no caller-supplied value stands in for the
  // user's confirmation and this unit can never satisfy the check with a value
  // it holds. A missing or failing authority fails closed instead of falling
  // back to Session.dispatch.
  function confirmPending() {
    const action = root._confirmationAction
    if (action === "") {
      root._recordDispatchFault("nothing_to_confirm")
      return
    }
    root._clearConfirmation()
    let wired = false
    try {
      wired = typeof Session.requestDestructive === "function"
    } catch (unwired) {
      wired = false
    }
    if (!wired) {
      root._recordDispatchFault("confirmation_unavailable", action)
      return
    }
    let verdict = ""
    try {
      verdict = String(Session.requestDestructive(action))
    } catch (e) {
      verdict = "dispatch_error"
    }
    if (verdict === "ok") {
      root._dispatchFault = ""
      root._publishState()
      root.close()
      return
    }
    root._recordDispatchFault(verdict === "" ? "dispatch_error" : verdict, action)
  }

  function _recordDispatchFault(code, action) {
    const fault = String(code)
    root._dispatchFault = fault
    root._publishState()
  }

  function _execute(row) {
    if (!row || typeof row.action !== "string") return
    // Second gate on the destructive family: whatever routed the row in,
    // it never reaches Session.dispatch from here.
    if (root.isDestructive(row.action)) {
      root._recordDispatchFault("confirmation_required", row.action)
      return
    }
    // Same closed vocabulary as the confirm path: a name from config.json
    // that Session.dispatch switches on, not a command line.
    if (!Session.dispatch(row.action)) {
      root._recordDispatchFault("unknown_action")
    }
  }

  property int matchedCount: 0
  property int totalCount: 0

  IpcHandler {
    target: "power"
    function help(command: string): string {
      return UnitIpc.help("power", "Power menu", "session power actions", [
        { name: "close", help: "hide the menu" },
        { name: "open", help: "show the menu" },
        { name: "toggle", help: "show/hide" },
      ], command)
    }
    function ping(): string { return "pong" }
    function toggle(): string { root.toggle(); return "ok" }
    function open(): string { root.open(); return "ok" }
     function close(): string { root.close(); return "ok" }
     function status(): string {
       return JSON.stringify({
         visible: root.visible,
         query: root.query,
         count: root.results.length,
         total: root.totalCount,
         filterFocused: root.effectiveFilterFocused,
         focusMode: root.effectiveFocusMode,
         configFault: root.configFault,
         configFaultMessage: root.configFaultMessage,
         confirmation: root.confirmationAction,
         dispatchFault: root._dispatchFault
       })
     }
  }

  PowerMenuView {}
}
