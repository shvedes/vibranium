pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import qs.common
import qs.services as Svc
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

  // Feedback state. `checking` and `attempts` are READ-ONLY projections of
  // `conv` (declared below): the conversation state machine is their only
  // writer, so a submit or a rejection can never leave a second copy out of
  // step with the record. `checking` covers submit -> verdict and `attempts`
  // drives the failure flash and shake in each view's PasswordBox (fail() on
  // the attempts change). `resetToken` tells the view when to wipe and
  // refocus the field.
  readonly property bool checking: root.conv.checking
  readonly property int attempts: root.conv.attempts
  property int resetToken: 0

  // The flow currently wired and the generation it was wired in. A newer
  // request retires every deferred closure of the old flow: each observer
  // captures both values and discards an event unless they still match. The
  // upstream `deleteLater()` leaves old QML connects alive by design, so
  // identity + epoch checking (not disconnecting) is the guard.
  property var wiredFlow: null
  property int flowEpoch: 0

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
  // Every flow observer takes the flow it was wired to and the epoch captured
  // at connect time and discards the event unless both still match the live
  // seat. A retired flow's late outcome must never be applied to the request
  // that replaced it (POL-1 / Q3). The guard lives here, NOT in the connect
  // call: a braced arrow there changes qmllint's whole-file type inference
  // and moves the pinned unresolved-type count.
  function isCurrentFlow(f, epoch) {
    return f === root.wiredFlow && epoch === root.flowEpoch
  }

  function observePromptText(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    root.syncFromFlow(f)
  }

  function observeEcho(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    root.syncFromFlow(f)
  }

  function observeSupplementary(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    root.syncFromFlow(f)
  }

  function observeSupplementaryError(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    root.syncFromFlow(f)
  }

  function observeResponseRequired(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    // Fresh prompt after a failed attempt or in multi-turn PAM: waiting is over
    // even though no explicit success signal arrives.
    root.syncFromFlow(f)
    // The same signal going the other way is what `submit()` does the instant
    // it hands the response over, so it is the backend saying "I have it"
    // rather than a turn ending.
    if (!f.isResponseRequired) return
    // `checking` is derived from conv; _apply("prompt") clears it there.
    root.onTurn()
  }

  // Every observer stays a single-expression arrow here, for the qmllint
  // reason recorded above; the multi-statement bodies live in the named
  // functions, which also carry the epoch guard.
  function wireFlow(f) {
    if (!f) return
    // Captured at connect time, after beginRequest() has advanced flowEpoch.
    // Do NOT skip rewiring when the backend hands back the same object: the
    // old connects stay alive (deleteLater) and only this epoch separates
    // them from the new ones. Identity + epoch, not disconnect, retire a flow.
    const epoch = root.flowEpoch
    root.wiredFlow = f
    f.inputPromptChanged.connect(() => root.observePromptText(f, epoch))
    f.responseVisibleChanged.connect(() => root.observeEcho(f, epoch))
    f.supplementaryMessageChanged.connect(() => root.observeSupplementary(f, epoch))
    f.supplementaryIsErrorChanged.connect(() => root.observeSupplementaryError(f, epoch))
    f.isResponseRequiredChanged.connect(() => root.observeResponseRequired(f, epoch))
    f.authenticationFailed.connect(() => root.handleAuthFailed(f, epoch))
    f.authenticationSucceeded.connect(() => root.handleAuthSucceeded(f, epoch))
    f.authenticationRequestCancelled.connect(() => root.handleRequestCancelled(f, epoch))
  }

  // A PAM turn is outstanding. The only place a turn is counted into the
  // conversation record.
  function onTurn() {
    root._apply("prompt")
  }

  // The mirrored flow fields have one clear path, shared by the normal
  // teardown and by supersession. `active`, `closing` and `inFlight` stay
  // with the callers: supersession keeps the surface up, whereas finishClose
  // takes it down.
  function clearMirroredState() {
    root.message = ""
    root.prompt = ""
    root.supplementary = ""
    root.supplementaryIsError = false
    root.responseRequired = false
    root.responseVisible = false
  }

  function beginRequest() {
    // The one read of `agent.flow` this function needs. The `wiredFlow`
    // snapshot is the PREVIOUS request's object, so reading it here would sync
    // this request's snapshot from the last one.
    const incoming = agent.flow
    // A new request takes the seat from whatever conversation is still on
    // screen. When the previous one is active or was already on its way out,
    // retire it BEFORE arming this one: run the same "close" transition the
    // normal teardown uses, drop its inFlight seat and its mirrored fields.
    // Without this, a request arriving during the exit fade leaves the old
    // seat counted and inFlight climbs to 2 and never returns to 0 (POL-2/Q2).
    // `refused(..., "close") === ""` is true exactly when a conversation is
    // still active or closing — i.e. there is an old one to retire — which
    // also covers the (backend-anomalous) request arriving with no fade.
    //
    // "close" clears conv.active before _apply("request"), so PolkitTrace
    // computes supersedes="" here. That is deliberate: the old conversation
    // was properly retired through its close path, not abandoned, so calling
    // it "superseded" would misreport it. There is no surface claim to
    // release: polkit is a system-summoned modal excluded from SurfaceClaim.
    if (PolkitTrace.refused(root.conv, "close") === "") {
      closeTimer.stop()
      root._apply("close")
      root.closing = false
      clearMirroredState()
      root.inFlight = Math.max(0, root.inFlight - 1)
    }
    // Tokens: a newer request retires every deferred closure of the old flow.
    root.flowEpoch += 1
    root.active = true
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
    // `text` goes from here straight into the backend; nothing derived from it
    // is kept anywhere in this component. `checking` is derived from conv:
    // _apply("submit") is its single writer.
    root._apply("submit")
    f.submit(text)
    root.resetToken++
  }

  function cancelRequest() {
    const f = agent.flow
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
  // popping. Teardown is NOT on a timer guessing when the fade ended: the
  // view releases it from hideAnim.onFinished (a real edge), where the 200 ms
  // late-outcome grace is started. finishClose() then drops the state.
  function beginClose() {
    if (root.closing || !root.active) return
    // Legal by the guard above, so assigned directly rather than through
    // _apply: a failure here could only be the guard disagreeing with the
    // machine, and the guard is the one that decides.
    root.conv = PolkitTrace.apply(root.conv, { type: "begin-close", at: Date.now() })
    root.closing = true
  }

  // Called by the view at hideAnim.onFinished (or immediately when motion is
  // disabled). The 200 ms is a grace for late outcome signals - the backend
  // retires isActive before emitting them - NOT a guess at when the fade
  // finishes: by the time this runs the fade has already finished (POL-3/Q4).
  function noticeFadeFinished() {
    if (root.closing) closeTimer.restart()
  }

  function finishClose() {
    if (PolkitTrace.refused(root.conv, "close") === "") root._apply("close")
    // active before closing, so the view's closing=false edge cannot mistake
    // a normal teardown for a supersession and bring the card back.
    root.active = false
    root.closing = false
    clearMirroredState()
    // checking/attempts are derived from conv and are NOT written here:
    // conv.attempts is retained so `outcome()` can still report locked-out.
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

  // 200 ms grace for late outcome signals, started at hideAnim.onFinished.
  // It is NOT a "wait for the fade to finish" timer - the fade is already
  // over when this is armed. See noticeFadeFinished() and POL-3 / Q4.
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

  function handleAuthFailed(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    // _apply("rejected") is the single writer: it increments conv.attempts
    // (the `attempts` projection) and clears conv.checking.
    if (!root._apply("rejected")) return
    root.resetToken++
  }

  function handleAuthSucceeded(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
    root._apply("granted")
    root.beginClose()
  }

  function handleRequestCancelled(f, epoch) {
    if (!root.isCurrentFlow(f, epoch)) return
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
