pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import qs.services as Svc
import qs.common
import "PolkitTrace.js" as PolkitTrace
import "../../common/text/UnitIpc.js" as UnitIpc

// Polkit authentication agent replacing polkit-gnome. The DBus side lives in
// PolkitAgent: incoming requests queue there and are presented one by one via
// `flow`. This singleton mirrors the live AuthFlow into plain properties so
// the overlay never binds across flow object swaps, funnels submit/cancel
// back into it, and owns the visible/closing lifecycle plus failure feedback
// timing. A failed attempt makes the backend spin up a fresh conversation,
// which re-raises isResponseRequired - that flip ends the "checking" wait.
//
// Nothing here ever reads or keeps anything derived from what the user typed
// into a PAM prompt. `submitPassword` is the only function in this file that
// ever holds one; it forwards the string straight to `flow.submit()`.
Singleton {
  id: root

  readonly property string tag: "polkit"

  // Dialog lifecycle: active = request on screen, closing = playing the exit
  // fade before teardown resets everything back to defaults.
  property bool active: false
  property bool closing: false
  readonly property bool visible: root.active || root.closing

  // Mirrored AuthFlow snapshot for the current request.
  property string message: ""
  property string prompt: ""
  property string supplementary: ""
  property bool supplementaryIsError: false
  property bool responseRequired: false
  // Mirrors flow.responseVisible ("show typed characters"). Defaults false:
  // anything but an explicit true must render dots.
  property bool responseVisible: false

  // Feedback state: checking covers submit -> verdict, attempts drives the
  // failure flash and shake in each view's PasswordBox (fail() on the
  // attempts change), resetToken tells the view when to wipe and refocus
  // the field.
  property bool checking: false
  property int attempts: 0
  property int resetToken: 0

  // Flow object currently wired; guards against duplicate connections if a
  // backend ever hands the same instance back.
  property var wiredFlow: null

  // ---- the conversation, as a record ---------------------------------------
  //
  // The booleans above are the dialog's own state and the view binds to them.
  // `conv` is the same state as one value, advanced only through
  // PolkitTrace.apply, because a PAM conversation is a state machine and a state
  // machine whose rules live in property assignments cannot be tested.
  // PolkitTrace is a `.pragma library` and needs no engine, so a probe can
  // drive the whole machine with a
  // synthetic script; importing THIS file from a probe would construct a live
  // PolkitAgent and register a second authentication agent on the user's
  // session.
  property var conv: PolkitTrace.newConversation()

  // One read-only projection of `conv` for the view, which must not reach
  // into the record itself. A view binding across the record would re-evaluate
  // on every field, and the record is a plain object rather than a changeable
  // type, so a binding to `conv.action` would never re-fire.
  readonly property string conversationAction: root.conv.action
  // Whether the agent registered with polkitd, exposed so a headless
  // harness has a handle on it.
  readonly property bool registered: agent.isRegistered

  // Requests started minus requests finished. The backend presents one at a
  // time and queues the rest, so this can only exceed one if the shell lost
  // track - and the request it lost track of is the one a user is looking at a
  // dialog that will never answer for.
  property int inFlight: 0

  // One event through the machine. Returns false when the machine refuses the
  // event, which is the one shape of a caller bug: a refused event leaves the
  // conversation exactly where it was.
  function _apply(type, action, identities, by) {
    const next = PolkitTrace.apply(root.conv, {
      type: type,
      at: Date.now(),
      action: action === undefined ? "" : action,
      identities: identities === undefined ? 0 : identities,
      by: by === undefined ? "" : by
    })
    if (next === null) return false
    root.conv = next
    return true
  }

  function syncFromFlow(f) {
    if (f === undefined) f = agent.flow
    if (!f) return
    root.message = f.message ?? ""
    root.prompt = f.inputPrompt ?? ""
    root.supplementary = f.supplementaryMessage ?? ""
    root.supplementaryIsError = f.supplementaryIsError === true
    root.responseRequired = f.isResponseRequired === true
    root.responseVisible = f.responseVisible === true
  }

  // Flow signals are wired imperatively instead of via Connections { target:
  // agent.flow }: the backend nulls isActive/flow BEFORE emitting the
  // outcome signals, which would retarget the Connections away and swallow
  // authenticationSucceeded. Direct connects to the flow object survive.
  // The observers. Each is a named function rather than an inline lambda body
  // for a reason that is not style, and it is worth writing down because the
  // next person to tidy this will undo it. A multi-statement lambda passed
  // straight to connect() - connect with a braced arrow - makes qmllint give
  // up on the type of the agent id for the WHOLE file, so every agent.flow
  // read stops being type-checked and the four pre-existing unresolved-type
  // warnings for AuthFlow silently disappear. Losing a warning is not a
  // cosmetic change: it moves a pinned per-kind count in the qmllint suite.
  // So the connect calls below stay single-expression arrows, and the bodies
  // that need more than one statement live here, as functions.
  function observePromptText(f) {
    root.syncFromFlow(f)
  }

  function observeEcho(f) {
    root.syncFromFlow(f)
  }

  function observeSupplementary(f) {
    root.syncFromFlow(f)
  }

  function observeResponseRequired(f) {
    // Fresh prompt after a failed attempt or in multi-turn PAM: waiting is over
    // even though no explicit success signal arrives.
    root.syncFromFlow(f)
    // The same signal going the other way is what `submit()` does the instant
    // it hands the response over, so it is the backend saying "I have it"
    // rather than a turn ending.
    if (!f.isResponseRequired) return
    root.checking = false
    root.onTurn()
  }

  // Flow signals are wired imperatively instead of via Connections { target:
  // agent.flow }: the backend nulls isActive/flow BEFORE emitting the
  // outcome signals, which would retarget the Connections away and swallow
  // authenticationSucceeded. Direct connects to the flow object survive.
  //
  // The sync-only observers stay single-expression arrows on purpose; see the
  // note above the observer functions for why.
  function wireFlow(f) {
    if (!f || root.wiredFlow === f) return
    root.wiredFlow = f
    f.inputPromptChanged.connect(() => root.observePromptText(f))
    f.responseVisibleChanged.connect(() => root.observeEcho(f))
    f.supplementaryMessageChanged.connect(() => root.observeSupplementary(f))
    f.supplementaryIsErrorChanged.connect(() => root.syncFromFlow(f))
    f.isResponseRequiredChanged.connect(() => root.observeResponseRequired(f))
    f.authenticationFailed.connect(root.handleAuthFailed)
    f.authenticationSucceeded.connect(root.handleAuthSucceeded)
    f.authenticationRequestCancelled.connect(root.handleRequestCancelled)
  }

  // A PAM turn is outstanding. The only place a turn is counted into the
  // conversation record.
  function onTurn() {
    root._apply("prompt")
  }

  function beginRequest() {
    // The one read of `agent.flow` this function needs. The `wiredFlow`
    // snapshot is the PREVIOUS request's object, so reading it here would sync
    // this request's snapshot from the last one.
    const incoming = agent.flow
    // A request arriving during the previous one's exit fade must disarm
    // the pending teardown or it would wipe this request's state mid-flight.
    closeTimer.stop()
    root.closing = false
    root.active = true
    root.checking = false
    root.inFlight += 1
    root.wireFlow(incoming)
    root.syncFromFlow(incoming)
    root._apply("request", root._actionId(incoming), root._identityCount(incoming))
    Svc.Keyboard.sync()
    root.resetToken++
    // The typed password never reaches this function - it is passed
    // straight to submit().
  }

  function _actionId(f) {
    return f === null || f === undefined ? "" : f.actionId
  }

  // How many identities polkit will accept for this request. The identities
  // themselves are user and group names off the wire, so only the count of
  // them is ever taken.
  function _identityCount(f) {
    if (f === null || f === undefined) return 0
    const list = f.identities
    return list === null || list === undefined ? 0 : list.length
  }

  function submitPassword(text) {
    const f = agent.flow
    if (!root.active || !f || !f.isResponseRequired || root.checking || text === "") return
    root.checking = true
    // `text` goes from here straight into the backend; nothing derived from it
    // is kept anywhere in this component.
    root._apply("submit")
    f.submit(text)
    root.resetToken++
  }

  function cancelRequest() {
    const f = agent.flow
    root.checking = false
    if (f && root.active) {
      // Note what the backend does NOT do here: `cancelAuthenticationRequest`
      // sets `isCancelled` and cancels the session, and unlike
      // `cancelFromAgent` it emits NO `authenticationRequestCancelled`. So the
      // user-side cancel has to be recorded here, because nothing downstream
      // will ever report it.
      root._apply("cancelled", undefined, undefined, "user")
      f.cancelAuthenticationRequest()
    }
    root.beginClose()
  }

  // Exit path always goes through here so the overlay fades instead of
  // popping; finishClose() then drops all state once the fade has played.
  // The 200ms window also gives late outcome signals room to land, since
  // the backend retires isActive before emitting them.
  function beginClose() {
    if (root.closing || !root.active) return
    // Legal by the guard above, so assigned directly rather than through
    // _apply: a failure here could only be the guard disagreeing with the
    // machine, and the guard is the one that decides.
    root.conv = PolkitTrace.apply(root.conv, { type: "begin-close", at: Date.now() })
    root.closing = true
    closeTimer.restart()
  }

  function finishClose() {
    if (PolkitTrace.refused(root.conv, "close") === "") root._apply("close")
    root.closing = false
    root.active = false
    root.checking = false
    root.attempts = 0
    root.message = ""
    root.prompt = ""
    root.supplementary = ""
    root.supplementaryIsError = false
    root.responseRequired = false
    root.responseVisible = false
    root.inFlight = Math.max(0, root.inFlight - 1)
  }

  Component.onCompleted: {
    Registry.offer("polkit", {
      title: "Polkit",
      description: "authentication agent",
      verbNames: [
        "cancel",
        "status",
        "help",
        "ping",
      ]
    })
    // The agent is constructed by now, and constructing it is what starts the
    // registration: `PolkitAgent.componentComplete` calls
    // `polkit_agent_listener_register` for the shell's own process session.
  }

  PolkitView {}

  Timer {
    id: closeTimer

    interval: 200
    onTriggered: root.finishClose()
  }

  PolkitAgent {
    id: agent
    path: "/org/vibranium/Polkit"

    onAuthenticationRequestStarted: root.beginRequest()

    onIsActiveChanged: {
      // The backend retires isActive before emitting outcome signals; going
      // through beginClose (not finishClose) keeps the fade and leaves a
      // window for them to land. Covers daemon-side cleanup that arrives
      // without any flow signal.
      if (!isActive && !root.closing) root.beginClose()
    }

  }

  function handleAuthFailed() {
    root.checking = false
    if (!root._apply("rejected")) return
    root.attempts += 1
    root.resetToken++
  }

  function handleAuthSucceeded() {
    root.checking = false
    root._apply("granted")
    root.beginClose()
  }

  function handleRequestCancelled() {
    // Emitted ONLY by `cancelFromAgent`, which is what quickshell calls when
    // polkitd cancels through the request's cancellable. A TIMEOUT arrives the
    // same way - polkitd's `polkit.requested.timeout` expiry cancels the
    // request - and the handler is `cancelAuthentication(request)` with no
    // reason attached, so the two are NOT separable from QML. `by=daemon` is the
    // honest claim: polkitd ended it, and a reader cannot tell from here whether
    // that was a timeout or a revocation.
    root._apply("cancelled", undefined, undefined, "daemon")
    root.beginClose()
  }

  IpcHandler {
    target: "polkit"
    function help(command: string): string {
      return UnitIpc.help("polkit", "Polkit", "authentication agent", [
        { name: "cancel", help: "cancel the current auth prompt" },
      ], command)
    }
    function ping(): string { return "pong" }

    function status(): string {
      return JSON.stringify({
        registered: agent.isRegistered,
        active: root.active,
        closing: root.closing,
        checking: root.checking,
        attempts: root.attempts,
        responseRequired: root.responseRequired,
        action: root.conv.action,
        turns: root.conv.turns,
        submits: root.conv.submits,
        inFlight: root.inFlight,
        outcome: root.conv.active ? "pending" : PolkitTrace.outcome(root.conv),
        message: root.message,
        prompt: root.prompt,
        supplementary: root.supplementary
      })
    }

    function cancel(): string {
      root.cancelRequest()
      return "ok"
    }
  }
}
