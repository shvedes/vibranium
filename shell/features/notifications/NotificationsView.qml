pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.notifications
import "NotificationsLib.js" as NotificationsLib

// The notification pile. A full-screen transparent layer-shell window with
// the cards parked in one corner, anchored on all four edges so the pile has
// the whole screen to position itself in rather than a window sized to the
// cards.
//
// Three things about this window are deliberate:
//
//   - `keyboardFocus: None`, always. Nothing in a card wants keys: the only
//     thing that ever did was an inline reply field, and inline replies are not
//     offered. See the property for why `OnDemand` was worse than it sounds.
//   - the input region follows the pile, not the window. A full-screen
//     layer-shell surface that takes input over its whole rectangle would
//     swallow every click on the desktop underneath it; `mask: Region { item:
//     pile }` claims exactly the cards and passes everything else through.
//   - the window is never unmapped between notifications. `specs/04` measured
//     that gating a window's loading on its visibility unmaps and re-maps it,
//     and the pile is the last surface that wants that: it is up in bursts and
//     down between them.
PanelWindow {
  id: win

  screen: Ui.primaryScreen ?? Quickshell.screens[0] ?? null
  // The mapping rule lives with the rest of the pile's policy (Notifications):
  // a card is up, including the exit fade of the last one.
  visible: Notifications.surfaceVisible
  color: "transparent"
  // No `clip` here, and there cannot be one: this root is a Window, and `clip`
  // is an Item property. Anything that needs clipping goes on `pile`, which is
  // the Item the cards actually live in.
  exclusionMode: ExclusionMode.Ignore
  exclusiveZone: -1
  anchors.top: true
  anchors.bottom: true
  anchors.left: true
  anchors.right: true

  WlrLayershell.namespace: "vibranium:notifications"
  // One level below the modal overlays (the menu family in
  // common/ui/OverlayWindow.qml), so an open menu covers the cards instead
  // of the cards drawing over the menu's dim.
  //
  // Two surfaces on one level are ordered by which of them the compositor
  // saw last, and this window is destroyed and rebuilt on every burst of
  // notifications, so a pile sharing a level with the menus would land
  // above a menu that was opened before the notification arrived. Separate
  // levels are the only order that does not depend on that.
  //
  // The cost of the level is the fullscreen fade: Hyprland fades the whole
  // Top layer when a window goes fullscreen, so the pile goes with it.
  WlrLayershell.layer: WlrLayer.Top
  // Never takes the keyboard. `OnDemand` reads as the polite choice - "this
  // surface may have the keyboard" - but a compositor is free to grant it the
  // moment the surface maps, and this surface maps every time a notification
  // arrives. So a pile on `OnDemand` took the keyboard out from under whatever
  // the user was typing into, once per notification, which is the whole reason
  // this is a constant `None`: nothing in a card wants keys, since inline
  // replies are not offered (`Notifications.qml`, `inlineReplySupported`).
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  // The pile's margin: the gap to the right screen edge AND the gap to the
  // bar it is docked to. One token for both, so the two edges cannot drift
  // apart - a corner pile with a wider gap on one side than on the other reads
  // as two placements rather than one.
  //
  // Ui.s, the tightest step of the spacing scale: a corner pile wants to sit
  // close to its corner, and the space around the stack is one small measure
  // on every side rather than a border drawn around it.
  readonly property real margin: Ui.s

  // Cards are 330px wide, clamped to the screen: a corner pile has to read as
  // a corner pile, and a card wider than the screen is a card with no corner.
  // Narrower than the 360 this started at, because a notification is a line of
  // title plus a line or two of body, and at 360 the body wrapped early enough
  // that most notifications spent a line on nothing.
  readonly property real cardWidth: Math.max(200, Math.min(330, win.width - 2 * win.margin))

  // Whether the pile has been placed at its dock yet. The box's tween is gated
  // on this so the first layout lands rather than growing up from nothing; see
  // the Behavior on `pile.height`.
  property bool placed: false

  // The pile is docked to the bar side. Which side that is comes from the
  // layout the bar publishes, not from a setting of this feature's own: a top
  // bar puts the pile under the bar, a bottom bar puts it above, and no bar
  // (or a hidden one) leaves the default, top. The two insets are written as
  // one question rather than two, so the pile cannot end up docked to the top
  // while its bottom inset clears a bar it is not next to.
  //
  // An open island on this screen adopts the dock (see islandSharing
  // below): the pile parks past the island's far edge instead of over the
  // island, so a notification never covers the card and a click on either
  // one lands where it looks. Not held until the island closes - shifted
  // past it - and following resizes live, because the edge below is plain
  // data republished on every park.
  readonly property real barDock: (DesktopLayoutState.barEnabled ? DesktopLayoutState.barHeight : 0) + win.margin
  // The island host serving this screen, if any: one IslandHost per bar
  // view registers itself in DesktopLayoutState under its screen name.
  // The island record for this screen ({showing, top, bottom}) or null.
  // Fresh object per publish, so any host move re-fires this chain by
  // value: opens shift the pile, closes return it, resizes glide it.
  readonly property string pileScreen: win.screen ? String(win.screen.name || "") : ""
  readonly property var islandRect: DesktopLayoutState.islandFor(win.pileScreen)
  // An open island on this screen shifts the pile past its far edge.
  // Anything else is the bar dock alone: records carry showing=false after
  // close, and a null record (no island, torn-down host) is the same answer.
  readonly property bool islandSharing: win.islandRect !== null && win.islandRect.showing === true
  // The island's far edge in pile coordinates (same screen, so the same
  // full-screen geometry): the bottom edge for a top dock, the top edge
  // mirrored through the window height for a bottom dock.
  readonly property real islandEdge: {
    if (!win.islandSharing) return 0
    if (Notifications.atTop) return Number(win.islandRect.bottom) || 0
    return win.height - (Number(win.islandRect.top) || 0)
  }
  readonly property real topInset: Notifications.atTop
    ? NotificationsLib.pileDock(win.barDock, win.islandSharing && Notifications.atTop, win.islandEdge, win.margin)
    : win.margin
  readonly property real bottomInset: Notifications.atTop
    ? win.margin
    : NotificationsLib.pileDock(win.barDock, win.islandSharing && !Notifications.atTop, win.islandEdge, win.margin)

  // The pile's box, not a Column of cards. A Column would lay the cards out,
  // and a Column assigns y itself: its Behaviour never sees that assignment and
  // it re-asserts it on every polish, so the slide the requirement asks for
  // cannot be built on one (measured on this build - see NotificationCard's y).
  // This holds the cards' box and nothing else; Notifications.yOf() places each
  // card inside it.
  Item {
    id: pile

    width: win.cardWidth
    // The dock, as one `y`, and a BINDING like every other piece of geometry in
    // this tree. That is the whole answer to "the dock is wrong after a resize":
    // a binding re-evaluates on every input it reads, so the box cannot fall
    // behind its own dock.
    //
    // A `Connections` on three named signals - the pile, the dock side, and
    // the surface visibility - is the alternative, and it cannot carry this
    // dock. `dockY` reads the
    // window's own height, the bar's published height, and whether the bar is
    // enabled at all; a listener set that names the pile, the dock side and
    // the surface visibility hears none of the last two, so any change
    // to the bar's height (`Ui.fontScale` follows the bar font setting, and the
    // bar's height follows it) moves the dock out from under a box that had no
    // idea it should move. Enumerating the triggers by hand is what makes it
    // hard: there is no correct list, because the list is whatever the
    // expression reads.
    //
    // Anchoring top or bottom instead would be the other way to say this, and a
    // bool-typed anchor on a type qmllint cannot resolve is a diagnostic about a
    // member the panel actually has.
    //
    // At the bottom dock it is anchored by its bottom edge, and the edge is the
    // window's height less the inset - so `y` is written against the box's own
    // `height` rather than against `pileHeight()` again. That is what makes the
    // bar edge the box's bottom edge at every frame rather than only once the
    // pile has stopped moving: `y + height` reduces to `win.height -
    // bottomInset`, which no animation state can change. Written the other way -
    // two bindings each naming `pileHeight()`, one on `y` and one on `height` -
    // the sum only holds while both animations are in step from a settled
    // start, and a pile that is still moving when a new card lands breaks that:
    // measured at the bottom dock, a flush landing on the tail of a dismissal
    // drifted the edge through 410.8, 575.7 and 694.3 on its way back to 860,
    // which left the whole pile floating clear of the bar for the best part of
    // a second.
    y: Notifications.atTop ? win.topInset : win.height - win.bottomInset - height

    // Arm the slide once, on the first layout.
    //
    // An Item's height starts at 0, so a Behavior armed at construction would
    // animate the box up from nothing to its first card on every notification
    // the shell shows - measured at 919.5 settling to 754, which is a
    // card-height drop-in. The first layout is a placement, not a change of
    // arrangement; this only disarms the tween afterwards, so the SECOND change
    // - and every change after it - is the one that animates.
    function place() {
      win.placed = true
    }

    // The box has to move on the same curve as the cards inside it, or the two
    // disagree and the pile appears to jump.
    //
    // Traced at the bottom dock. The box's height is `pileHeight()`, so its
    // target moves by one card height every time a card is added or removed.
    // Left to snap, that target is reached in ONE FRAME while the cards inside
    // glide over `Ui.fastMs`, and the two motions do not cancel:
    //
    //   removing a card from three:  the box's height drops 98px instantly
    //   the card that was below it:   its own y 196 -> 98, i.e. -98px smoothly
    //   so its ABSOLUTE position went 950 -> 1048 in one frame and then back
    //   to 950 over the tween - down across the bar and up again
    //
    // That is the "jumps over the bar, then goes up again" this fixes, and it
    // is invisible at the top dock: there the box's y is the constant
    // `topInset`, so only the height changes and no card's position depends on
    // it.
    //
    // The box's own HEIGHT is the one animated property, and it is animated rather
    // than left to snap because that is what lets the pile's bottom edge stand
    // still.
    //
    // The defect, measured at the bottom dock. The box's y is anchored by its
    // bottom edge, so a card arriving moves its target up by a slot, while its
    // height - which is what says how far up the pile reaches - snapped to the
    // new total the instant the card arrived. For the length of the y tween the
    // box was therefore taller than its position accounted for and its bottom
    // edge hung past the bar: traced at 1189 with the bar edge at 1040, i.e.
    // 149px below it and off the bottom of the screen, taking seven frames to
    // settle, with the arriving card drawn down there - the "slides in from
    // outside the screen and over the statusbar" report.
    //
    // Animating the height on the same `Glide` makes the pile grow UPWARD out of
    // the bar's space instead of arriving from below it, and - because `y` above
    // is written against this height rather than against `pileHeight()` a second
    // time - it holds the bar edge exactly, which is also what makes it possible
    // for a card to cancel the box's motion and sit flush against the bar while
    // the cards above it do the sliding. That half is in NotificationCard, under
    // `Notifications.isArriving`; the two are one change.
    //
    // No Behavior on `y`, deliberately: it is not an independent quantity to
    // animate but the bar edge minus the height above it. Animating both is how
    // the edge drifts.
    //
    // Gated on `placed` so the first layout lands instead of animating up from
    // height 0 - the same reason as the cards, which are constructed at their
    // bound values. `place()` arms it once and never again; every later change is
    // this binding's own doing.
    Behavior on height {
      enabled: win.placed && Notifications.animationsEnabled
      Glide {}
    }
    // The cards' box, not the window's: this is what the input region follows.
    height: Notifications.pileHeight()
    anchors.right: parent.right
    anchors.rightMargin: win.margin

    // The only call site for place(), and it is deliberate: the box is armed
    // exactly once, after its first layout, and never again. Every LATER move
    // is the `y` binding's own doing and is animated by the Behavior above -
    // including the ones no explicit connection could have listed, which is the
    // point of the binding.
    Component.onCompleted: pile.place()

    // Each row carries one role, `entry`: the NotificationEntry its card draws.
    // A role holding the live object rather than a key into a lookup, because
    // the card binds to the entry itself and a second indirection would be a
    // second place to keep in step. The role's type is fixed by the first
    // insert, and syncRows() only ever inserts real entries.
    Repeater {
      model: rows

      delegate: NotificationCard {}
    }

    // Hovering the pile freezes every card's deadline.
    //
    // `HoverHandler` on the PILE rather than on each card, for the reason the
    // card's own hover is also a handler: a pointer anywhere in the pile is
    // inside one item, so the answer to "is the pile hovered" is one question
    // asked once, and it stays true across the gap between two cards, where a
    // per-card handler would report nothing at all. A card's own border lift is
    // per-card and stays that way.
    //
    // It does not interfere with the cards' clicks: a handler takes hover
    // without accepting the pointer, and the input region is the pile's own
    // geometry either way.
    HoverHandler {
      id: pileHover
    }
  }

  // `win.visible` is half of the answer, and it is the half a HoverHandler alone
  // cannot give: a pointer cannot leave a window that is no longer there, so the
  // unmapped-under-the-pointer case produces no hover event at all, and the
  // flag would outlive the pile that set it and freeze the next one.
  //
  // Published as one derived property rather than a handler per edge, because
  // visibility and hover are two inputs to a single question.
  readonly property bool _hoverPaused: win.visible && pileHover.hovered

  on_HoverPausedChanged: Notifications.hoverPaused = win._hoverPaused

  // The pile, one row per card.
  //
  // A ListModel rather than `Notifications.pile` directly, and the whole reason
  // is measured: a Repeater over a plain JS array destroys and rebuilds every
  // delegate whenever the array is replaced, and a delegate that has just been
  // constructed starts AT its bound value - so the card's `Behavior on y` has no
  // distance to travel and the pile snaps. The same test with a row removal on a
  // ListModel kept the surviving delegates (identity serials unchanged) and the
  // y tweened.
  //
  // `Repeater`, not `ListView`: the pile is bounded at Notifications.maxCards
  // and a recycling view would destroy the very delegates whose exit fade is
  // running - the card would be recycled, not finished.
  ListModel {
    id: rows
  }

  // Mirror Notifications.pile into the rows, row-wise.
  //
  // Removals, moves and inserts rather than a reset, because that is what
  // keeps the delegates that did not change. `applied` is what this function
  // last put in the model, so the diff is against the model's own state rather
  // than against a second guess at it.
  function syncRows() {
    // The model is this window's own child, and the window's `pile` binding can
    // change before it is constructed - the controller reassigns `pile` on
    // every notification, and the first one can land while the view is still
    // being built. Nothing to mirror into a model that is not there yet, and
    // the change that would have mattered arrives again with the next one.
    if (!rows) return
    const want = Notifications.pile
    const have = win.applied.slice()

    // Removals, highest index first so the indices below stay valid. A card
    // leaving here is one whose fade has already landed - the controller keeps
    // a released entry in the pile until then - so nothing is cut off.
    for (let i = have.length - 1; i >= 0; i--) {
      if (want.indexOf(have[i]) >= 0) continue
      rows.remove(i)
      have.splice(i, 1)
    }

    // Then put each wanted entry at its index, moving what is already there.
    for (let i = 0; i < want.length; i++) {
      if (have[i] === want[i]) continue
      const from = have.indexOf(want[i])
      if (from < 0) {
        rows.insert(i, { entry: want[i] })
        have.splice(i, 0, want[i])
        continue
      }
      rows.move(from, i, 0)
      have.splice(from, 1)
      have.splice(i, 0, want[i])
    }

    win.applied = have
  }

  // The pile, read once here so the change handler below has a local property
  // to watch. The controller reassigns `pile` on every change, so this is the
  // whole trigger: a pile that never changes never needs mirroring.
  readonly property var pile: Notifications.pile

  property var applied: []

  onPileChanged: win.syncRows()
  Component.onCompleted: win.syncRows()

  // Input only over the cards. An empty region while the pile is down, which
  // is the same answer a window with no mask gives for a surface nothing is
  // drawn on - except that a full-screen mask is the wrong answer here, so the
  // region is bound to the pile's own geometry.
  mask: Region { item: pile }
}