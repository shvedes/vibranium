pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common
import qs.features.notifications
import "../../common/math/Range.js" as Range
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
LayerSurface {
  id: win

  // Primary output only, and that is a decision rather than an oversight: a
  // card carries a dismiss deadline and a hover freeze, so a stack that
  // migrated to another output mid-timer would arrive still counting down with
  // no pointer able to pause it. Secondary outputs get the bar, the islands
  // and the OSD; the pile stays home.
  screen: Ui.primaryScreen ?? Quickshell.screens[0] ?? null
  // The mapping rule lives with the rest of the pile's policy (Notifications):
  // a card is up, including the exit fade of the last one.
  visible: Notifications.surfaceVisible
  // No `clip` here, and there cannot be one: this root is a Window, and `clip`
  // is an Item property. Anything that needs clipping goes on `pile`, which is
  // the Item the cards actually live in.
  surface: "vibranium:notifications"
  // The same level as the modal overlays (the menu family in
  // common/ui/OverlayWindow.qml) but below them in the layer's order: the
  // `vibranium:notifications` layer rule pins `order = 1`, so an open menu
  // covers the cards instead of the cards drawing over the menu's dim.
  //
  // Two surfaces on one level are ordered by which of them the compositor
  // saw last, and this window is destroyed and rebuilt on every burst of
  // notifications, so map order cannot answer this - the rule's explicit
  // order is what does, and it does not depend on which surface mapped last.
  //
  // Overlay rather than Top because Hyprland fades the whole Top layer when a
  // window goes fullscreen, which took the pile with it. Overlay is not faded
  // that way, so a notification arriving over a fullscreen app stays at full
  // strength.
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
  readonly property real cardWidth: Range.clamp(win.width - 2 * win.margin, 200, 330)

  // Vertical dock. The bar's height is reserved only when the bar is actually
  // on the side the pile chose: "follow statusbar" always is, and an explicit
  // corner is when it names the bar's side. A corner on the opposite side gets
  // just the margin - reserving the bar there left a bar-sized empty band
  // between the cards and the screen edge. The two insets are written as one
  // question rather than two, so the pile cannot end up docked to the top while
  // its bottom inset clears a bar it is not next to.
  //
  // An island that overlaps the pile's column adopts the dock (see
  // islandSharing below): the pile parks past the island's far edge instead
  // of over the island, so a notification never covers the card and a click
  // on either one lands where it looks. An island elsewhere on the bar - the
  // centre, say - leaves the pile at the bar dock, because it shares the bar
  // edge with the pile but not its column. Not held until the island closes -
  // shifted past it - and following resizes live, because the edge below is
  // plain data republished on every park.
  readonly property bool barOnPileSide: DesktopLayoutState.barEnabled
    && DesktopLayoutState.barPosition === (Notifications.atTop ? "top" : "bottom")
  readonly property real barDock: (win.barOnPileSide ? DesktopLayoutState.barHeight : 0) + win.margin
  // The island host serving this screen, if any: one IslandHost per bar
  // view registers itself in DesktopLayoutState under its screen name.
  // The island record for this screen ({showing, top, bottom, left, right})
  // or null.
  // Fresh object per publish, so any host move re-fires this chain by
  // value: opens shift the pile, closes return it, resizes glide it.
  readonly property string pileScreen: win.screen ? String(win.screen.name || "") : ""
  readonly property var islandRect: DesktopLayoutState.islandFor(win.pileScreen)
  // The pile's own column in the same full-screen coordinates as the island
  // footprint: one card wide at the chosen side, with the same margin on the
  // screen edge. This is what decides whether an island is actually near the
  // pile, and it follows a left-side setting just as the box itself does.
  readonly property real pileLeft: Notifications.atRight
    ? win.width - win.margin - win.cardWidth : win.margin
  readonly property real pileRight: Notifications.atRight
    ? win.width - win.margin : win.margin + win.cardWidth
  // An open island on this screen shifts the pile past its far edge, but only
  // when the island's footprint overlaps the pile's column: an island under a
  // module in the middle of the bar shares the bar edge with the pile, not its
  // column, so shifting for it would drag every notification towards the
  // middle of the screen. Anything else is the bar dock alone: records carry
  // showing=false after close, and a null record (no island, torn-down host)
  // is the same answer.
  // The island belongs to the bar, so it can only push a pile that is on the
  // bar's side. A corner chosen opposite the bar has no island to slide past.
  readonly property bool islandSharing: win.islandRect !== null
    && win.islandRect.showing === true
    && win.barOnPileSide
    && NotificationsLib.islandOverlapsPile(win.islandRect.left, win.islandRect.right,
      win.pileLeft, win.pileRight)
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
  // and a Column assigns y itself: its Behavior never sees that assignment and
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

    // The height glides with the cards so a bottom-docked pile grows upward
    // out of the bar instead of snapping. `y` is still the bar edge minus this
    // height at every frame, so the bottom edge stays put. Both are suppressed
    // across a dock change, where the card order reverses and there is nothing
    // meaningful to glide between.
    Behavior on height {
      enabled: !Notifications.snapReflow && Notifications.animationsEnabled
      NumberAnimation { duration: Notifications.motionMs; easing.type: Notifications.motionEasing }
    }
    // The cards' box, not the window's: this is what the input region follows.
    height: Notifications.pileHeight()
    // The pile docks straight to the chosen side. No animation on a switch:
    // an entrance or exit already owns each card's motion, and moving the
    // whole pile at the same time fights one that is in flight. Snapping also
    // lands the card reorder on the same frame as the move.
    x: Notifications.atRight
      ? parent.width - width - win.margin : win.margin

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
  // region is bound to the pile's box.
  //
  // The box's HEIGHT animates (Behavior on pile.height, 380ms), and its y is
  // derived from that height at the bottom dock. A Region bound to the Item
  // followed both live, so every frame of a reflow reposted the input region to
  // the compositor and stalled animations on the same GUI thread. The mask
  // instead uses the box's TARGET height - the same value the Behavior eases
  // toward - so it moves once when the pile changes and holds still through
  // the glide. x, width and the insets are step bindings already; pileHeight()
  // is a pure read of the settled content, not the animated geometry.
  mask: Region {
    x: pile.x
    y: Notifications.atTop
      ? win.topInset
      : win.height - win.bottomInset - Notifications.pileHeight()
    width: pile.width
    height: Notifications.pileHeight()
  }
}
