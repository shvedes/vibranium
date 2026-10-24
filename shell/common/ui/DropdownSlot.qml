pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Standard in-flow dropdown slot shared by every surface that unfolds
// content under a row: the settings menu (ctrl-i description, select
// dropdowns, inline editors, expandable bodies) and the app launcher
// (ctrl-i description, delete confirmation). One motion everywhere - the
// height eases open/closed on the shared Glide curve while the content
// fades in/out - so a dropdown reads the same on every surface.
//
// CONTENT: inline content is a single child that fills the slot's width
// and reports its own height through the host. Columns size themselves
// like any row chrome; a Loader child keeps the deferred pattern
// (Menu.Entry's expandSlot) and can use `closing` to stay alive through
// the close animation, or wait for closeFinished to release on the
// terminal edge.
//
// NESTED CONTENT: `nestedContent` is the same deferral, owned here so a
// consumer with an expensive body does not hand-roll the gate per
// dropdown. The slot constructs the component when it opens, keeps the
// instance through the close animation and releases it on the same
// terminal edge closeFinished marks, so a closed slot owns no controls at
// all: a per-row delegate that would build a field and a button row for
// every row in a list builds them for the one row that is open. The gate
// is `open || closing`, the same rule the hand-written Loader follows, so
// an open slot's geometry, motion and item lifetime are unchanged.
// `nestedItem` is the live instance (null while released) for a consumer
// that drives the body imperatively - focus, reveal, reset - instead of
// holding an id into a tree that may not exist; watch it, or the body's
// own Component.onCompleted, for a body constructed after the state that
// needs it flipped.
//
// The body is created into the content host, not into a Loader: a Loader
// takes over the size of the item it loads, which would silently widen an
// inset body (a Column at `width: parent.width - 2 * Ui.m`) to the full
// slot width. Parented to the host instead, a gated body sizes itself
// exactly like an inline one and is the host's last child.
//
// GEOMETRY: the height is a pure linear sum of topGap plus content height
// plus `gap`, so a parent's height tracks each slot's animation 1:1 - the
// close lands exactly when the slot does, no end-of-animation pop. Stacked
// slots anchor at 0 under the previous slot's bottom and leave topGap at 0,
// since the slot above already ends in its own gap; standalone slots
// unfolding straight under a row line set topGap to Ui.m and anchor at 0,
// so the padding above rides the same tween as the content below.
//
// MOTION: `MotionPolicy.enabled` decides whether a slot eases at all, here
// and for every surface, because the one other thing that can suppress the
// tween - a host landing the slot for an unfold that resizes its region -
// is a per-call-site verdict, not a rule. A dropdown whose region does not
// have to grow (there is room for it, or the rows below slide down to
// reveal it) was never landed, so it eased on while its twin in a shorter
// window snapped: the same control animated or did not depending on the
// size of the screen it was opened on. Whether the shell moves is the
// user's setting; where the room is, is the host's business.
Item {
  id: root

  // Drives both the height and the fade.
  property bool open: false
  // Breathing room below the content while open.
  property real gap: Ui.m
  // Breathing room above the content while open, owned here rather than by
  // the consumer's anchor margin so the row sums one animated height instead
  // of a height plus a snapping margin. Standalone slots unfolding straight
  // under a row line set Ui.m; slots stacked under another slot leave 0,
  // since the slot above already ends in its own gap. Anchors stay at 0 -
  // the padding rides inside the height tween, so open and close glide as
  // one motion with no end-of-animation pop.
  property real topGap: 0

  // Suppress this slot's motion and put it where it is going, now. A host
  // sets it when the slot's unfold is about to resize the region it lives
  // in: the region has already reached its destination, so a slot still
  // easing into it reads as a second, unrelated motion arriving after the
  // one the user asked for.
  //
  // LATCHED for the whole open AND close, because the region stops growing
  // the moment the slot starts closing - a collapse decided by a flag that
  // has already fallen would ease while the region it belongs to is already
  // back at rest, which is the same seam in the other direction. The host
  // owns both edges: it raises this for an unfold and clears it before the
  // next one, because only it knows whether that next unfold resizes the
  // region too. `land()` is what actually applies it; assigning the flag
  // alone would not, see below.
  property bool settle: false

  // True while a just-closed slot is still animating away. Consumers
  // with deferred content (Loaders) keep it alive until the close
  // animation finishes, then unload.
  readonly property bool closing: root._closing

  // The close reached its end: `closing` is false again and the whole fade
  // is over, so a consumer holding deferred content may release it here
  // instead of watching `closing`. Emitted once per close that runs to the
  // end; a reopen inside the grace window cancels the pending emission.
  // The grace timer is parented to the slot, so a destroyed slot takes it
  // down with it.
  signal closeFinished

  // Deferred body. Assign the content as a Component instead of declaring
  // it inline: the slot builds it on open, keeps it through the close fade
  // and releases it when the grace window ends, so a closed slot owns no
  // controls. Inline content (the default property) is still the cheap form
  // and keeps working unchanged.
  property Component nestedContent: null

  // The live body, null while the slot holds none. `var`, not Item: the
  // Component is the consumer's, and the slot does not know (nor need to
  // know) which type comes out of it.
  readonly property var nestedItem: root._nested

  // The body instance the gate holds, private; `nestedItem` is the public
  // view of it. Starts empty, so a slot never has a body before its first
  // open, whatever the consumer bound `open` to.
  property var _nested: null

  // Create, release, or do nothing. The verdict is read here rather than
  // cached in a derived property: this runs from the change handlers of
  // `open` and `closing`, and a binding on those re-evaluates inside the
  // notification, where it still reports the previous value.
  function _syncNested() {
    const wanted = root.nestedContent !== null && (root.open || root.closing)
    if (wanted) {
      if (root._nested === null) {
        root._nested = root.nestedContent.createObject(contentHost)
        // The deferral this primitive exists for: a closed slot owns no
        // controls at all, so a per-row delegate builds its body for the one
        // row that is open rather than for every row in the list.
      }
    } else if (root._nested !== null) {
      root._nested.destroy()
      root._nested = null
    }
  }

  height: root.open ? root.topGap + contentHost.height + root.gap : 0
  clip: true
  opacity: root.open ? 1 : 0

  // The height this slot is heading for, readable the instant it opens:
  // contentHost has already measured the content, and the Behavior below
  // is only the journey from 0 to this. Consumers that must place
  // something against a row mid-unfold (the list's reveal, see
  // List.rowSettledHeight) need the destination, not the current frame.
  readonly property real settledH: root.open ? root.topGap + contentHost.height + root.gap : 0

  // Unfold pacing: constant velocity (Ui.slotVpx) between the shared
  // duration floor and cap, derived from the unfolded height - top gap,
  // content and gap alike - never a hardcoded per-slot number. Close uses
  // the same pacing off the same height, so both directions match; the
  // grace timer below takes the longer of this and the fade, so deferred
  // content never unloads mid-close on a slot of any height.
  readonly property int slotMs: Math.max(Ui.fastMs, Math.min(Ui.slowMs,
    Math.round((root.topGap + contentHost.height + root.gap) / Ui.slotVpx * 1000)))

  // True while the slot is being held at its destination because its unfold
  // resizes the region. Not a binding: `settle` is raised imperatively by the
  // host (see the note on it), and a binding here would be read once and
  // then re-evaluated at a moment the Behavior has already passed.
  property bool _held: false

  // Put the slot at its destination and keep it there for the rest of this
  // unfold.
  //
  // The flag goes up FIRST and synchronously; the value is written on the next
  // turn. Both halves are load-bearing and for different reasons.
  //
  // The flag, synchronously: QQuickBehavior::write reads its own `enabled`
  // when the property is written and takes a bypass branch straight to the
  // value when that is false. It reads the plain member, not a re-evaluated
  // binding, so a host that raised this from a change handler would always
  // lose the race - the slot's height is written during the same propagation
  // that publishes the verdict, and the Behavior has already armed by the
  // time any binding chain re-runs. There is no stop() to call instead: the
  // declared Glide is a template Qt clones per trigger (see the note on both
  // Behaviors) and QQuickBehavior itself has none.
  //
  // The value, deferred: writing `height` here would be a write INTO the
  // evaluation that produced the verdict. The row's settled height is the
  // claim (List.revealNeedH), the claim is what calls this, and the write
  // would travel straight back up it - a loop through
  // height -> revealNeedH -> MenuPanel._latchClaim, which Qt answers by
  // dropping the value. `callLater` puts the write in the next event-loop
  // turn, still before the next frame is rendered, so the tween is disabled
  // in time and the slot is never seen part-way open.
  function land() {
    if (root._held) return
    root._held = true
    root.settle = true
    Qt.callLater(root._writeLanded)
  }

  function _writeLanded() {
    height = root.open ? contentHost.height + root.gap : 0
    opacity = root.open ? 1 : 0
  }

  // Release the hold, so the NEXT unfold on this slot can ease. The host
  // calls it when the current unfold is over - `_held` is the gate both
  // Behaviors read, so leaving it set would freeze the slot for good rather
  // than for the one dropdown.
  function release() {
    root._held = false
    root.settle = false
  }

  // Whether this slot eases. The policy alone decides, narrowed by the hold:
  // a slot a host has landed is not a slot with a slower tween, it is a slot
  // already where it is going. The two Behaviors below are the only readers,
  // and both are gated rather than shortened, so with the switch off the value
  // is written straight to the target - the same landing, minus the motion.
  readonly property bool motion: MotionPolicy.enabled && !root._held

  Behavior on height {
    enabled: root.motion
    Glide { duration: root.slotMs; easing.type: Easing.OutCubic }
  }

  Behavior on opacity {
    enabled: root.motion
    Glide { duration: Ui.normalMs; easing.type: Easing.OutCubic }
  }

  // The unfold, per frame. Both the height and the fade are driven by
  // animation clones that carry no signal, so the frame loop on the slot is
  // the only place the curve is legible - and the two do not land together,
  // which is the reason the grace timer below exists.

  default property alias content: contentHost.data

  // Width is anchor-driven so `width: parent.width` bindings inside the
  // content keep resolving to the slot's width; height mirrors whatever
  // the content reports, offset by topGap so the padding above rides the
  // same tween as the content below. A gated body lands here too, so it
  // measures itself against the same width an inline one does.
  Item {
    id: contentHost

    anchors.left: parent.left
    anchors.right: parent.right
    y: root.topGap
    height: contentHost.childrenRect.height
  }

  property bool _closing: false

  // Keeps the fade-out visible: deferred content must survive a little
  // longer than the animation itself, and the animation is whichever of
  // the two runs longest. The height tween is paced by slotMs, the opacity
  // tween is the fixed Ui.normalMs, and slotMs is floored at Ui.fastMs -
  // so a short slot (content height plus gap under the floor) fades out
  // for longer than its height takes to land, and a grace window derived
  // from slotMs alone would clear `closing` mid-fade and tear the deferred
  // content out of a slot that is still visible. A property, not a child
  // - the default property routes children into the content host.
  property Timer closeGrace: Timer {
    interval: Math.max(root.slotMs, Ui.normalMs) + 20

    onTriggered: {
      // The terminal edge. Everything a consumer defers on close is released
      // here, so the interval and what it released travel together: a body
      // that outlives its grace window and one torn out mid-fade look
      // identical without them.
      root._closing = false
      root.closeFinished()
    }
  }

  onOpenChanged: {

    if (root.open) {
      root._closing = false
      root.closeGrace.stop()
    } else {
      root._closing = true
      root.closeGrace.restart()
    }
    root._syncNested()
  }

  // The terminal edge: `closing` clearing is the release point. It also
  // clears on a reopen inside the grace window, where `open` is true again
  // and the body simply stays.
  onClosingChanged: {

    root._syncNested()
  }

  // A content swap is a release plus a create - the held body belongs to
  // the component that is no longer assigned, and `_syncNested` only
  // creates when the slot holds nothing.
  onNestedContentChanged: {
    if (root._nested !== null) {
      root._nested.destroy()
      root._nested = null
    }
    root._syncNested()
  }

  Component.onCompleted: {
  }

  Component.onDestruction: {
  }
}
