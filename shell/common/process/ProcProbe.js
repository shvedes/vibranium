.pragma library

// Liveness of one owned Process, in the form every spawn watchdog in the tree
// asks for it. `running === true` if the child is live, otherwise a process id
// above zero - the fallback is what separates "never had one" from "had one and
// lost it", because a child that was never spawned and one that has already
// exited both report `running === false`.
//
// Both reads are guarded: an unusable handle answers false rather than throwing
// into a watchdog that cannot express the difference. `null`, `undefined` and a
// destroyed Process all land there.
//
// One copy, because the question has one answer. Exec, ProcessJob and the two
// owned bus monitors in Inhibitor each carried this probe inline, and a probe
// that drifts per copy is a watchdog that fires on a live child or never fires
// on a dead one.
//
// What this cannot do is observe a spawn. The Process type exposes no error
// signal, and a property poll cannot separate an unresolvable argv[0] from a
// child that ran and finished inside the first tick - both read
// `running=false, processId=null`. Only `started` confirms a spawn, and the
// absence of that confirmation is observable solely as a deadline expiring.

/**
 * Whether `proc` is a live child.
 *
 * @param {object} proc A Quickshell.Io Process, or any handle exposing
 *                       `running` and `processId`.
 * @returns {boolean} false for a null, undefined, or destroyed handle.
 */
function alive(proc) {
  if (proc === null || proc === undefined) return false
  try {
    if (proc.running === true) return true
  } catch (ignored) {
    return false
  }
  try {
    const pid = Number(proc.processId)
    return isFinite(pid) && pid > 0
  } catch (ignored) {
    return false
  }
}