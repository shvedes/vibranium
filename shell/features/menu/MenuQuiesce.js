.pragma library

// The quiesce handshake for motionless row installs, as a pure state machine.
//
// WHY IT EXISTS. A plain array is this panel's row model, and two assignments
// in a row - back to back while the view is still applying the first - can
// strand delegates: the children of the old set stay visible under the new one
// and two rows read as overlaid in one slot. Healthy loops apply within the
// gaps the install debounce leaves; a starved loop serializes instead of
// corrupting. The panel therefore notes every structural change the view
// reports after a motionless write and refuses the next one until the previous
// has settled (or the bounded wait runs out, so typing can never freeze).
//
// THE RULE IS PURE. The panel owns the four values - armed, events, seen and
// the arm timestamp - as reactive properties; this module only decides what
// they become. Keeping it here is what makes the timing rule testable without
// a shell: the panel's own copy could only be observed by driving a live
// ListView across event-loop turns.

// A gate that is not armed: the next write may land.
function idle() {
  return { armed: false, events: 0, seen: 0, armedAt: 0 }
}

// Armed at the write that just landed. `now` is the caller's clock in ms.
function armed(now) {
  return { armed: true, events: 0, seen: 0, armedAt: Number(now) || 0 }
}

// One structural change reached the view while a motionless write was
// settling. An idle gate counts nothing: there is no write to protect.
function note(state) {
  if (!state || state.armed !== true) return state
  return {
    armed: true,
    events: state.events + 1,
    seen: state.seen,
    armedAt: state.armedAt
  }
}

// Whether the next motionless write may land, and the state it leaves behind.
// `ready` is true when nothing is outstanding, when the write already
// outstanding has quiesced (no structural churn since the last check), or when
// the bounded wait has run out. A held check records what it has seen, so the
// same churn is not counted twice.
function check(state, now, waitMs) {
  if (!state || state.armed !== true) return { ready: true, state: state || idle() }
  const ms = Number(now) || 0
  const wait = Number(waitMs) || 0
  if (state.events === state.seen || ms - state.armedAt > wait)
    return { ready: true, state: idle() }
  return {
    ready: false,
    state: {
      armed: true,
      events: state.events,
      seen: state.events,
      armedAt: state.armedAt
    }
  }
}
