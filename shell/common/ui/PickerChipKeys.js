.pragma library

// The key mapping shared by the two mixer picker chips (DeviceRow's profile
// chip and StreamRow's route chip). Both chips answered the same five keys
// with the same verb: Up/Down open the list and step the highlight, Return,
// Enter and Space open it. The one thing that must not drift is WHICH key
// means WHICH step, so that table lives here.
//
// What stays at each site: the guard (`profilesReadable` in DeviceRow,
// `pickable` in StreamRow), the accessible name/description, the tooltip and
// the click behaviour. This module accepts the event, the Qt object (passed
// as DATA, so the library imports no Qt and stays headlessly drivable like
// NavKeys.js), and the two actions the chip already owns.
//
// No Escape here on purpose: a chip that swallowed it would stop it reaching
// the window's own handler and Escape would no longer close the mixer. No
// WheelHandler either: a wheel over a chip is a scroll of the row's body,
// not a per-notch write to the audio server.

// The action a key names, or null when it names none. `step` is -1 for Up,
// +1 for Down, 0 for "open only".
function action(key, codes) {
  if (!codes) return null
  if (key === codes.down) return { open: true, step: 1 }
  if (key === codes.up) return { open: true, step: -1 }
  if (key === codes.returnKey || key === codes.enter || key === codes.space)
    return { open: true, step: 0 }
  return null
}

// Full key handler minus the site's guard. Returns true when the event was
// claimed, so a caller can still layer behaviour on an unclaimed key.
function handle(event, qt, open, step) {
  if (!event || !qt) return false
  const a = action(event.key, {
    down: qt.Key_Down,
    up: qt.Key_Up,
    returnKey: qt.Key_Return,
    enter: qt.Key_Enter,
    space: qt.Key_Space
  })
  if (a === null) return false
  event.accepted = true
  if (typeof open === 'function') open()
  if (a.step !== 0 && typeof step === 'function') step(a.step)
  return true
}

if (typeof module !== "undefined") {
  module.exports = { action: action, handle: handle }
}
