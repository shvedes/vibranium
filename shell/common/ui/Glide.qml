pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Standard number tween: Ui.fastMs on the shared OutCubic curve. Drop-in
// for `Behavior on <number>` blocks; override duration per use.
NumberAnimation {
  // MotionPolicy is the only global motion switch, and the primitive is
  // where a consumer gets it without asking: a site that does not repeat
  // the check on its own Behavior is covered by this binding.
  duration: MotionPolicy.duration(Ui.fastMs)
  easing.type: Easing.OutCubic

  // There is no per-frame tick here, and the reason is the type rather than
  // an omission. `NumberAnimation` exposes no `currentValue` and no
  // `currentValueChanged`: it derives from QQuickPropertyAnimation, which
  // derives from QAbstractAnimation, not from the QVariantAnimation that
  // owns those two. An `onCurrentValueChanged` handler is a LOAD error on
  // this type, not a warning, and `currentTimeChanged` is the same. The
  // animated value is only ever readable off the target's own property.
  //
  // Sampling it per frame from here needs a second moving part - a Timer
  // reading `target[property]` for the tween's lifetime, which this type
  // cannot host (it has no default property, so it cannot parent one). The
  // tick therefore lives where the frame is: the components that declare
  // `Behavior on <p>` and watch their own property change, which is driven
  // by Qt's own frame loop and costs nothing when the scope is off.

  // A stopped animation keeps its target. The property it drove stays held
  // for the rest of the owner's life - a one-shot tween keeps a reference to
  // an item that has already been closed, moved, or repurposed, and only a
  // new target or the animation's own destruction drops it. Releasing on
  // stop is what makes a stopped tween leave nothing behind.
  //
  // This is inert in the role every use site in the tree spells it,
  // `Behavior on <p> { Glide {} }`: Qt runs a clone of a declared animation,
  // so the declared instance is a template that never receives a target and
  // never runs, and Behavior re-points its clone at the property on every
  // trigger regardless.
  //
  // THE REUSE CAVEAT, for an owner that drives this primitive itself
  // (declares `target:` and calls start()/restart()). `target = null` is an
  // imperative assignment, and assigning over a declared binding REMOVES that
  // binding. So the release is exactly right for a one-shot tween and exactly
  // wrong for one that is driven more than once: after the first stop there is
  // no binding left to re-establish, and every later restart() runs against
  // nothing - the value does not move, and the run ends immediately, which
  // also fires any onStopped the owner hangs its completion on. Measured on the
  // slide shape, driven three times: with the hand-back the value returns to 0
  // on the second drive, without it the value is still sitting at its offset.
  //
  // So an owner that reuses this instance must hand the target back at the top
  // of its own drive function, next to the `from`/`to` it is already setting:
  //
  //   function arm(offset) {
  //     tween.target = theItem   // the release above dropped this binding
  //     tween.from = offset
  //     tween.to = 0
  //     tween.restart()
  //   }
  //
  // Nothing is held between runs, which is the point of the release - a
  // one-shot owner pays nothing for it and a reusing owner pays one line.
  onStopped: {
    target = null
  }
}
