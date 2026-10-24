pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import qs.common

Singleton {
  id: root

  readonly property bool enabled: HyprlandSettings.value("hypr.animations.enabled") === true

  // The setting itself flipping is the one event here that is not a
  // consequence of something else asking, so it gets its own line: every
  // other motion line in the shell is downstream of this one, and a run
  // where nothing moved has to be able to show the switch rather than
  // infer it from an absence.

  // The one place that turns a requested duration into a runnable one. A
  // NumberAnimation has no `enabled` member to switch off, so a primitive
  // that wants to honor the policy from the inside has to carry the gate in
  // its duration, and 0 is the only value that ends the tween in the tick it
  // starts - the same landing the Behavior applies when it is disabled, so
  // the value still arrives and only the motion is gone.
  //
  // A consumer that assigns `duration:` on an instance replaces the binding
  // this call produced, so such a site has to gate its Behavior with
  // `enabled: MotionPolicy.enabled` instead.
  //
  // Every duration in the shell passes through here, so this is the cheapest
  // place to answer "are animations on at all": one line per tween carrying
  // both what was asked for and what was granted, and a granted 0 is the
  // policy doing its job rather than a missing line. The site is gated
  // because a duration binding re-evaluates on every construction of every
  // animation, which is per frame for anything a tween is re-aiming.
  function duration(ms) {
    const granted = root.enabled ? ms : 0
    return granted
  }
}
