// Shared backend-readiness grace (features/bar).
//
// BlueZ and NetworkManager assemble their object graphs after the bar is
// already up, so an empty report at construction means "not reported yet",
// not "no backend". Painting that as a fault flashes on every boot. One
// bounded deadline retires the grace; a live edge retires it sooner when the
// backend has one. Pure JS, pragma library, no Qt imports: the decision is
// unit-drivable and the one value cannot drift between the two modules.
.pragma library

// The single deadline, in ms. Both modules' one-shot Timers bind to this.
var DEADLINE_MS = 2000

// True while a backend report is still expected: no live edge has arrived and
// the deadline has not elapsed. `edge` is a real readiness signal when the
// backend publishes one; pass false when no stable edge survives its object
// assembly (Network), leaving the deadline as the only retire. `expired` is
// published by the caller's own one-shot Timer.
function pending(edge, expired) {
  return !edge && !expired
}
