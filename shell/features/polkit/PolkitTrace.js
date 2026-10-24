.pragma library

// Pure decision logic for the polkit feature: the authentication conversation
// as a state machine, the outcome an ended conversation resolves to, and why
// the prompt is not on screen.
//
// It is a library rather than part of the surface because the surface cannot be
// reached headlessly.
// `qs.features.polkit.Polkit` is a singleton that constructs a live
// `PolkitAgent`, whose constructor calls
// `polkit_agent_listener_register` - so importing the singleton from a probe
// would register a SECOND authentication agent on the user's live session,
// which is a side effect a unit test must not have. The view's root is a
// `Variants` of `PanelWindow`, which has no backend under
// QT_QPA_PLATFORM=offscreen. A `.pragma library` has no engine dependency, so
// every rule here can be executed by a probe that imports this file alone,
// which is the only way any of it is testable at all. No case under
// tests/shell/suites/ drives it today, so the rules are verified by reading
// this file.
//
// TWO INVARIANTS hold for everything below.
//
// 1. Nothing here can be given the field value. No function takes, reads or
//    returns anything derived from what a user typed into a PAM prompt.
//    `apply("submit", ...)` is the only event that corresponds to a user
//    pressing enter, and it accepts a timestamp and a sequence number and
//    nothing else - there is no parameter through which a response could
//    arrive. That is structural rather than a convention: there is no door.
//
// 2. Nothing here can be given a string a client chose. Every decision this
//    file answers is a fixed token from this file, a number or a boolean. The
//    one string it holds is the action id - the well-known bus name polkit
//    sent - and it is held because it is the one identifier that answers
//    "which app asked for this"; it is a name out of polkit's own vocabulary,
//    not free text, and nothing here interprets it. Everything else off the
//    wire is narrowed before it is stored: `ev.type` is matched against a
//    closed list and an event that is not on it is refused, `ev.by` collapses
//    to "user" or "daemon", and `ev.identities` is a count. The request cookie
//    is never held at all: it is polkit's own internal identifier, and no
//    rule here needs it.

// ---- the closed vocabularies ----------------------------------------------

// The attempts at which a conversation that ended without a verdict is called a
// lockout rather than a timeout.
//
// polkitd's own `try_first_pass`/`max_tries` accounting never reaches QML: the
// `PolkitAgentSession` reports only a boolean "gained authorization", and
// quickshell starts a fresh session after every rejection without asking how
// many have been made. So this bound is the SHELL'S, not polkit's, and the
// outcome that applies it says so. Three is chosen because it is where a reader
// stops calling it "a wrong password" and starts calling it "too many tries";
// it is a reporting threshold and nothing enforces it, because the backend owns
// the retry loop and there is no call in the API that ends it.
function lockoutAttempts() {
  return 3
}

// ---- the conversation ------------------------------------------------------

// A new conversation, with nothing asked and nothing answered.
function newConversation() {
  return {
    // `action` is the well-known bus name polkit sent ("org.freedesktop.halt")
    // and is the one identifier in this whole file that is safe AND useful: it
    // is exactly what answers "which app asked for this". It is stored here so
    // a later read can name the conversation without reaching back into the
    // flow, which by then may be a different object.
    action: "",
    // The action of the conversation this one replaced, and "" when it
    // replaced nothing. Non-empty is the superseded case.
    supersedes: "",
    identities: 0,
    // The three phases the dialog can be in. `waiting` is "a PAM turn is
    // outstanding", which is not the same as `checking`: the first is the
    // backend asking a question, the second is the shell waiting for the
    // answer to that question.
    active: false,
    closing: false,
    waiting: false,
    checking: false,
    // `turns` counts prompts issued, `submits` counts responses sent, and
    // `attempts` counts responses the backend rejected. All three, because they
    // come apart in exactly the cases that matter: a prompt that arrives with
    // no submit before it is a second turn the backend asked for on its own,
    // and a submit that never becomes an attempt is a response the daemon
    // answered with neither success nor failure.
    turns: 0,
    submits: 0,
    attempts: 0,
    // The terminal event, or "" while none has arrived.
    closedBy: "",
    // The last CONVERSATION event - prompt, submit, rejected, granted or
    // cancelled - and NOT the last event of any kind. `begin-close` and `close`
    // are the dialog leaving the screen, not the exchange finishing, so they do
    // not touch it. This is what separates "the conversation ended on a
    // rejected password" from "the conversation ended while a fresh prompt was
    // outstanding", and those are a denial and a timeout respectively.
    last: "",
    // Who cancelled, for `closedBy == "cancelled"`: "user" when the shell
    // asked, "daemon" when polkitd cancelled through its own cancellable.
    by: "",
    startedAt: 0,
    promptAt: 0,
    submitAt: 0
  }
}

// True when `type` does not apply to `s`, and false when it does. The reason
// is a fixed token, never a message, and `apply` returns null rather than a
// record for every one of them: an event the machine refuses is something the
// caller logs and does not perform, and a caller that ignored the refusal would
// be the bug this function exists to make visible.
function refused(s, type) {
  const c = s || newConversation()
  switch (String(type)) {
    case "request":
      // Always legal: a request is what starts a conversation, and one that
      // arrives mid-conversation is the superseded case rather than an error.
      return ""
    case "prompt":
      if (!c.active) return "no-conversation"
      return ""
    case "submit":
      if (!c.active) return "no-conversation"
      // The backend has not asked anything, or already has the answer to the
      // turn it asked about. Both are the guard in `submitPassword` refusing a
      // double submit, and both are worth saying so about.
      if (!c.waiting) return "no-prompt-outstanding"
      if (c.checking) return "already-checking"
      return ""
    case "rejected":
      if (!c.active) return "no-conversation"
      return ""
    case "granted":
    case "cancelled":
      if (!c.active) return "no-conversation"
      if (c.closedBy !== "") return "verdict-already-set"
      return ""
    case "begin-close":
      if (!c.active) return "no-conversation"
      if (c.closing) return "already-closing"
      return ""
    case "close":
      if (!c.active && !c.closing) return "not-closing"
      return ""
    default:
      return "unknown-event"
  }
}

// The next state, or null when `refused` names a reason. A new object every
// time rather than a mutation, so a caller that logs the old state and the new
// one cannot have them alias.
//
// `ev` is { type, at, action, identities, by }. `at` is a millisecond
// timestamp, `identities` a count, and the two strings are the well-known bus
// name and the word "user"/"daemon". `ev` carries NO response, NO prompt text
// and NO message: see invariant 1.
function apply(s, ev) {
  const c = s || newConversation()
  const reason = refused(c, ev && ev.type)
  if (reason !== "") return null

  const e = ev || {}
  const at = Number(e.at)
  const n = newConversation()
  // Carried across every event, because a rejected turn is the same
  // conversation as the turn that was rejected.
  n.action = c.action
  n.supersedes = c.supersedes
  n.identities = c.identities
  n.active = c.active
  n.closing = c.closing
  n.waiting = c.waiting
  n.checking = c.checking
  n.turns = c.turns
  n.submits = c.submits
  n.attempts = c.attempts
  n.closedBy = c.closedBy
  n.last = c.last
  n.by = c.by
  n.startedAt = c.startedAt
  n.promptAt = c.promptAt
  n.submitAt = c.submitAt

  switch (String(e.type)) {
    case "request":
      // A request while one is still active abandons the first. The backend
      // will not do this - it holds one flow at a time and queues the rest -
      // so a non-empty `supersedes` means the shell's own accounting went
      // wrong, or a config reload swapped the agent under a live request. Both
      // are the shape of a dangling polkit request.
      n.supersedes = c.active ? c.action : ""
      n.action = String(e.action === undefined || e.action === null ? "" : e.action)
      n.identities = Number(e.identities) > 0 ? Math.round(Number(e.identities)) : 0
      n.active = true
      n.closing = false
      n.waiting = false
      n.checking = false
      n.turns = 0
      n.submits = 0
      n.attempts = 0
      n.closedBy = ""
      n.last = ""
      n.by = ""
      n.startedAt = at
      n.promptAt = 0
      n.submitAt = 0
      return n
    case "prompt":
      // A turn is outstanding. `checking` clears here and nowhere else: the
      // failed-attempt loop runs submit -> rejection -> a fresh prompt, and
      // this is the one point in it where the record can leave the busy state
      // again. A conversation that moved on without asking again leaves the
      // dialog "checking" against a turn that no longer exists, and the
      // `submit` guard then refuses the next response as "already-checking".
      n.last = "prompt"
      n.turns = c.turns + 1
      n.waiting = true
      n.checking = false
      n.promptAt = at
      return n
    case "submit":
      n.last = "submit"
      n.submits = c.submits + 1
      n.waiting = false
      n.checking = true
      n.submitAt = at
      return n
    case "rejected":
      // The backend answers a wrong password by starting a fresh session on the
      // SAME flow object, so this is not a new conversation: the action, the
      // turn count and the identities all carry.
      n.last = "rejected"
      n.attempts = c.attempts + 1
      n.checking = false
      n.waiting = false
      return n
    case "granted":
      n.last = "granted"
      n.closedBy = "granted"
      n.checking = false
      n.waiting = false
      return n
    case "cancelled":
      n.last = "cancelled"
      n.closedBy = "cancelled"
      n.by = e.by === "user" ? "user" : "daemon"
      n.checking = false
      n.waiting = false
      return n
    case "begin-close":
      n.closing = true
      return n
    case "close":
      // The fade has played. `active` drops and the record is kept, because
      // the outcome is computed after this point and needs the turn
      // counts and the timestamps the record is holding.
      n.active = false
      n.closing = false
      n.checking = false
      n.waiting = false
      return n
    default:
      return null
  }
}

// ---- the outcome -----------------------------------------------------------

// What an ended conversation amounts to. This is the rule the whole file
// turns on: an authentication that was asked for and never answered is not an
// authentication, and the token says so rather than reporting a success that
// never happened or a failure nobody caused.
//
// Order matters and is the argument:
//   * an explicit terminal event is what it says, first and without
//     qualification. A grant is a grant whatever else happened.
//   * otherwise, if the last exchange was a rejection AND at least one turn
//     was issued, the request ended on a wrong password. The backend normally
//     answers a rejection by opening a new session, so a conversation whose
//     LAST event is a rejection is one whose retry loop was taken away - and
//     past the attempt bound that is a lockout rather than a denial, which is
//     why the bound is tested here and not in a separate branch.
//   * a request that was never asked a single question is `no-prompt`: the app
//     is waiting and the user was never asked, which is the most confusing
//     state there is.
//   * no verdict otherwise is a timeout. polkitd delivers a timeout to the
//     agent through the same cancellable it uses for its own cancellations, and
//     quickshell's handler is `cancelAuthentication(request)` with no reason
//     attached, so a timeout and a daemon-side cancel are NOT separable from
//     QML. The split this file does make is the one the record supports: a
//     turn the user never answered and a turn they answered and then abandoned
//     are two different reader problems, and the outcome token folds them
//     together into one timeout.
function outcome(s) {
  const c = s || newConversation()
  if (c.closedBy === "granted") return "granted"
  if (c.closedBy === "cancelled") return "cancelled"
  // A conversation that was asked and answered at least once, and whose LAST
  // exchange event was a rejection: the backend tried again and the request
  // ended there. From the app's point of view it is a denial.
  if (c.last === "rejected" && c.turns > 0) {
    return c.attempts >= lockoutAttempts() ? "locked-out" : "denied"
  }
  // Asked nobody, ended with no verdict: a request arrived, the dialog opened,
  // and no PAM turn was ever issued. The most confusing state there is - the
  // app is waiting and the user was never asked.
  if (c.turns === 0 && c.closedBy === "") return "no-prompt"
  // No verdict, a turn outstanding or a submit in flight, short of the
  // attempt bound: a timeout.
  if (c.attempts >= lockoutAttempts()) return "locked-out"
  return "timed-out"
}

// ---- why nothing is on screen ---------------------------------------------

// Why the request is not showing a prompt, as a fixed token.
//
// Precedence is the argument, and `session-locked` is first because it is the
// one that never resolves on its own: the view's `visible` binding is
// `Polkit.visible && !Lockscreen.locked`, so a request that lands while the
// session is locked stays pending with nothing drawn and nothing said. The app
// waits, polkitd's clock runs down, and the user never learns there was a
// prompt. That is the "no prompt appeared but the request is pending" state,
// and it is a distinct token rather than the absence of one.
//
//   requested   a request is pending in the singleton
//   locked      Lockscreen.locked
//   screens     how many screens Ui considers real
//   primary     whether a primary screen was found among them
//   closing     the exit fade is playing
//   visible     the window's own `visible`
// True when the prompt SHOULD be on screen: a request is pending, nothing is
// suppressing it, and there is a screen to put it on.
//
// This is the one decision in this file that must never read the window's
// visibility back, because the window's `visible` is bound to it. A binding
// that reads its own output is a binding loop, and its symptom is not an error
// - it is a window rendering a card it believes is hidden, which is exactly the
// dead prompt this function exists to prevent.
//
// `suppression()` below answers the same question AND takes the window's
// visibility as its last input, because "a request is pending and the window is
// not up" is a diagnostic worth naming. So there are two, deliberately: this one
// is the cause, that one is the report. The original code had a single binding,
// `visible: Polkit.visible && !Lockscreen.locked`, which had no such input and
// could not loop.
function shouldShow(cfg) {
  const c = cfg || {}
  if (c.requested !== true) return false
  if (c.locked === true) return false
  if (!(Number(c.screens) > 0)) return false
  if (c.primary !== true) return false
  if (c.closing === true) return false
  return true
}

function suppression(cfg) {
  const c = cfg || {}
  if (c.requested !== true) return "none"
  if (c.locked === true) return "session-locked"
  if (!(Number(c.screens) > 0)) return "no-screen"
  if (c.primary !== true) return "no-primary-screen"
  if (c.closing === true) return "closing"
  if (c.visible === true) return "shown"
  return "window-hidden"
}

