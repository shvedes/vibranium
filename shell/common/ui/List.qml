pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
// qmllint disable property-override
import QtQuick
import qs.common
import "NavKeys.js" as NavKeys

// Vertical list over any model, center-lock scrolloff follow policy.
//
// One follow rule: on long lists the cursor row rests near the
// viewport center; on short lists (content fits) the view never
// moves. scrolloff > 0 adds a row-margin around the center window
// (vim-style: the view holds until the cursor crosses it, then
// glides). All motion routes through seatTo - the single contentY
// writer - so view position and highlight bar share one truth.
//
// Placement: settle(index, snap) lands the cursor and places the row
// by the policy, placeRow(index) places a row the cursor is already
// on, and restoreAt(index, y) is the exact cursor-plus-offset seat.
// The height of the viewport the row is placed in is the last argument
// of settle, for a consumer whose viewport is still growing to it: the
// centre of a viewport that is not the one the row will sit in is the
// centre of a viewport that no longer exists.
//
// Keyboard scrolling is the consumer's routing (move() walks
// selectable rows via isSelectable, wrapping per `wrap`); the wheel
// steps entries directly when wheelSteps is on and the list is
// non-interactive (default). interactive: true restores native
// drag/flick (menu) and disables wheel stepping.
//
// Geometry authority: a measured, identity-keyed height table
// (rowIdentity; default index). Native estimate machinery never
// writes contentY: no positionViewAtIndex, no flick re-anchoring on
// non-interactive lists. contentHeight growth reconciles contentY
// downward-only against real bounds, so stale geometry can open no
// ghost space above row 0.
ListView {
  id: root

  // Emitted by activate() when the current row has no activate() of its own,
  // so a consumer whose rows answer a click can answer Enter from one place.
  // Declared here because ListView has no activated signal of its own (Qt
  // 6.11: `onActivated` on a bare ListView is an unqualified diagnostic), and
  // the name is the one every panel already reads off its own rows.
  signal activated(int index)

  // The current row as an untyped value. `currentItem` is declared as
  // QQuickItem and a delegate may be any Item with or without an activate(),
  // so probing that member off it directly is a missing-property diagnostic.
  // The untyped hop is what makes the duck-typed contract below legal; see the
  // same accessor in GridList, which is the other half of this contract.
  function _currentRow(): var { return root.currentItem }

  // Predicate deciding which indices keyboard navigation may land on;
  // defaults to accepting everything.
  property var isSelectable: index => true
  // Whether keyboard navigation wraps at the ends (menu-style).
  // Launcher stops at the last row instead of looping.
  property bool wrap: true
  // Compat: the follow policy is always center-lock.
  // Retained because consumers assign it; the value is advisory.
  property bool centerCursor: true
  // Smooth-scroll seat motion when the consumer's animation gate is
  // on; instant otherwise. User-driven motion always wins.
  property bool smoothScroll: false
  // Row-margin around the center window (vim-style). 0 = pure center
  // hold: any cursor step re-centers. > 0 = the view holds while the
  // cursor roams within `scrolloff` rows of its current viewport slot.
  property int scrolloff: 0
  // Sliding selection bar, library-driven: one bar gliding behind
  // transparent delegates. Consumers bind highlightMotion to their
  // animation gate; the active slot still owns height tracking.
  property bool selectionHighlight: true
  property bool highlightMotion: MotionPolicy.enabled
  // Row-set motion, library-driven: add/remove transitions live here rather
  // than in each consumer, so every list gets the same reveal. Consumers bind
  // this to their own animation gate - the menu drives it from whether the
  // row set is gliding or was rebuilt wholesale, which is knowledge only the
  // consumer has. Same contract as highlightMotion.
  property bool rowMotion: false
  //
  // What the eye reads as a slide here is NOT one. The slide half of these
  // transitions reads a travel from `ViewTransition.item`, which is null
  // inside a transition's `from` binding in this Qt, so the expression takes
  // its 0 branch and no travel is ever applied - proven three ways on a bare
  // ListView (`ViewTransition.item`, `ViewTransition.targets` and the
  // animation's own `target` are all null at that point). The motion that
  // does show is `addDisplaced` easing each row from wherever it was to
  // wherever it now belongs, which is why a newly created row and a row
  // pushed down by it read as two different motions. The opacity half is
  // unaffected - `from: 0` is a constant - so the fade always worked and the
  // slide never did.
  //
  // A real travel is expressible only where the item is reachable: in the
  // delegate, behind a wrapper a row puts around its own visuals. `remove`
  // transitions do not run at all: a `ListModel` remove destroys the delegate
  // inside the same turn, so there is nothing left to animate.
  // The selection bar is engine-owned and decoupled from contentY: it
  // binds to the current delegate's geometry with its own behavior, so
  // bar motion can never race or drift the scroll position (nothing writes
  // contentY from an estimate of where the cursor is).
  highlightFollowsCurrentItem: false
  // Stillness gate: zero highlight duration while a landing lease holds,
  // re-armed by observed release or user motion.
  property bool _seatsInstant: false
  // Stillness lease: acquired on "land" seats, released when displaced
  // motion quiesces (no displaced transition running and layout settled),
  // or pre-empted by a "step"/"click" seat, whichever lands first.
  property int _stillLease: 0
  property int _stillSeq: 0
  property string _stillFp: ""
  property int _stillStable: 0
  property double _stillAt: 0
  function _stillFingerprint() {
    var y = -1, h = -1
    var it = root.currentItem
    if (it) {
      y = it.y
      h = it.height
    }
    return root.count + "|" + Math.round(root.contentHeight) + "|"
      + root.currentIndex + "|" + y + "|" + h + "|"
      + (root.rowMotion ? "1" : "0")
  }
  // Acquire the stillness lease and schedule observed release. The gate
  // stays armed across turns until the layout fingerprint holds steady
  // with no tween in flight; a later land re-arms with a new token and
  // retires the older watch.
  function _stillAcquire() {
    root._stillSeq++
    root._stillLease = root._stillSeq
    root._seatsInstant = true
    root._stillFp = root._stillFingerprint()
    root._stillStable = 0
    root._stillAt = Date.now()
    var lease = root._stillLease
    Idle.run(function() { root._stillObserve(lease) }, 2)
  }
  // Observed release: hold while the swap/restore window owns the view,
  // while a content tween runs, or while the fingerprint still shifts;
  // release after it holds steady across turns, and never before one
  // displaced flight could have landed. Turns drain inside a single
  // frame, so stability across turns alone releases pre-flight.
  function _stillObserve(lease) {
    if (lease !== root._stillLease) return
    if (root._inSwap || root._sweeping) {
      Idle.run(function() { root._stillObserve(lease) }, 2)
      return
    }
    if (scrollAnim.running || root.moving) {
      Idle.run(function() { root._stillObserve(lease) }, 2)
      return
    }
    if (Date.now() - root._stillAt < MotionPolicy.duration(Ui.fastMs) + 20) {
      Idle.run(function() { root._stillObserve(lease) }, 2)
      return
    }
    var fp = root._stillFingerprint()
    if (fp !== root._stillFp) {
      root._stillFp = fp
      root._stillStable = 0
      Idle.run(function() { root._stillObserve(lease) }, 2)
      return
    }
    root._stillStable++
    if (root._stillStable < 2) {
      Idle.run(function() { root._stillObserve(lease) }, 2)
      return
    }
    if (lease !== root._stillLease) return
    root._stillLease = 0
    root._seatsInstant = false
  }
  // User motion pre-empts a held landing lease, so a step taken
  // mid-rearrange still glides.
  function _stillPreempt() {
    root._stillLease = 0
    root._seatsInstant = false
  }
  // cause: "step" (user) | "land" (filter/swap/restore seat) |
  //        "click" (user, delegate-direct today)
  // The single place an index write meets the highlight policy.
  // "step"/"click" re-arm glide; "land" acquires the stillness lease.
  // snap threads through to the follow: true seats instantly, otherwise
  // land seats instantly and step/click seats follow the smooth gate.
  // A snapped land defers its follow one turn, so the follow reads healed
  // geometry - unless a swap or a restore sweep owns the view in its own
  // window, which is the one case where a follow here would fight the
  // hold that is keeping the view where the model change left it. Other
  // lands follow at once. Clearing to -1 holds no bar and takes no lease.
  //
  // viewH is the height of the viewport the placement is for, for a
  // consumer whose viewport is still growing to it (see centerTarget). It
  // travels with the seat rather than sitting on the view, so it is the
  // height of THIS placement and nothing else can leave one behind.
  function seat(index, cause, snap, viewH) {
    var c = (cause === "step" || cause === "click") ? cause : "land"
    root._lastSeatCause = c
    if (c === "step" || c === "click") {
      root._stillPreempt()
      // A gesture takes the bar back from any pinned origin: the user is
      // naming a row, and a bar still easing from an origin another
      // transition armed would leave the cursor somewhere it is not.
      root._hlPin = false
      // The same gesture ends the cursor-keep arm (see keepCursor). The
      // arm exists to put the cursor back on the row a MODEL change took
      // it from, and it is spent by the first index change after the
      // write. A model change whose projection keeps the row under the
      // cursor at the same index moves no index at all, so the first
      // index change after it is this gesture - and the restore would
      // then put the cursor back on the row it was on, swallowing the
      // move the user just made. The gesture is the newer intent, so it
      // ends the arm rather than feeding it.
      root._keepCursor = false
    } else {
      if (index === -1) {
      } else if (index >= 0 && index < root.count) {
        root._stillAcquire()
        if (snap === true && index <= 0) root.seatTo(0, false, "seat")
      } else {
        return
      }
    }
    if (index === -1) {
      root._engineIndexWrite = true
      root.currentIndex = -1
      root._engineIndexWrite = false
      return
    }
    if (index < 0 || index >= root.count) return
    root._engineIndexWrite = true
    root.currentIndex = index
    root._engineIndexWrite = false
    if (c === "land") {
      if (snap === true) {
        const probe = index
        Qt.callLater(function() {
          // The cursor left the row this seat put it on: a gesture took
          // over, and the row it names is the one that matters.
          if (root.currentIndex !== probe) return
          // A swap or a restore sweep owns the view in its own window: a
          // follow here would fight the hold that is keeping the view
          // where the model change left it.
          if (root._inSwap || root._sweeping) return
          root.learnLive()
          // The follow, and nothing else: the seat's own write published
          // the index this seat names, so a test against that index is a
          // test against the seat itself and never lets the follow
          // through. A snapped land that never follows leaves the row
          // wherever the view happened to be - off screen, or pinned to an
          // edge - and the caller that asked for the row to be placed gets
          // nothing.
          root.trackCursor(probe, false, viewH)
        })
      } else {
        root.learnLive()
        root.trackCursor(index, false, viewH)
      }
    } else {
      root.trackCursor(index, snap === true ? false : true)
    }
  }
  // Sweep override: while a content tween runs, the bar uses the same
  // duration and curve so both land together with a constant viewport
  // offset (no end-of-glide wobble from mismatched 120ms-vs-distance
  // timings). Set per animated seat in seatTo, cleared on land/grab/
  // instant seat. -1 = off (default 120ms glide).
  property int _sweepMs: -1
  property bool _highlightHandoff: false
  readonly property real _currentSlotMotionMs:
    root.currentItem && typeof root.currentItem.slotMotionMs === "number"
      ? root.currentItem.slotMotionMs : 0
  highlightMoveDuration: root._seatsInstant
    ? 0
    : (root.highlightMotion && root.selectionHighlight
      ? (root._sweepMs >= 0 ? root._sweepMs : Ui.fastMs) : 0)
  highlightResizeDuration: root._seatsInstant || root._currentSlotMotionMs > 0
    ? 0
    : (root.highlightMotion && root.selectionHighlight
      ? (root._sweepMs >= 0 ? root._sweepMs : Ui.fastMs) : 0)
  highlight: selectionHighlight ? selHighlight : null

  // Held selection geometry: the last real position and size of the bar,
  // captured while the cursor's row still exists. The bar reads it while
  // that row does not (see selHighlight), which is the window a model swap
  // opens. Two capture points, both while the geometry is real: a cursor
  // move, and the opening of a swap - the moment before the delegates go.
  // _hlHeld is dropped with the cursor, so an empty list or a cleared
  // selection paints no bar at all.
  //
  // The Y is the row's distance from the VIEW's top, not its place in the
  // content. A content coordinate would leave the bar where the row used
  // to stand in the CONTENT, and a swap that shortens the content moves
  // the content under the bar: the tail delete takes the last row away
  // and the view rides the freed space down, so a content coordinate puts
  // the bar a whole row BELOW the place the user last saw it - off the
  // bottom edge of the list, from where it flies back in. A view-relative
  // coordinate keeps the bar where the user left it, which is the one
  // thing the hold is for.
  property bool _hlHeld: false
  property real _hlX: 0
  property real _hlY: 0
  property real _hlW: 0
  property real _hlH: 0
  // A pinned hold keeps the bar on that geometry even while a live cursor
  // row exists, which is the opposite of what the hold is for by itself.
  // A consumer arms it as the ORIGIN of a motion it is about to seat: the
  // index adjustment a model swap deals lands a frame or more after the
  // swap window closes, so between a repair seat and the commit that
  // confirms it the cursor is wherever the view echoed to - row 0 on a
  // fresh model. Unpinned, the bar follows the cursor there and then
  // travels the whole list back to the row the repair named. Pinned, it
  // starts from the row the user was on and takes a single leg. A pin
  // already standing is kept: a second swap inside the same delete is
  // still one motion, and re-pinning would re-take the origin from a
  // cursor that has already moved onto the row being eased away from.
  property bool _hlPin: false
  function pinHighlight() {
    if (root.currentIndex < 0) return false
    // A pin already standing keeps the origin it was armed with. The one
    // exception is a hold that has since been dropped - the cursor was
    // cleared while the pin was up - and clearing the pin is what lets the
    // hold be taken again, because an inert pin would report itself armed
    // while the bar is already following the cursor.
    if (root._hlPin) {
      if (root._hlHeld) return true
      root._hlPin = false
    }
    // The pin is the ORIGIN of the motion the consumer is about to seat, so
    // it has to be the geometry of the row the cursor is on NOW. A hold
    // left over from an earlier row would pin the bar to a row the user is
    // not looking at - and a hold that survived a row that is gone is
    // exactly that. So the capture has to have happened here, and a hold
    // that merely exists is not enough.
    if (!root._holdHighlight()) return false
    root._hlPin = true
    return true
  }
  // Dropping the pin hands the bar back to live cursor geometry, so the
  // release IS the seat: the bar eases from the pinned origin to wherever
  // the cursor row is by then.
  //
  // A standing settle holds the pin: the view has not ridden the freed
  // space down yet, so the live cursor row is not where the bar stands,
  // and releasing the pin here would drop the bar a whole row. The
  // settle releases it when it lands (see releaseSettle).
  function unpinHighlight() {
    if (root._settleActive) return
    root._hlPin = false
  }
  // Hold the bar's geometry at the cursor's row, so the bar has something to
  // read while that row is not there to be read - the window a model change
  // opens. Returns whether the geometry was captured now: a caller that
  // pins the hold needs a FRESH capture, because a hold left over from an
  // earlier row is a row the user is not looking at.
  function _holdHighlight() {
    if (root.currentIndex < 0) {
      root._hlHeld = false
      return false
    }
    // A pinned origin is the one geometry that must survive a cursor
    // move: the whole point of pinning is that the bar does not start its
    // next motion from wherever the cursor went.
    if (root._hlPin) return false
    const it = root.currentItem
    if (!it || it.height <= 0 || it.width <= 0) return false
    // Never hold a row that is not the cursor's: mid-swap the current
    // item lags the index (a model reset lands it on the top row while
    // the repair seat already moved on), and holding that row starts
    // the next glide from the top of the list.
    if (it !== root.itemAtIndex(root.currentIndex)) return false
    root._hlX = it.x
    // The row's distance from the view's top: the hold is about where the
    // bar sat on the SCREEN, and the screen is what the user was looking
    // at. A content coordinate would drag the bar along with the content
    // whenever a swap moves the content under it.
    root._hlY = it.y - root.contentY
    root._hlW = it.width
    root._hlH = it.height
    root._hlHeld = true
    return true
  }

  Component {
    id: selHighlight

    Rectangle {
      id: selBar

      color: Theme.color("background_2")
      radius: RoundingPolicy.radius
      // Live geometry, read off the cursor's row, or the latch on the view
      // while that row is not there yet. A model swap releases every
      // delegate and the replacements are laid out a frame later, so
      // currentItem is null for a frame and the new delegate reports zero
      // size until the view has measured it. A bar bound straight to
      // either collapses to nothing and pops back one frame later, which
      // reads as the selection redrawing on every update instead of the
      // rows changing under a static bar. The latch lives on the view, not
      // here: this bar's own bindings are torn down and rebuilt around a
      // swap, so anything it remembered about the old row would not survive
      // to be held.
      readonly property bool live: root.currentItem !== null
        && root.currentItem !== undefined
        && root.currentItem.height > 0
        && root.currentItem.width > 0
      // Held only while the cursor exists: an empty list or a cleared
      // selection has no bar at all, so a hold must never outlive the row
      // set it was measured on. A PINNED hold outranks live geometry (see
      // _hlPin): the consumer armed that geometry as the origin of a motion
      // it has not seated yet, and a cursor that moved in between is the
      // one place the bar must not start from.
      readonly property bool hold: root._hlHeld
        && root.currentIndex >= 0
        && (root._hlPin || !selBar.live)

      x: selBar.hold ? root._hlX : (selBar.live ? root.currentItem.x : 0)
      // The held Y is a distance from the view's top (see _hlY), so it is
      // read back against the CURRENT offset: the bar keeps the place on
      // the screen the user left it in, whether the content moved under it
      // or not.
      y: selBar.hold ? root._hlY + root.contentY
        : (selBar.live ? root.currentItem.y : 0)
      // The WIDTH is the list's width - every row in a list is as wide as
      // the list - so the live row answers it, and the held copy is only
      // the stand-in for the window where no row is there to read. A pin
      // holds the ORIGIN of a motion, not the size of the bar: the size
      // it froze was measured on a row of the width the list had then,
      // and a card that resizes under a standing pin (the menu's search
      // projection reserves a chevron the page rows did not) left the bar
      // a chevron short of the row it was supposed to be under.
      width: selBar.live ? root.currentItem.width
        : (selBar.hold ? root._hlW : 0)
      // The HEIGHT stays held: it belongs to the row, and the row a
      // swap has just put there reports its floor until it has measured
      // itself, so the live height would shrink the bar and grow it back.
      height: selBar.hold ? root._hlH
        : (selBar.live && root.currentItem ? root.currentItem.height : 0)

      Behavior on y {
       NumberAnimation {
         id: highlightMoveAnim
         duration: root.highlightMoveDuration
         easing.type: Easing.OutCubic
         onFinished: {
           root._highlightHandoff = false
           if (!scrollAnim.running) root._sweepMs = -1
         }
       }
      }
      Behavior on height {
        NumberAnimation { duration: root.highlightResizeDuration; easing.type: Easing.OutCubic }
      }
    }
  }

  // Step tween: one animation on the shared curve; duration scales
  // with distance so a wrap lap glides and a single step stays snappy.
  NumberAnimation {
    id: scrollAnim
    target: root
    property: "contentY"
    easing.type: Easing.OutCubic
     onFinished: {
       if (!root._highlightHandoff) root._sweepMs = -1
       root._followIdx = -1
       // A landed pursuit is not tracking anything, so a later reveal for
       // this row is a real scroll again and may ease. Without this the
       // claim outlives its own tween and every following seek on the row
       // would seat geometrically.
       root._pursuitIdx = -1
       root.contentY = root.clampY(root.contentY)
       // A pursuit that landed short of a target which kept moving has a
       // remainder, and nothing else re-arms it: the row has stopped
       // changing, so its height handler is quiet. Re-run the chase, so the
       // last few pixels arrive as one more eased leg - a smooth push, not a
       // snap, and not a leftover gap under the dropdown. With nothing left
       // to do the target is unchanged and seatTo returns without arming, so
       // this cannot loop.
       if (root.autoRevealIndex >= 0) root.pursue()
       root.motionFinished()
     }
  }

  // Traverse velocity for scroll tweens: px per second, scaled up with
  // content size so a full-length page lands in ~250ms on any list
  // while short steps keep the exact fastMs feel via the stepMs floor.
  property int _sweepMaxMs: 420
  property real scrollVpx: 6000
  function scrollVel() { return Math.max(root.scrollVpx, root.tableTotal() * 4) }
  function stepMs(dist) {
    if (!isFinite(dist) || dist <= 0) return Ui.fastMs
    return Math.max(Ui.fastMs,
      Math.min(root._sweepMaxMs, Math.round(dist / Math.max(1, root.scrollVel()) * 1000)))
  }

  // Seat epoch: every programmatic seat and every user grab bumps it.
  // Deferred retries capture it and no-op when stale.
  property int _seatEpoch: 0
  property bool _inSwap: false
  property int _swapToken: 0
  // Every seat that actually moved (or began moving) the view, and the tag
  // of the last one. The epoch cannot serve the swap hold instead: a seat
  // that lands on the position the view already holds still bumps it, and
  // the index echo a model swap deals the view is exactly such a seat. A
  // hold that read the epoch would release on the very frame the heal
  // needs it.
  property int _seatWrites: 0
  property string _lastWriteTag: ""
  // Wall clock of the last swap-window close, ms. ListView settles a model
  // reset asynchronously - delegates, layout AND the index land over the
  // frames after the install - so an index change arriving just past the
  // choreography window is the view echoing the swap, not a new cursor
  // gesture, and following it with a tween scrolls settled content for no
  // reason (the flip-slide). The auto-follow below stands down for one
  // fastMs window after a swap closes; a real gesture re-follows on its
  // next move. Self-healing by construction: time passes whether or not
  // anything else runs.
  property double _swapEndMs: 0
  // Restore-sweep window (menu restore protocol): true while restoreAt
  // is re-seating after a model restore; consumers gate persistence on
  // it. Closed by _endSweep() or self-closed after the re-seat.
  property bool _sweeping: false
  property int _restoreToken: 0

  // --- measured height table (identity-keyed) ---

  property var _knownH: ({})
  property real _avgH: -1
  property real _sumH: 0
  property int _countH: 0
  // Stable per-row identity for the height table. Default is the
  // index itself (static-model consumers keep index behavior).
  // Consumers whose rows mutate, reorder or load content async
  // override this so table entries follow their row, not its slot.
  // A non-callable override degrades to the index default through
  // _rowKey below instead of taking down every handler that reads one.
  property var rowIdentity: index => index
  // Identity epoch for the table, declared by the consumer. A model
  // that swaps a row's identity in place - same count, same first and
  // last identity - is invisible to the endpoint fingerprint below, so
  // such a consumer binds its identity changes here. 0 means a static
  // model and keeps the fingerprint's pre-revision behaviour exactly.
  property int identityRevision: 0
  // Retained identities. A session measures a few hundred distinct
  // rows at most (pass navigation alone touches ~140 view keys), while
  // a consumer that churns identities without declaring a revision
  // keeps one dead entry per mutation forever: a sustained middle-only
  // churn reached 2000 dead keys. The bound caps that at the price of
  // an estimate for the least recently changed rows, which re-learn on
  // their next measurement.
  property int maxKnownH: 1024
  // When-change stamp per entry. Eviction is least recently changed
  // first, so a row whose height settled (and which therefore needs no
  // fresh entry) is the one that gives up its slot.
  property var _touchH: Object.create(null)
  property int _touchClock: 0
  // Identity -> owning live index, or -1 where more than one live row
  // claims the same identity. One measured height cannot be the height
  // of two rows, so a contested identity is refused for learning and
  // pruned from the table. Prototype-free: an identity naming an
  // Object.prototype member must not read as a claim.
  property var _idOwner: Object.create(null)
  property string _identityError: ""
  // Non-empty while the live rows collide on one identity, coded like
  // MenuPanel's _modelError so a consumer can report it verbatim. It
  // catches a consumer that DECLARES identityRevision and still
  // collides; a consumer that mutates identities without declaring one
  // leaves the fingerprint untouched, so no sync runs and the collision
  // stays invisible by construction. A collision that clears without
  // moving count, endpoints or revision keeps the code until the next
  // sync - the code describes the last row set the engine inspected.
  readonly property string identityError: root._identityError
  // Reported by nobody, and that is a decision with a reason rather than an
  // omission. A contested key is refused for learning and pruned, so the
  // damage is contained - the cost is a silently degraded table, not a wrong
  // frame - and the engine is the only place that can see the collision, so
  // the diagnostic wants a scope that names a shared primitive, and the
  // consumers that declare a `rowIdentity` each own a feature, so any scope
  // they could raise would name a consumer that is not at fault.
  //
  // So this stays a report back. A consumer that wants the guarantee reads
  // this property - it is a binding, so a `Connections` on
  // `onIdentityErrorChanged` is the whole integration - and that is acceptable
  // while the failure mode is a table that re-learns rather than geometry that
  // lies.
  property string _idFingerprint: ""
  // The row the cursor is on, by identity. Captured on every cursor change
  // the model did not cause, because a model replacement clears
  // currentIndex and the row goes with it: by then the only way to name
  // the row is the name it was given here.
  property string _cursorId: ""
  // Armed by the consumer before it replaces the model. The consumer is
  // the only thing that knows a replacement is coming: the list sees the
  // model change after the change has already moved the cursor, and by
  // then the row the cursor was on is gone from the model.
  property bool _keepCursor: false
  // Arm the cursor for the next model change. The consumer calls this
  // before it replaces the model, and the cursor stays on the ROW it was on.
  //
  // A model change moves the cursor off that row either way, and which way
  // depends on the model: a REPLACED model clears currentIndex, so the
  // cursor lands on the new head, and a DIFFED model keeps the index, which
  // is now a different row. Either way the row the user was on is a row
  // nobody is on, and only the row's identity says which one it was.
  //
  // The consumer has to arm it because the consumer is the only thing that
  // knows a change is coming: the list sees the model change after the
  // change has already moved the cursor, and by then the row is gone from
  // the model.
  //
  // The bar's origin is pinned at the same moment, and for the same
  // reason. The bar reads the cursor's row, so a bar that followed the
  // cursor onto the head would start its travel at the head and walk the
  // whole list back down to the row the cursor is put back on. Pinned to the
  // row the user was looking at, it takes one leg instead. The pin is
  // released when the cursor is back on its row, and the hold covers the
  // frames in between where the row is not there to be read.
  //
  // The arm is spent by the FIRST index change after the write, and that
  // has to be a change the MODEL made. A model change whose projection
  // keeps the row under the cursor at the same index moves no index at
  // all, so the model never spends the arm - and an arm that outlives its
  // change is an arm waiting to answer the user's own cursor move with a
  // cursor the user did not ask for. A user gesture therefore ends it (see
  // seat), and the bar's width reads the live row rather than the width
  // the arm froze (see selHighlight).
  function keepCursor() {
    root._keepCursor = true
    root.pinHighlight()
  }

  // Put the cursor back on the row it was on before the model was replaced.
  // The row is found by identity, so a row that appeared or disappeared
  // above the cursor does not move it: the cursor lands on the same ROW, at
  // whatever index that row now sits at.
  //
  // A direct index write, not a seat. A seat acquires the stillness lease,
  // and the lease is what holds the row motion still - so a restore that
  // arrived as a landing would freeze the very transition the model change
  // was about to play, and the rows would appear and disappear without
  // moving. A restore is not a landing: nothing about the cursor's place in
  // the world has changed, only the numbering of the rows around it.
  function _restoreCursor() {
    const id = root._cursorId
    // Every path out of here releases the pin. A pin that outlives its
    // restore is a bar frozen on the geometry of a row the cursor has
    // already left, and it is frozen until something else happens to move
    // the cursor - which is a bar that paints the wrong row until the user
    // clicks.
    if (id === "") { root.unpinHighlight(); return }
    for (let i = 0; i < root.count; i++) {
      if (root._rowKey(i) !== id) continue
      if (i === root.currentIndex) { root.unpinHighlight(); return }
      // The write is guarded, so the handler that fires for it does the
      // geometry hold and stops - the same shape a landing has, minus the
      // stillness lease.
      root._engineIndexWrite = true
      root.currentIndex = i
      root._engineIndexWrite = false
      // The cursor is back on its row, so the bar may travel to it. The
      // hold covers the frames in which the row is not there to be read,
      // and the pin - which held the bar at the row the user was looking
      // at - gives way to the hold here.
      root.unpinHighlight()
      return
    }
    // The row is not in the model: the new model is not laid out yet, or
    // the row is gone for good. There is nothing to put the cursor on, and
    // the pin has nothing to hand over to.
    root.unpinHighlight()
  }

  // The one identity accessor: every table read and write goes through
  // it, so a missing or non-callable rowIdentity can never throw out of
  // a binding. A null/undefined identity degrades to the index default
  // too - one shared "null" key would collapse every row onto a single
  // height entry.
  function _rowKey(index) {
    if (typeof root.rowIdentity !== "function") return String(index)
    const id = root.rowIdentity(index)
    return id === null || id === undefined ? String(index) : String(id)
  }
  function _clearHeightTable() {
    root._knownH = {}
    root._touchH = Object.create(null)
    root._touchClock = 0
    // The ownership map describes the same row generation as the
    // table, so dropping the table drops it too.
    root._idOwner = Object.create(null)
    root._identityError = ""
    root._sumH = 0
    root._countH = 0
    root._avgH = -1
  }
  // Drop table entries whose identity no longer exists: stale keys
  // would keep tableMaxY above real bounds after model mutations. The
  // identityRevision term in the fingerprint is what makes an in-place
  // identity swap visible here; the prune then drops exactly the keys
  // the current row set no longer claims.
  function _syncIdentitySet() {
    const fp = root.identityRevision + "@" + root.count + ":" + (root.count > 0
      ? root._rowKey(0) + "|" + root._rowKey(root.count - 1)
      : "")
    if (fp === root._idFingerprint) return
    root._idFingerprint = fp
    if (root.count === 0) {
      root._clearHeightTable()
      return
    }
    const owner = Object.create(null)
    let contested = false
    for (let i = 0; i < root.count; i++) {
      const key = root._rowKey(i)
      if (owner[key] === undefined) owner[key] = i
      else {
        owner[key] = -1
        contested = true
      }
    }
    root._idOwner = owner
    root._identityError = contested ? "duplicate_identity" : ""
    let changed = false
    const next = {}
    let sum = 0
    let n = 0
    for (const k in root._knownH) {
      const own = owner[k]
      // Dead identity, or an identity two live rows share: neither
      // keeps a measured height.
      if (own === undefined || own === -1) {
        delete root._touchH[k]
        changed = true
        continue
      }
      next[k] = root._knownH[k]
      sum += next[k]
      n++
    }
    if (changed) {
      root._knownH = next
      root._sumH = sum
      root._countH = n
      root._avgH = n > 0 ? sum / n : -1
    }
  }
  // Least recently changed eviction, run after every write, so a
  // consumer that never declares identityRevision cannot grow the
  // table past the bound. The sum and the count move with every drop,
  // so the average stays the true average of what is kept.
  function _trimHeightTable() {
    // _countH is the entry count, so the common case allocates nothing.
    if (root._countH <= root.maxKnownH) return 0
    const keys = Object.keys(root._knownH)
    const excess = keys.length - root.maxKnownH
    keys.sort((a, b) => {
      const delta = (root._touchH[a] || 0) - (root._touchH[b] || 0)
      if (delta !== 0)
        return delta
      return a < b ? -1 : 1
    })
    let removed = 0
    for (let i = 0; i < keys.length && removed < excess; i++) {
      const key = keys[i]
      root._sumH -= root._knownH[key]
      root._countH--
      delete root._knownH[key]
      delete root._touchH[key]
      removed++
    }
    if (removed === 0) return 0
    root._avgH = root._countH > 0 ? root._sumH / root._countH : -1
    return removed
  }
  onCountChanged: {
    root._noteWindowing()
    root._syncIdentitySet()
  }

  onIdentityRevisionChanged: root._syncIdentitySet()
  onModelChanged: {
    root._clearHeightTable()
    // A model change that did NOT move the cursor leaves it on the same
    // INDEX, which is a different row. That case has no index change to
    // restore from, so it is restored here - and here is late enough to be
    // worth the wait, because the cursor never left the row it was on, so
    // there is no travel to see.
    if (root._keepCursor) {
      root._keepCursor = false
      root._restoreCursor()
    }
  }
  // Engine-write guard: internal currentIndex assignments (move,
  // settle, restoreAt) seat explicitly and must not re-trigger this
  // handler. Set before the assignment, always cleared after it -
  // the signal fires synchronously, or not at all when the value
  // is unchanged.
  property bool _engineIndexWrite: false
  // Provenance of the last cursor seat: "step"/"click" for user motion,
  // "land" for everything programmatic (settles, restores, clears). The
  // menu's cursor memory (track/saveFrame) persists only user motion: a
  // native index adjustment after a model swap must never become a
  // remembered seat. Reset on every model write, since anything the
  // cursor does after a write is non-volitional until the next seat.
  property string _lastSeatCause: "land"
  // Auto-follow: consumers set currentIndex directly (menu, launcher,
  // pass, filter resets, delegates) - the view must chase through the
  // one seat writer. That writer is the trigger for out-of-engine index
  // writes; explicit callers
  // (move/settle/restoreAt) seat themselves and are guard-suppressed.
  // Suppressed mid-swap and mid-restore: those paths seat explicitly.
  onCurrentIndexChanged: {
    // A model change moves the cursor off the row it was on, and the
    // consumer armed keepCursor before the write, so this movement is the
    // model's and the row is put back - HERE, in the same turn as the
    // movement, because a turn later the view has already painted the row
    // the cursor landed on and the selection bar has already started its
    // travel there, and the bar's glide from that row to the right one
    // makes the whole path visible.
    if (root._keepCursor) {
      root._keepCursor = false
      root._restoreCursor()
    } else if (root.currentIndex >= 0) {
      // The row the cursor is on, by identity. Captured while it is still
      // there: a model change moves the cursor off that row, and the row
      // goes with it, so this is the only moment the row can be named.
      root._cursorId = root._rowKey(root.currentIndex)
    }
    // Re-hold for the new cursor row before the guards below, but never
    // inside a swap window: beginSwap already held the pre-swap geometry,
    // and the index reset a model swap deals re-holds the top row, which
    // the next repair seat then glides from across the whole list. A bar
    // bound to the previous row's geometry must not be what the hold
    // carries into a swap that follows this move.
    if (root.selectionHighlight && !root._inSwap) root._holdHighlight()
    if (root._engineIndexWrite) return
    if (root._inSwap || root._sweeping) return
    // A non-selectable list has no cursor to follow. The guard keys on
    // `selectionHighlight` alone, because `stableModel` defaults to
    // undefined: a guard that also required `stableModel !== undefined`
    // inverted it for the default - the lists that PAIR
    // selectionHighlight: false with a stableModel returned here, and a
    // non-selectable list that declared neither - the color-picker history -
    // fell through and was cursor-tracked. That arms `_followIdx`, and
    // every later contentHeight change re-derives centerTarget against that
    // remembered row, parking the view mid-list where a front-promoted entry
    // lands above the viewport and is never shown.
    if (!root.selectionHighlight) return
    // _seatsInstant gates tweening too: snap restores and swap landings
    // seat instantly even with animations on. The swap-recency term covers
    // the view's own async echo: ListView lands a model reset's index
    // adjustment after the swap window closed, and that change is not a
    // gesture - following it would ease settled content on stale tall
    // geometry. Within one fastMs of a swap close the follow seats
    // instantly; a real cursor move re-follows animated on its next step.
    const freshSwap = (Date.now() - root._swapEndMs) < Ui.fastMs
    root.trackCursor(root.currentIndex, !root._seatsInstant && root.smoothScroll && !freshSwap)
  }

  // Live delegate count and the windowing regime, both derived and both
  // re-derived from the view rather than tracked: the view owns how many
  // delegates exist and the buffer, and asking it is cheaper than being
  // right about it.
  property int _liveDelegates: -1
  property int _windowingRegime: -1

  // Delegate construction and destruction. `contentItem.children` is the
  // live set, so a difference from the last reading is exactly one
  // construction or one destruction.
  function _noteDelegates() {
    const live = root.contentItem ? root.contentItem.children.length : 0
    if (live === root._liveDelegates) return
    root._liveDelegates = live
  }

  // The full-instantiation threshold. Below `Ui.listFullRows` the list
  // instantiates every row and the layout is exact; above it the fixed
  // buffer trades that for a bounded delegate count, and the answer changes
  // from exact to estimated at the crossing. Which side of it a list is on
  // explains most of what a reader cannot explain about its geometry.
  function _noteWindowing() {
    const regime = root.autoCache ? (root.count < Ui.listFullRows ? 1 : 0) : 2
    if (regime === root._windowingRegime) return
    root._windowingRegime = regime
  }

  Component.onCompleted: {
    root._noteWindowing()
  }

  onAutoCacheChanged: root._noteWindowing()

  function _avg() {
    if (root._avgH > 0) return root._avgH
    const n = root.count
    if (n > 0 && root.contentHeight > 0)
      return Math.max(Ui.rowMinH, root.contentHeight / n)
    return Ui.rowMinH
  }
  // Predicate gating height learning per row. Consumers with in-flow
  // slots (delete confirms, editors, descriptions) report false while
  // any slot is open, so the table never learns slot-inflated heights
  // (phantom scroll on short lists, short seats elsewhere). Defaults to
  // always learning. Must be a pure flag read - never throw, never bind
  // to delegate geometry (it runs inside the seat path).
  property var measureGuard: index => true
  property real restingContentHeight: 0
  function noteMeasured(index, h) {
    if (index < 0 || index >= root.count) return
    if (typeof h !== "number" || !isFinite(h) || h < 1 || h > 2000) return
    // Never learn from transient geometry: newborn delegates measured
    // mid-swap report their floor (unpolished texts) instead of their
    // resting height, and hidden views measure degenerate widths. Both
    // pollute the average, short-land far-end seats and ratchet originY.
    if (root._inSwap || root.height <= 0) return
    if (typeof root.measureGuard === "function" && !root.measureGuard(index)) return
    const key = root._rowKey(index)
    // Two live rows on one identity have no single height to learn.
    if (root._idOwner[key] === -1) return
    if (root._knownH[key] === h) return
    const old = root._knownH[key]
    root._knownH[key] = h
    root._touchClock++
    root._touchH[key] = root._touchClock
    if (typeof old === "number") root._sumH += h - old
    else {
      root._sumH += h
      root._countH++
    }
    root._avgH = root._countH > 0 ? root._sumH / root._countH : -1
    root._trimHeightTable()
  }
  // The height a row will SETTLE at, for rows that publish one. A row
  // whose slot is unfolding is mid-animation, so its live height is one
  // frame of a target that is still moving: seating on that frame and
  // re-seating as it moves is what makes a reveal stutter, because every
  // re-seat restarts the ease at zero velocity - the content decelerates
  // into each handover, stops dead, and lurches out of the next one. The
  // destination is known the moment the slot opens (DropdownSlot measures
  // its content before it animates), so the pursuit can seat ONCE to where
  // the row is going and ride it out in a single ease whose duration and
  // curve are the slot's own - the scroll and the unfold become one motion.
  // Rows that publish nothing (every plain row) keep the live height.
  function rowSettledHeight(it, live) {
    if (!it) return live
    const s = it.settledHeight
    if (typeof s === "number" && isFinite(s) && s > live) return s
    return live
  }
  function rowHeightAt(index) {
    const h = root._knownH[root._rowKey(index)]
    if (typeof h === "number" && isFinite(h) && h > 0) return h
    return root._avg()
  }
  // Live delegate geometry wins over the table whenever the delegate
  // exists: with full instantiation (small lists) every seat reads engine
  // truth, so stale table entries (birth heights on unvisited rows) can
  // no longer short-land far-end seats. Transient y mid-transition
  // (menu add/remove glides) errs by under a row for one seat and heals
  // on the next - bounded, unlike unbounded table staleness. Row 0 is 0
  // by construction - never extrapolated.
  function rowTop(index) {
    const live = root.itemAtIndex(index)
    if (live) return live.y
    let y = 0
    for (let i = 0; i < index; i++) {
      y += root.rowHeightAt(i)
      y += root.spacing
    }
    return y
  }
  // Total the content WOULD have with every open slot fully out, summed
  // from the rows themselves rather than from the last row's position.
  // A row mid-unfold is resized at once but is not applied to the rows
  // below it until the view flushes, so the last row's y understates the
  // extent by exactly that growth for the whole unfold - and once the
  // view does flush, the growth is already inside that same y, so
  // patching the number up by the growth double-counts it. Summing the
  // settled heights is right on either side of the flush, and it is also
  // how a bound that is genuinely short can be told from a stale one.
  // -1 when the list is not fully instantiated, because a sum over the
  // live subset is not the total.
  function settledTotal() {
    if (root.count <= 0) return -1
    if (root.contentItem.children.length < root.count) return -1
    let total = root.trailSpace
    for (let i = 0; i < root.count; i++) {
      const d = root.itemAtIndex(i)
      if (!d) return -1
      total += root.rowSettledHeight(d, d.height)
      if (i > 0) total += root.spacing
    }
    return total
  }
  function tableTotal() {
    // Exact total while the last delegate lives (engine layout plus the
    // trailing space the footer carries). Falls back to the table sum
    // for big estimated lists. A last row mid-unfold contributes its
    // SETTLED height, not the current frame's: the bound has to admit the
    // position the reveal is riding to, and a bound that only reaches the
    // live frame would clamp that seat back to a chase.
    const settled = root.settledTotal()
    if (settled >= 0) return settled
    const last = root.count > 0 ? root.itemAtIndex(root.count - 1) : null
    if (last) {
      return last.y + root.rowSettledHeight(last, last.height) + root.trailSpace
    }
    let total = root.trailSpace
    const n = root.count
    for (let i = 0; i < n; i++) {
      total += root.rowHeightAt(i)
      if (i > 0) total += root.spacing
    }
    return total
  }
  function tableMaxY() {
    return Math.max(0, root.tableTotal() - root.height)
  }
  // Height the first `maxRows` rows occupy, clamped to what the viewport
  // can show. Live geometry is the authority; a row the view has not
  // instantiated is measured from the height table instead - the same
  // rule rowTop and tableTotal already use, because a capped list
  // routinely has more rows in the model than the viewport holds (and
  // while the card is still short, far more).
  //
  // Refusing the whole fit because row 11 of 11 is off-screen is what
  // left every capped list unmeasured: the caller got -1, gave up, and the
  // card fell back to the whole available height - so a list capped at ten
  // rows sized itself to the window, and the card breathed by the
  // difference on every keystroke that crossed the cap.
  // True when this row's height is engine truth rather than an average: a
  // live delegate, or a table entry measured for this row's own identity.
  // rowHeightAt degrades to _avg() when neither holds, and a sum built on that
  // is a guess about rows the view has never shown.
  function rowHeightKnown(index) {
    if (root.itemAtIndex(index)) return true
    const h = root._knownH[root._rowKey(index)]
    return typeof h === "number" && isFinite(h) && h > 0
  }

  function fitHeight(avail, maxRows) {
    if (root.count === 0 || root.contentHeight <= 0) return -1
    const limit = maxRows > 0 ? Math.min(root.count, maxRows) : root.count
    // A row the view has not shown has no height to measure, and rowTop's sum
    // over rowHeightAt would fold _avg() in for it - so the answer comes back
    // fractional and off a row boundary, and the caller latches a size the
    // settled geometry does not agree with. Measured on a cold boot of the
    // theme picker: rows 8 and 9 were still unbuilt, the fit answered 487.17
    // against a true ten-row bottom of 468, and the card shrank to the real
    // height a frame later - a sliver of the eleventh row, then a visible
    // correction. -1 sends it down the retry path, which is what every other
    // not-yet-measurable condition in here already does.
    for (let i = 0; i < limit; i++) {
      if (!root.rowHeightKnown(i)) return -1
    }
    let best = -1
    let prev = -1
    let last = -1
    for (let i = 0; i < limit; i++) {
      const d = root.itemAtIndex(i)
      const h = d ? d.height : root.rowHeightAt(i)
      if (!(h > 0)) return -1
      const bottom = (d ? d.y : root.rowTop(i)) + h
      if (bottom > avail + 0.5) return best
      prev = best
      best = bottom
      last = i
    }
    if (last < 0) return -1
    const withTrail = best + root.trailSpace
    if (withTrail <= avail + 0.5) return withTrail
    // The trailing space overflows the last row: answer with the row
    // before it, which the loop already measured.
    return last === 0 || prev < 0 ? best : prev
  }

  // One clamp for every contentY write. The table is the primary
  // authority; the real layout (live contentHeight) wins downward when
  // it is clearly below the table bound - the ghost-space signature of
  // stale or transiently inflated geometry. Upward dips stay ignored:
  // transient estimate churn must not ratchet the view down.
  //
  // The veto only applies when the table is the ESTIMATED side, which is
  // exactly when the last delegate is not instantiated: only then does
  // tableTotal() sum cached heights instead of measuring a live row, and
  // only then can it over-claim. When the last delegate IS live,
  // tableTotal() measured real geometry and contentHeight is the side that
  // lags - the view flushes a resized delegate's new extent on its own
  // schedule, so mid-animation it reads short by exactly the growth in
  // flight. Measured on a dropdown opening on the last row: the delegate
  // was 74 tall at y=245, tableTotal() said 319, and contentHeight still
  // said 292 for the whole 120ms of the slot easing - so the bound was 0,
  // the reveal could not begin at all, and it only became possible once
  // the view relayouted after the slot had finished. That is the whole of
  // the bottom-entry reveal: the dropdown opened below the fold, then
  // jumped when the view caught up. Higher rows need no scroll and so
  // never see it. Trusting the lagging side here also cannot invent ghost
  // space: the live measurement is the truth, not an estimate.
  //
  // The one case where neither side answers is a held swap (_swapHold), where
  // the table was just cleared and the live extent belongs to a half-built
  // content. There the live extent is the bound, because it is the only one
  // that grows as the replacement rows measure.
  function clampY(y) {
    // NaN (never +-Infinity: followCursor queries the bound with
    // +Infinity) degenerates to the top.
    if (Number.isNaN(y)) return 0
    let maxY = root.tableMaxY()
    if (root.contentHeight > 0) {
      const realMaxY = Math.max(0, root.contentHeight - root.height)
      if (root._swapHold) {
        // Inside a held swap the table is the one bound that cannot be
        // believed: the model write cleared it and the replacement rows
        // measure a frame late, so it under-reports for exactly as long as
        // the hold has to run. The live extent is what Qt itself enforces,
        // and any bound under it puts back the short seat the hold exists
        // to replace.
        maxY = realMaxY
      } else if (!root._inSwap) {
        const lastLive = root.count > 0 && root.itemAtIndex(root.count - 1) !== null
        if (!lastLive && realMaxY < maxY - 0.5) maxY = realMaxY
      }
    }
    if (y > maxY) return maxY
    if (y < 0) return 0
    return y
  }

  // --- the tail settle ---
  //
  // A removal at the TAIL of the content is the one change the view
  // cannot absorb for free: the content loses exactly the space the view
  // was resting on, so the bound comes down by a whole row, and the
  // correction is instant - the content cannot hold a stale extent and
  // the bound IS the bound. The list jumps a row and the highlight bar
  // goes with it.
  //
  // The settle holds that space instead of giving it back at once. The
  // space is claimed BEFORE the model write, so the write leaves the
  // content's extent alone: the view does not move and the scroll range
  // does not change under the finger. It is animated away afterwards, so
  // the content shrinks by exactly the space while the view rides it
  // down: the rows settle into the freed space, the scroll range closes
  // with them, and the bar - pinned to the place the user left it -
  // stands still throughout.
  //
  // The space is the removed row's own slot (its height plus the gap
  // below it). It rides on the trail, which is the space under the last
  // row, and the consumer's own trail is put back when the settle lands.
  property real _settleTrail: 0
  property real _settleSpace: 0
  property bool _settleActive: false
  // Whether a settle is standing. A consumer reads it to know that the
  // view is mid-settle: the content's extent is still the old one and
  // the bar is still pinned.
  readonly property bool settling: root._settleActive
  // Claim the space a removal at the tail of the content frees. Called
  // before the model write, so the write leaves the content's extent
  // alone. Returns whether the settle took the space: a consumer asks
  // only when the removal is the LAST one and the view stands on the
  // bottom, because anywhere else the content loses space the view was
  // not using and the bound does not move under it.
  function claimSettle(space) {
    if (!(space > 0)) return false
    root._settleTrail = root.trailSpace
    root._settleSpace = space
    root.trailSpace = root._settleTrail + space
    root._settleActive = true
    return true
  }
  // Give the space back: the content shrinks by exactly that much, the
  // bound comes down with it, and the view rides it down.
  function releaseSettle() {
    if (!root._settleActive) return
    if (!MotionPolicy.enabled) {
      // No motion is the same as no settle: the space goes back at once
      // and the view takes the row's worth in one step.
      settleAnim.stop()
      root.trailSpace = root._settleTrail
      root._settleSpace = 0
      root._settleActive = false
      root._hlPin = false
      return
    }
    settleAnim.from = root.trailSpace
    settleAnim.to = root._settleTrail
    settleAnim.restart()
  }
  NumberAnimation {
    id: settleAnim
    target: root
    property: "trailSpace"
    duration: Ui.fastMs
    easing.type: Easing.OutCubic
    onFinished: {
      root._settleSpace = 0
      root._settleActive = false
      // The bar was pinned to the place the user left it for the whole
      // settle, and the live cursor row has arrived under it: the
      // release is a handover and not a move.
      root._hlPin = false
    }
  }

  // Single programmatic writer for contentY. Every seat - keyboard
  // step, wheel step, page, restore, pursuit, reconciliation - routes
   // through here. Direct `contentY =` writes outside this function
   // are forbidden.
   //
   // paceMs overrides the distance-paced duration for a seat that must
   // land together with another motion: a pursuit chasing an open slot
   // passes the claimed row's own slot pace, so a long scroll runs with
   // the unfold and the region's growth instead of arriving after them.
   // Capped at the distance pace, never slower than it: a remainder is
   // not a full unfold, and pacing one at the full slot duration would
   // crawl. Absent (or not positive) the seat keeps the distance-paced
   // duration.
  function seatTo(y, animated, tag, paceMs) {
    root._syncIdentitySet()
    root._seatEpoch++
    const target = root.clampY(y)
    // `tag` is the OWNER of the seat, which is what the release below reads.
    if (Math.abs(target - root.contentY) < 0.5) return target
    // Absolute seats (restore/reveal/page/pursuit/reconcile) own an
    // exact position, never a follow: release any in-flight follow so a
    // later layout shift cannot retarget them to the cursor. A pursuit is
    // the one seat that keeps a claim of its own, and every other seat
    // must leave that claim clear - a foreign tween mistaken for a
    // pursuit's own would be re-aimed by the next height step.
    const owner = tag || "seat"
    // Ownership is recorded only for a seat that moves: a seat that lands
    // where the view already stands has no opinion about contentY, and the
    // swap hold below has to be able to tell the two apart.
    root._seatWrites++
    root._lastWriteTag = owner
    if (owner !== "follow") root._followIdx = -1
    if (owner !== "pursuit") root._pursuitIdx = -1
     if (animated === true) {
       let distanceMs = root.stepMs(Math.abs(target - root.contentY))
       if (paceMs > 0) {
         distanceMs = Math.min(distanceMs,
           Math.max(Ui.fastMs, Math.min(root._sweepMaxMs, Math.round(paceMs))))
       }
       const handoffMs = root._highlightHandoff && root._sweepMs >= 0
         ? root._sweepMs : 0
       scrollAnim.duration = Math.max(distanceMs, handoffMs)
       scrollAnim.to = target
       // Re-aiming a running tween by moving `to` alone does NOT work in
       // this engine: the endpoints are captured when the animation
       // starts, so a retarget is silently ignored and the tween lands on
       // the target it was armed with. Every restart is therefore a new
       // ease from zero velocity, which is what a stutter looks like.

       scrollAnim.restart()
       // Bar/content sync: the highlight tween runs the same duration on
       // the same curve (see _sweepMs), so both land together with no
       // end-of-glide wobble. Assigned after restart: a synchronously
       // firing finish from the superseded run must not clear it first.
       root._sweepMs = scrollAnim.duration
     } else {
       scrollAnim.stop()
       if (!root._highlightHandoff) root._sweepMs = -1
       root.contentY = target
     }
    return target
  }

  // --- follow policy ---

  // Center scrolloff: the cursor row rides near the middle of the
  // view, clamped to real bounds.
  // Short lists (content fits the viewport) never move the view.
  // scrolloff > 0 holds the view while the cursor stays within that
  // many rows of its current viewport slot; crossing the margin glides.
  // Centered seat target from live geometry (delegate positions when
  // instantiated, table fallback otherwise). Pure: no holds, no side
  // effects - followTarget adds the hold policy, the retarget below
  // re-derives this mid-flight while layout shifts under a running
  // follow tween (collapsing slots above the cursor).
  //
  // viewH is the height of the viewport the row is being placed in, for a
  // consumer whose viewport is still growing to it. The centre of a
  // viewport that is not the one the row will sit in is the centre of a
  // viewport that no longer exists, and the place it names is out of the
  // scroll range the moment the viewport grows - so the engine corrects
  // the view to it, visibly, as it grows. A consumer that knows the height
  // its viewport is growing to says so, and the placement names the centre
  // of the viewport the row is going to be in. 0 = the height the viewport
  // has now.
  function centerTarget(index, viewH) {
    if (index < 0 || index >= root.count) return -1
    const ry = root.rowTop(index)
    const live = root.itemAtIndex(index)
    const rh = live ? live.height : root.rowHeightAt(index)
    const vh = viewH > 0 ? viewH : root.height
    // The bound the placement is held to: the range the viewport will have
    // when it has grown to the height it is growing to. A placement outside
    // it is corrected by the engine as the viewport grows - a visible drag
    // of the content - so the placement is held inside it from the start.
    const bound = viewH > 0
      ? Math.max(0, root.tableTotal() - vh)
      : root.clampY(Infinity)
    return Math.max(0, Math.min(ry + rh / 2 - vh / 2, bound))
  }
  // Pure follow target: the contentY followCursor would seat to, or
  // -1 when it would hold (fits/degenerate/in-margin: no seat coming).
  // One definition feeds the seat and the bar pre-arm below, so the
  // sweep duration always matches the actual seat distance - pre-arming
  // from rowTop overshot centered seats by half a viewport (~40ms of bar
  // lag on center rows, invisible on top rows that hit the 120ms floor).
  // Index of the in-flight follow seat for the layout-shift retarget
  // below; -1 outside follow seats.
  property int _followIdx: -1
  // Index of the row whose open-slot pursuit put the contentY tween now in
  // flight, or -1 when the running seat is anything else. seatTo clears it
  // on every seat that is not a pursuit, so it describes the tween in
  // flight and never a past one.
  property int _pursuitIdx: -1
  function followTarget(index, viewH) {
    if (index < 0 || index >= root.count) return -1
    // Never seat into a degenerate viewport (open path settles before
    // layout): a to=17 seat at viewH=0 parks a 17px cut that later seats
    // must repair. The cursor is already assigned; the first laid-out
    // seat corrects scroll.
    if (root.height <= 0) return -1
    if (root.tableTotal() <= root.height) return -1
    if (root.restingContentHeight > 0 && root.restingContentHeight <= root.height) return -1
    // ... and never seat from an estimated table while the live layout
    // fits: fresh-page averages (or a polluted table) claim scroll room
    // the real content does not have, parking a stale offset (18px on a
    // fitting page) that only a later clamp repairs. Either source
    // proving fits holds the seat.
    if (root.contentHeight > 0 && root.contentHeight <= root.height) return -1
    const ry = root.rowTop(index)
    // Live delegate height wins like rowTop does (same staleness
    // argument); trackCursor usually measured it a line above already.
    const live = root.itemAtIndex(index)
    const rh = live ? live.height : root.rowHeightAt(index)
    if (root.scrolloff > 0) {
      const margin = root.scrolloff * rh
      if (ry - margin >= root.contentY
        && ry + rh + margin <= root.contentY + root.height) return -1
    }
    return root.centerTarget(index, viewH)
  }
  function followCursor(index, animated, viewH) {
    const t = root.followTarget(index, viewH)
    if (t < 0) return
    root._followIdx = index
    root.seatTo(t, animated === true && root.smoothScroll, "follow")
  }

  // Exact cursor seat: measured geometry when the delegate exists,
  // bounded retries while it instantiates, seat-in-place on give-up.
  // Learns every live delegate first (small lists only): unselectable
  // rows (separators) are never visited, so visit-only learning leaves
  // them at the average forever - 12px separators estimated at 47px
  // inflate the table past the viewport and defeat the fits hold with
  // spurious seats. measureGuard still filters each row (open slots
  // never relearn), big lists keep visit-learning (uniform rows there).
  function learnLive() {
    if (root.count > Ui.listFullRows) return
    for (let i = 0; i < root.count; i++) {
      const d = root.itemAtIndex(i)
      if (d) root.noteMeasured(i, d.height)
    }
  }
  function trackCursor(index, animated, viewH) {
    if (index < 0 || index >= root.count) return
    root.learnLive()
    const first = root.itemAtIndex(index)
    if (first) {
      root.noteMeasured(index, first.height)
      root.followCursor(index, animated, viewH)
      return
    }
    const e = root._seatEpoch
    const retry = (n) => {
      if (e !== root._seatEpoch || root.currentIndex !== index) return
      const live = root.itemAtIndex(index)
      if (live) {
        root.noteMeasured(index, live.height)
        root.followCursor(index, animated, viewH)
        return
      }
      if (n < 8) Idle.run(() => retry(n + 1), 2)
      else root.followCursor(index, animated, viewH)
    }
    retry(0)
  }

  // --- keyboard navigation ---

  // Step `dir` (+1/-1) to the next selectable index. With wrap:true
  // (menu) it cycles - last to first glides through the step tween
  // when smoothScroll is on; with wrap:false it clamps at the ends.
  // Returns true when the current index changed.
  function move(dir, highlightMs) {
    const count = root.count
    if (count === 0) return false
    if (dir === 0) return false
    // User motion re-arms highlight glide via seat "step", so a step
    // taken while rows are still landing eases as usual.
    const from = root.currentItem
    const fromSlotMs = from && typeof from.slotMotionMs === "number"
      ? from.slotMotionMs : 0
    let i = root.currentIndex
    // An unseated cursor (currentIndex -1) has no row to step from, so
    // step one extra place before wrapping: down/right enters on row 0,
    // up/left on the last row. Stepping from -1 directly lands a row
    // short of the top end - (-1 - 1 + count) % count is count - 2 -
    // which is what a list that starts its cursor unset would do on its
    // very first keypress. GridList.moveRow/moveCell special-case the
    // same state (GridList.qml:154, :174).
    if (i < 0) i = dir > 0 ? -1 : count
    for (let n = 0; n < count; n++) {
      if (root.wrap) {
        i = (i + dir + count) % count
      } else {
        i += dir
        if (i < 0 || i >= count) return false
      }
      if (root.isSelectable(i)) {
        if (i === root.currentIndex) return false
        // Wrap laps streak the bar across the list while the seat tween
        // glides contentY there; fitting-list wraps keep the bar glide as
        // their only motion (content never scrolls there). A snapped bar
        // was proven unnecessary: the native follower does not preempt a
        // gliding seat, so both motions coexist without fighting.
        // Bar/content sync: pre-arm the sweep duration from the true
        // follow target BEFORE the index write below, because the
        // highlight tween launches on the assignment with whatever
        // duration is current (mid-flight duration changes are ignored).
        // followTarget returns -1 on holds: default glide then.
         const ft = root.followTarget(i)
         const requestedMs = typeof highlightMs === "number" && isFinite(highlightMs)
           ? highlightMs : fromSlotMs
         const focusMs = requestedMs > 0
           ? Math.max(Ui.fastMs, Math.min(Ui.slowMs, Math.round(requestedMs))) : 0
         const handoff = fromSlotMs > 0
           || (typeof highlightMs === "number" && highlightMs > 0)
         root._highlightHandoff = handoff
         root._sweepMs = focusMs > 0 ? focusMs
           : (ft < 0 ? Ui.fastMs : root.stepMs(Math.abs(ft - root.contentY)))
         root.seat(i, "step")
         // No seat started (hold/no-op/instant) - release the pre-arm so
         // the bar keeps its default glide instead of a stale sweep.
         if (!scrollAnim.running && !root._highlightHandoff) root._sweepMs = -1
        return true
      }
      if (!root.wrap && n === count - 1) return false
    }
    return false
  }

  // --- keyboard navigation contract (NavKeys.js, IslandNav.qml) ---
  //
  // The island key router does not know what a list is. It calls moveBy with
  // a direction and activate for Enter on whatever object the content
  // declared as its `islandNavTarget`; a list is one shape of that target,
  // and these two functions are the whole wiring an island does.
  //
  // A 1-D list projects the two-dimensional direction onto the row axis
  // (NavKeys.project): a vertical step wins when both are set, because a
  // diagonal is not a key anyone presses, and Left/Right read as previous and
  // next - which is the only useful meaning they have on a single column.
  function moveBy(dx, dy): bool {
    const dir = NavKeys.project(dx, dy)
    if (dir === 0) return false
    return root.move(dir)
  }

  // Draw the keyboard cursor as a FOCUS BORDER on the current row instead of
  // the shared sliding selection bar. Default off, because the bar is right
  // for a plain list and wrong for a banded one - a bar behind a zebra stripe
  // reads as "this row is brighter", not "the cursor is here".
  //
  // A border is a per-delegate decoration, so it lives in the delegate rather
  // than in this file's chrome: the delegate is the only thing that knows
  // where its own edges are, and a cursor drawn by the view would have to
  // guess at a delegate's insets.
  property bool focusBorder: false
  // One flag for "a row can take the cursor", exposed so a delegate does not
  // have to re-derive the currentIndex === index comparison and risk answering
  // the cursor for a row `isSelectable` refuses.
  readonly property bool cursorVisible: root.currentIndex >= 0

  // Enter on the current row. A delegate that implements activate() owns the
  // press (a row with an action of its own), and anything else reports
  // through `activated` so a consumer that binds the click on the row itself
  // still gets the keyboard. False when there is no row to act on, which is
  // also what keeps a router from consuming an Enter nothing answered.
  function activate(): bool {
    const idx = root.currentIndex
    if (idx < 0 || idx >= root.count) return false
    const it = root._currentRow()
    if (it !== null && it !== undefined && typeof it.activate === "function") {
      it.activate()
      return true
    }
    root.activated(idx)
    return true
  }

  // Land on the nearest selectable index at or after `index`. snap
  // forces an instant seat (restores never ease); steps follow the
  // center policy.
  //
  // viewH is the height of the viewport the row is being placed in, for a
  // consumer whose viewport is still growing to it (see centerTarget).
  function settle(index, snap, viewH) {
    const count = root.count
    if (count === 0) {
      // Transient reset gap, not an empty list: the model was assigned
      // but the view has not laid it out yet (count still reads 0 this
      // turn). Aborting here drops the snap seat and re-arms durations
      // mid-choreography, stranding contentY wherever the old list left
      // it - and a later follow then eases that stale position home as a
      // visible slide. Hold the gate and retry bounded instead; a
      // genuinely empty model still lands here and re-arms on give-up.
      // Any seat meanwhile bumps the epoch and retires the retry, so a
      // fresher choreography can never fight this one.
      const e = root._seatEpoch
      const retryIdx = index, retrySnap = snap, retryH = viewH
      const retry = (n) => {
        if (e !== root._seatEpoch) return
        if (root.count > 0 || n >= 4) {
          if (root.count === 0) {
            root._stillPreempt()
          } else root.settle(retryIdx, retrySnap, retryH)
          return
        }
        Idle.run(() => retry(n + 1), 2)
      }
      Idle.run(() => retry(0), 2)
      return
    }
    let i = Math.min(Math.max(0, index), count - 1)
    for (let n = 0; n <= count; n++) {
      const probe = (i + n) % count
      if (root.isSelectable(probe)) {
        // Programmatic landing: the lease holds the bar still across
        // the displaced flight; observed release re-arms the glide.
        // Durations stay held across the deferred follow below, until
        // displaced rows land or user motion pre-empts.
        root.seat(probe, "land", snap, viewH)
        return
      }
    }
    // No selectable row: nothing to hold the bar for.
    root._stillPreempt()
  }

  // Put a row where the follow policy puts it, without moving the cursor:
  // for a consumer that has already seated the cursor and only wants the
  // view to agree with it. Instant - the consumer says where the row
  // goes, so there is nothing to glide.
  //
  // viewH is the height of the viewport the row is being placed in, for a
  // consumer whose viewport is still growing to it (see centerTarget).
  function placeRow(index, viewH) {
    root.followCursor(index, false, viewH)
  }

  // Bring an index into view without moving the cursor beyond it.
  // Snap seats instantly; otherwise the center policy glides.
  // Scroll-only: seats no cursor and takes no landing lease, so the
  // bar keeps whatever duration the lease gate already holds.
  function reveal(index, snap) {
    if (index < 0 || index >= root.count) return
    if (snap === true) {
      const it = root.itemAtIndex(index)
      if (it) root.noteMeasured(index, it.height)
      root.seatTo(root.rowTop(index) + root.rowHeightAt(index) - root.height, false)
    } else {
      root.trackCursor(index, true)
    }
  }

  // Last-row reveal for open slots: claim the row and let the pursuit
  // decide. There is deliberately no seat of its own here. Bottom-aligning
  // the row is the right answer when a scroll is the only way to reveal it,
  // and it is wrong the moment the region can grow instead: it puts the
  // row's RESTING bottom on the region's edge, so the list scrolls by
  // exactly the amount the region is about to grow and the dropdown is
  // revealed by two motions at once. pursue() reads the same live bottom
  // the region's growth reads (revealNeedH), so it takes the growth's
  // silence when there is room to grow and seats when there is not - a
  // region already at its ceiling.
  function revealEnd(index) {
    if (index < 0 || index >= root.count) return
    root.autoRevealIndex = index
    root.pursue()
  }

  // Shared page motions: page steps clamp contentY by viewport height
  // factor; end jumps seat the cursor at the ends and follow.
  function pageBy(factor) {
    const target = Math.min(Math.max(0, root.contentY + root.height * factor),
      root.clampY(Infinity))
    root.seatTo(target, root.smoothScroll)
  }
  function jumpEnd(last) {
    const n = root.count
    if (n === 0) return
    // User motion re-arms highlight glide via seat "step", as in move().
    let t = -1
    if (last) {
      for (let i = n - 1; i >= 0; i--) {
        if (root.isSelectable(i)) { t = i; break }
      }
    } else {
      for (let i = 0; i < n; i++) {
        if (root.isSelectable(i)) { t = i; break }
      }
    }
    if (t < 0) return
    const jt = root.followTarget(t)
    root._sweepMs = jt < 0 ? Ui.fastMs : root.stepMs(Math.abs(jt - root.contentY))
    root.seat(t, "step")
    if (!scrollAnim.running) root._sweepMs = -1
  }

  // Exact restore seat: cursor index plus absolute scroll offset, no
  // motion. Out-of-range indices clamp; non-selectable indices scan
  // forward with wrap. A guarded re-apply covers measurement drift.
  function restoreAt(index, y) {
    const count = root.count
    if (count <= 0) return
    let i = Math.min(Math.max(0, index), count - 1)
    let found = false
    for (let n = 0; n < count; n++) {
      const probe = (i + n) % count
      if (root.isSelectable(probe)) {
        i = probe
        found = true
        break
      }
    }
    if (!found) return
    // Restore-sweep window (compat protocol): consumers gate persistence
    // and quiet checks on _sweeping during the restore (menu), and may
    // close it early via _endSweep. Self-closes after the re-seat for
    // consumers that never call _endSweep.
    const token = ++root._restoreToken
    root._sweeping = true
    // Restore landing: the lease holds the bar still across the re-seat;
    // the absolute scroll below overwrites the center follow at once, so
    // no frame lands between the two. Observed release re-arms the glide.
    root.seat(i, "land")
    root.seatTo(y, false, "restore")
    const e = root._seatEpoch
    Idle.run(() => {
      if (token !== root._restoreToken) return
      if (e !== root._seatEpoch) {
        root._sweeping = false
        return
      }
      // The bail branch MUST close the sweep window too: a stuck
      // _sweeping suppresses auto-follow for the whole session in
      // consumers that never call _endSweep (clipboard).
      root._sweeping = false
      if (root.currentIndex !== i) {
        return
      }
      root.seatTo(y, false, "restore-retry")
    }, 2)
  }

  // Compat: closes the restore-sweep window early (menu calls this once
  // its back-navigation seat has settled). Idempotent. Re-arms animated
  // seats and highlight motion - the restore window runs instant.
  // Composes with the lease: closing the window releases the landing
  // hold it arrived with, so a wrap one frame later still glides.
  function _endSweep() {
    root._sweeping = false
    root._stillPreempt()
  }

  // --- scroll preservation across model swaps ---

  // Bind `stableModel` instead of `model` when the list's data is
  // replaced wholesale: position is captured before the swap and
  // re-applied until the re-layout settles.
  property var stableModel: undefined
  onStableModelChanged: {
    const y = root.contentY
    root.model = root.stableModel
    if (y <= 0) return
    const e = root._seatEpoch
    const retry = (n) => {
      if (e !== root._seatEpoch) return
      root.seatTo(y, false)
      if (n < 4) Idle.run(() => retry(n + 1), 2)
    }
    retry(0)
  }

  // --- swap machinery ---

   // Scroll position across a swap. Replacing the model resets the view to
  // the top of a list that was scrolled somewhere else, and the view puts
  // the old offset back a frame later - so a list with room to scroll
  // paints its first entry for a frame and then snaps back down. This is
  // the same loss the bar geometry is held across, and the same hold is
  // what repairs it.
  //
  // But the offset cannot simply be written back once. A model write does
  // not only move the view, it destroys the delegates that were giving the
  // content its extent, and the replacements report their floor until their
  // payload lays out. Every bound derived from that half-built content is
  // short, and Qt enforces the same short bound on contentY - so a single
  // restore in the write's own turn lands the view where the transient
  // content put it, and nothing walks it back: the healed bound only ever
  // admits what is already there. That is the whole-list jump. The view
  // leaves, a later reveal glides it the rest of the way back, and the user
  // watches the list do both.
  //
  // So the offset is HELD, the way the bar's geometry is held: re-asserted
  // while the content re-measures, bounded by the live extent (the only
  // bound that grows with the heal) and never by the height table, which
  // the write cleared and the replacement rows have not refilled yet. Each
  // contentHeight change moves the bound up with the content, so the view
  // arrives at the healed position on the frame the content heals, rather
  // than settling short and being pulled back by whatever seats next.
  property real _swapY: 0
  // Whether the captured offset is still being re-asserted, and the watch
  // that decides when it stops.
  property bool _swapHold: false
  property int _swapHoldTurns: 0
  property int _swapHoldStable: 0
  property double _swapHoldH: -1
  property int _swapHoldWrites: 0

  function beginSwap() {
     root._swapToken++
     root._inSwap = true
     root._highlightHandoff = false
     root._sweepMs = -1
     scrollAnim.stop()
     root._swapY = root.contentY
     // A swap supersedes any hold still running: the offset it captured is
     // the one this write is about to move.
     root._swapRelease()
     // Last moment the cursor row still exists: hold the bar's geometry
     // here, so the frames a model swap spends without a row to read keep
     // the plate instead of collapsing it to nothing and popping it back.
     if (root.selectionHighlight) root._holdHighlight()
     return root._swapToken
  }
  function endSwap() {
    root._inSwap = false
    root._swapEndMs = Date.now()
  }
  // Where the captured offset sits against the content as it stands NOW.
  // -1 when there is no content to bound it, which is the one frame of a
  // swap where nothing is writable and the hold says so rather than
  // answering 0 and pulling the view to the top.
  function _swapWant() {
    if (root.contentHeight <= 0) return -1
    return Math.min(root._swapY, Math.max(0, root.contentHeight - root.height))
  }
  function _swapRestore() {
    if (!root._swapHold) return
    const want = root._swapWant()
    if (want < 0 || Math.abs(want - root.contentY) < 0.5) return
    root.seatTo(want, false, "swap-restore")
  }
  // Whether the hold still owns contentY, which is the question every entry
  // into the restore has to ask first: a seat that moved the view and was
  // not the hold's own has said where the view belongs, and re-asserting
  // over it would stop the very tween that seat started. A seat that landed
  // where the view already stood has not said anything - that is what the
  // index echo a model swap deals the view looks like, and the hold has to
  // outlive it or it releases on the frame the heal needs it.
  function _swapHoldsContentY() {
    return root._seatWrites === root._swapHoldWrites
      || root._lastWriteTag === "swap-restore"
  }
  function _swapArm() {
    root._swapHold = true
    root._swapHoldTurns = 0
    root._swapHoldStable = 0
    root._swapHoldH = -1
    root._swapHoldWrites = root._seatWrites
    swapWatch.restart()
  }
  // Every exit from the hold goes through here, because the watch is a
  // running timer and a hold that released without stopping it would leave
  // this list waking once a frame for the rest of the session.
  function _swapRelease() {
    root._swapHold = false
    swapWatch.stop()
  }
  // The hold's restore is event-driven - every contentY and contentHeight
  // change re-asserts it, which is what puts the view where the content says
  // it belongs on the same change, before the frame paints. The timer only
  // decides when the hold gives contentY back, and it has to be a timer
  // rather than a callLater chain: deferred turns drain inside a single
  // frame, so a chain retires before the relayout the hold exists for has
  // run at all. One tick a frame, bounded, never a spin.
  Timer {
    id: swapWatch
    interval: Math.max(8, Math.round(Ui.fastMs / 8))
    repeat: true
    onTriggered: root._swapWatch()
  }
  // The watch runs exactly while the hold is up. A release that left it
  // running would keep this list waking once a frame for the rest of the
  // session to do nothing, and nothing else in the file would say so.
  readonly property bool _swapWatching: swapWatch.running
  // Observed release. Absent another writer - see _swapHoldsContentY - the
  // hold gives contentY back once the content has stopped measuring with
  // the position it wanted, for two ticks running, so the heal cannot land
  // between them and be missed.
  function _swapWatch() {
    if (!root._swapHold) return
    if (!root._swapHoldsContentY()) {
      root._swapRelease()
      return
    }
    root._swapHoldTurns++
    root._swapRestore()
    root._swapHoldWrites = root._seatWrites
    const want = root._swapWant()
    const settled = want >= 0 && Math.abs(want - root.contentY) < 0.5
    if (settled && root.contentHeight === root._swapHoldH
      && root._swapHoldTurns >= 3) {
      root._swapHoldStable++
    } else {
      root._swapHoldStable = 0
    }
    root._swapHoldH = root.contentHeight
    // The turn cap is what makes this self-healing: time passes whether or
    // not anything else runs, so a hold nobody retires still cannot outlive
    // its own swap by more than its own cap.
    if (root._swapHoldStable >= 2 || root._swapHoldTurns >= 24) {
      root._swapRelease()
      return
    }
  }
  // Shared model-swap choreography: begin, run the caller's seat
  // lambda inside the swap window, hold the scroll the write dropped,
  // then deferred guarded close. The landing seat inside acquires the
  // stillness lease; the close only ends the window and stamps the recency
  // term, while observed release re-arms the glide. Panels pass their
  // generation counter as `gen` and a live check as `isLive` so a newer
  // swap wins over a stale close.
  function swapRun(gen, isLive, settleFn) {
    const token = root.beginSwap()
    // A consumer that seats inside the window has said where the view
    // belongs, and seating is the one thing that bumps the epoch - so the
    // hold below stands down rather than undoing the seat it just made.
    const e = root._seatEpoch
    settleFn()
    if (root._swapY > 0 && e === root._seatEpoch) {
      root._swapArm()
      root._swapRestore()
    }
    Idle.run(() => {
      if (token !== root._swapToken) return
      if (!isLive(gen)) { root._inSwap = false; root._swapEndMs = Date.now(); return }
      root.endSwap()
    }, 2)
  }

  // --- pursuit (open-slot reveal) ---

  property int autoRevealIndex: -1
  property bool autoRevealEnabled: true
  property bool pursuitAnimated: false
  property var autoRevealItem: null
  signal motionFinished()

  // The region height a surface is GROWING TOWARD for the live claim, or -1
  // when it is not growing the region for one. -1 default: with no surface
  // claiming the reveal, this list owns it outright, which is the behaviour
  // every list that is not inside a card already has.
  //
  // A plain property, written by the surface from a change handler, and never a
  // binding. The surface sizes its region FROM the claim, so a binding here
  // would close a loop through the height - the same reason the claim itself is
  // plain content-space geometry (see revealNeedH).
  //
  // It exists because "is the region short of the claim" is not a question
  // this list can answer. Its own best guess - comparing the claim against the
  // height it is showing - is wrong in both directions at once: while the
  // region is TWEENING toward the claim the height is still short, which is
  // right, and the moment it lands the two are equal and the list takes over,
  // which is also right. But the surface may REFUSE the growth entirely (a
  // dropdown taller than the screen is not shown, the list scrolls it), and
  // then the height never reaches the claim and a height-based test would
  // suppress the pursuit forever, leaving the row off-screen. The surface knows
  // whether it took the claim; this is it saying so.
  property real growthH: -1

  // "The reveal is the region's, not mine": true once a region has LANDED at
  // a target that satisfies the claim on its own. The surface sizes its
  // region to `claim - <where the content will sit> + Ui.s`
  // (MenuPanel.growForSlot), and a landed region that carries the claim
  // leaves the fall-through in pursue() owing nothing.
  //
  // A region that is still TRAVELLING is not one of those. Treating it as
  // one is what makes the growth and the scroll mutually exclusive: a row
  // taller than the resting region grows by the
  // whole deficit with the list pinned, so the entries above it stay
  // fully visible and the window takes the entire unfold downward. The
  // region's target assumes the list scrolls its share at the same
  // time - it is sized against where the content WILL sit, not where it
  // is - so silencing the list mid-flight is what pins it there.
  //
  // Two things keep that from becoming a second writer. The region's target
  // is derived from the row's top, which is a settled constant for the whole
  // unfold, so it does not move as the list scrolls; and the seat the list
  // takes is the same `rowTop` (pursue caps its own target there), so the
  // two converge on one geometry instead of negotiating it frame by frame.
  //
  // The landed test is the exact complement of the `owed` test in pursue(),
  // down to the same half-pixel tolerance, and that is deliberate: it used
  // to be the same inequality written the OTHER way round, which was
  // invisible while the region was sized against the CURRENT scroll offset
  // (it then always compared equal and never fired) and became the silence
  // that stranded the list as soon as the region was sized against a
  // DIFFERENT one. A region satisfies the claim when `claim + margin -
  // contentY` fits inside it, so a left side that is too LARGE is the region
  // falling short - the one case the list still has to move for.
  function _regionOwnsReveal(claim) {
    if (!(claim > 0) || !(root.growthH > 0)) return false
    // En route: the growth is going to satisfy this claim TOGETHER WITH a
    // seat, so the list is not finished being owed.
    if (root.growthH > root.height + 0.5) return false
    // Arrived, and it carries the claim on its own.
    return claim + Ui.s - root.contentY <= root.growthH + 0.5
  }

  function bindAutoRevealItem() {
    const index = root.autoRevealIndex
    const next = index >= 0 ? root.itemAtIndex(index) : null
    if (root.autoRevealItem !== next) root.autoRevealItem = next
  }

  // The claimed row's destination bottom edge, in content coordinates, or -1
  // when nothing is claimed (or the region could never reach it). The claim is
  // the library's and the region is the surface's, so this is the one number
  // that connects them: a surface that can grow tweens to it over
  // revealSlotMs (see MenuPanel._latchClaim, PanelCard.slotRegionH).
  //
  // WHO reveals the claim is the consumer's question, not this binding's: the
  // library answers "where does this row end", and a surface that has a region
  // compares that against what it is already showing. Answering it here would
  // mean reading this view's own height or its scroll offset, and the surface
  // sizes its region FROM this number - so the decision would close a loop
  // through the height and Qt would drop the value.
  //
  // HOW MUCH is the row's SETTLED bottom, and that is the whole contract: the
  // value is CONSTANT for the whole unfold, so a surface can animate to it
  // instead of chasing it. Two things fall out of that. The split of the
  // reveal cannot flip mid-unfold, so the region and the seat are not
  // negotiating frame by frame - each is computed from this number and from
  // the row's top, both of which stand still, and a decision re-taken per
  // frame is exactly what put a bottom row's dropdown through a crossover it
  // jumped at. And the close has a target at all: the settled height drops to
  // zero the instant a slot starts closing, so a LIVE-height claim would
  // vanish on the first tick of the close and the region would snap shut with
  // no animation. A constant target is what lets both directions be a tween
  // running at the slot's own speed.
  readonly property real revealNeedH: {
    const index = root.autoRevealIndex
    if (index < 0 || index >= root.count || root._inSwap) return -1
    // The row's destination bottom edge, in CONTENT coordinates, and nothing
    // else. Content-side is not a stylistic choice, it is the only shape that
    // cannot loop: a surface sizes its region from this number, so every term
    // here has to be independent of that region. Three are not, and all three
    // were read in earlier versions of this:
    //
    //   root.height     the region itself
    //   root.contentY   clamped against that region - onContentHeightChanged
    //                   reconciles the position through clampY, so contentY
    //                   is a function of the height
    //   itemAtIndex()   reaches the delegate through the view, and a resize
    //                   is what makes the view lay out
    //
    // Any one of them closes height -> revealNeedH -> height, which Qt answers
    // by dropping the value and reporting a binding loop. A surface that wants
    // a region height subtracts the scroll position it is sizing for - the
    // row's top, or the offset it is already at, whichever is further along -
    // and compares that against its own ceiling, and does so imperatively for
    // the same reason (see MenuPanel.growForSlot / _latchClaim).
    //
    // The row is reached through autoRevealItem, which the claim path already
    // binds and refreshes, rather than through a fresh itemAtIndex() call -
    // that call goes through the view, and a resize is what makes the view lay
    // out, so it is a dependency on the region by another name.
    //
    // So: pure arithmetic, and nothing read that a resize can invalidate. That
    // includes helpers - a function called from a binding may not read a
    // property the binding has not already read, because every read registers
    // as a dependency of that binding. A helper that reads more than the
    // binding it serves changes the behaviour it observes, which is worse than
    // having no helper.
    const it = root.autoRevealItem
    if (!it || !(it.height > 0)) return -1
    return it.y + root.rowSettledHeight(it, it.height)
  }

  // How long the claimed row's own slot takes to open or close, or 0 when
  // nothing is claimed. A surface animating to revealNeedH uses THIS as the
  // duration, so the region and the dropdown move at one speed in both
  // directions instead of the region arriving on its own clock. -1 rather
  // than 0 when a claim is live, because 0 is a legal duration a consumer
  // might read as "snap" and a live claim is never that.
  readonly property int revealSlotMs: {
    const index = root.autoRevealIndex
    if (index < 0) return 0
    const it = root.autoRevealItem || root.itemAtIndex(index)
    if (!it) return 0
    const ms = typeof it.slotMotionMs === "number" ? it.slotMotionMs : -1
    return ms > 0 ? Math.round(ms) : -1
  }

  // A pursuit tween re-aims itself. The claimed row keeps growing under
  // the tween, so every height step re-derives the bottom-align target and
  // must bend the tween that is already running: waiting it out lands the
  // row however far it grew after the tween was last armed, and the
  // dropdown ends up short of its own track.
  //
  // Invariant: the in-flight tween is re-aimable only when this row put it
  // there - by this row's own pursuit (_pursuitIdx) or this row's own
  // follow (_followIdx). _followIdx is -1 whenever no follow seat is
  // running, which is no row's claim at all and never a veto; a follow for
  // a different row, and any other seat (page/reveal/restore/reconcile,
  // which seatTo clears _pursuitIdx for), is left running untouched.
  function pursue() {
    if (!root.autoRevealEnabled) return
    if (root.autoRevealIndex < 0) return
    if (root.autoRevealIndex >= root.count) {
      root.autoRevealIndex = -1
      return
    }
    if (root.moving || root._inSwap) return
    const index = root.autoRevealIndex
    const mine = root._followIdx === index || root._pursuitIdx === index
    const it = root.autoRevealItem || root.itemAtIndex(index)
    if (!it) {
      const ry = root.rowTop(index)
      let target = Math.max(0, Math.min(
        ry + root.rowHeightAt(index) + Ui.s - root.height,
        root.clampY(Infinity)))
      if (ry < target) target = ry
      if (target > root.contentY + 0.5
        && (!scrollAnim.running || mine)) {
        root._pursuitIdx = index
        root.seatTo(target, root.pursuitAnimated && MotionPolicy.enabled, "pursuit")
      }
      return
    }
    const ry = it.y
    // A growth claim does NOT own this reveal on its own, and the list must
    // still chase it. The region is sized against where the content WILL sit
    // (SlotGrowth subtracts the row's top, not the current offset), so it is
    // asking for the stretch of the deficit no scroll can reach and leaving
    // the rest to the seat below. A region sized for a list that stands still
    // would be the whole deficit, and then
    // the entries above a tall dropdown stay fully visible while the
    // window grows past its own bottom border to carry it.
    //
    // What keeps the two from fighting is that neither target moves: the
    // region's is the row's top, and the seat's is capped at the same number
    // two lines below (`if (ry < target) target = ry`), so both arrive at one
    // geometry rather than negotiating it per frame. The claim is
    // settled-derived and constant for the unfold, so the split cannot flip
    // between the two halves mid-unfold - and it stays alive through the
    // CLOSE, where a region is folding back and the list owes the row nothing
    // once it has landed.
    //
    // Reading the claim rather than re-deriving the decision from geometry is
    // what keeps that to one number and one answer: a region that has landed
    // and satisfied it is the only thing that silences this pursuit, and that
    // is the same test the surface's own arithmetic is built on.
    //
    // Reading contentY and height HERE is safe and reading them in the claim
    // binding is not: this runs from change handlers, outside the binding
    // graph, which is exactly why the comparison lives on this side of the
    // line (see revealNeedH).
    const claim = root.revealNeedH
    if (root._regionOwnsReveal(claim)) return
    // Where the row really ends is the SETTLED height: this seat rides to
    // the row's destination in one ease rather than chasing its current
    // frame (see rowSettledHeight). The same seat serves both halves of a
    // split reveal - the region takes the stretch past the row's top, this
    // takes the scroll up to it.
    const rh = root.rowSettledHeight(it, it.height)
    // Already revealed, MARGIN INCLUDED: the view owes this row nothing, and it
    // must not move. A slot is in-flow, so it does push the rows below it
    // down, but that is the content growing, not a row leaving the fold - the
    // view has no reason to follow it, and doing so scrolls the list for an
    // entry near the top that is plainly visible. A seat here was the single
    // change that made top rows drift upward on open.
    //
    // The SETTLED height, and the margin, and that combination is what makes
    // this the exact complement of the test above - the hole between the two
    // tests is where the bounce lives. The row's CURRENT frame against a
    // `-Ui.s` threshold, with the region sized to the claim
    // EXACTLY, is the combination this test exists to exclude: a region that
    // lands puts the row's settled bottom precisely
    // on the region's edge: `over` reads 0 where this test wants -2, the
    // pursuit falls through and seats 2px, and those 2px move the scroll
    // offset that the region's own arithmetic reads, which retargets the
    // region, which starts a tween, which moves the height read here. The
    // live session's symptom is a card bouncing back and forth on some opens
    // and not others, because which way it goes depends on whether the pixel
    // arithmetic falls on the near or the far side of a threshold - which is
    // exactly what "sometimes" means.
    //
    // One shared expression, on the settled row, with the margin on both
    // sides, closes it: a region sizes itself to `claim - <where the content
    // will sit> + Ui.s` (MenuPanel.growForSlot), so a landed region satisfies
    // this with a whole pixel to spare and a short one fails the test above
    // instead. There is nothing left for the two writers to alternate over.
    const owed = ry + rh + Ui.s - root.contentY - root.height
    if (owed <= 0.5) return
    let target = Math.max(0, Math.min(
      ry + rh + Ui.s - root.height,
      root.clampY(Infinity)))
    if (ry < target) target = ry
    if (target <= root.contentY + 0.5) return

    if (scrollAnim.running && !mine) return
    // A pursuit tween is NOT re-armed while it is in flight. seatTo always
    // restarts, and restart() re-reads `from` at the current value, so a
    // re-arm once per frame begins the easing from zero every time and the
    // scroll advances by a fraction of what the target just moved. The
    // result is a crawl: the dropdown finishes opening and the list is still
    // catching up a beat later, which is the delay a bottom entry shows and
    // a row with room to grow never does - a row with room never scrolls.
    // Seat once and let the tween run its full course; the landing re-arms
    // for whatever it did not reach (see scrollAnim.onFinished), so the
    // reveal arrives as whole eased legs rather than a stalled chase.
    if (scrollAnim.running && root._pursuitIdx === index) return
    root._pursuitIdx = index
    // Make the view's own extent honest before writing a position inside
    // it. Qt applies a resized delegate to the rows BELOW it on its own
    // schedule, so mid-unfold contentHeight understates the truth - and
    // QQuickFlickable enforces bounds from THAT number. The consequence is
    // a second writer on contentY: the view pulls the position back into
    // its stale bounds while the reveal tween eases toward the real one.
    //
    // Once per seat, and only here. It belongs to the write, not to
    // seating in general: forceLayout is a full relayout, so flushing on
    // every height step of an unfold kept the extent permanently behind
    // (each flush re-measured the delegate that was mid-animation) and a
    // view whose extent never settles clamps every tween back to nothing,
    // so the list stopped scrolling at all. By the time a seat is armed the
    // row has published its settled height and there is nothing to wait
    // for; after the flush the view's bounds and the measured extent
    // agree, and the clamp has nothing left to do.
    const settledTotal = root.settledTotal()
    if (settledTotal > 0 && root.contentHeight < settledTotal - 0.5) {
      root.forceLayout()
    }
    // The scroll rides the slot's own pace when that is the quicker of the
    // two: a long chase runs with the unfold and the region's growth
    // instead of arriving after them, while a short seat keeps the
    // distance pace (seatTo caps the override at it, so a remainder never
    // crawls at a full unfold's duration). A claim with no published pace
    // (or none at all) keeps the distance pace.
    const paceMs = root.revealSlotMs > 0 ? root.revealSlotMs : -1
    root.seatTo(target, root.pursuitAnimated && MotionPolicy.enabled, "pursuit", paceMs)
  }

  onAutoRevealIndexChanged: {

    // A released claim leaves no seat ownership behind. _pursuitIdx is
    // ownership of the tween in flight by the row that put it there, and a
    // claim that is gone owns nothing - the row closed its slot, so the
    // position it was chasing is not owed any more.
    if (root.autoRevealIndex < 0) root._pursuitIdx = -1
    root.bindAutoRevealItem()
    root.pursue()
  }
  onAutoRevealEnabledChanged: root.pursue()
  onHeightChanged: {
    if (root.autoRevealIndex < 0) return

    root.pursue()
  }

  Connections {
    target: root.contentItem

    function onChildrenChanged() {
      root._noteDelegates()
      root.bindAutoRevealItem()
      root.pursue()
    }
  }

  Connections {
    target: root.autoRevealItem

    function onHeightChanged() { root.pursue() }
    function onYChanged() { root.pursue() }
  }

  property bool wheelSteps: true

  // --- wheel ---

  // Wheel stepping: one entry per notch, through move() so wheel and
  // keyboard share the follow policy and the single seat writer.
  // Native flick stays available via interactive: true (menu), which
  // auto-disables this handler.
  WheelHandler {
    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
    enabled: root.wheelSteps && !root.interactive
    onWheel: event => {
      root.move(event.angleDelta.y > 0 ? -1 : 1)
      event.accepted = true
    }
  }

  // --- user grabs ---

  // True when the claimed row is already fully revealed: its bottom edge
  // carries the Ui.s margin inside the viewport, so pursuit has nothing
  // left to chase. Live delegate first, height table otherwise - the same
  // geometry order pursue() reads.
  function _rowRevealed() {
    const index = root.autoRevealIndex
    if (index < 0) return true
    const it = root.autoRevealItem || root.itemAtIndex(index)
    const bottom = it
      ? it.y + it.height
      : root.rowTop(index) + root.rowHeightAt(index)
    return bottom + Ui.s <= root.contentY + root.height
  }

  onMovingChanged: {
    if (root.moving) {
      root._seatEpoch++
       scrollAnim.stop()
       root._highlightHandoff = false
       root._sweepMs = -1
       root._followIdx = -1
       root._pursuitIdx = -1
      // A grab suspends pursuit, it does not renounce it: pursue() skips
      // every step while `moving` is set, so a claim that outlives the
      // drag is picked up again on the first height step after release.
      // The claim is retired only when the grabbed view already shows the
      // claimed row whole, which is the flick landing where the claim
      // wanted the view anyway; a row still short of that keeps its claim,
      // because a slot that is still unfolding cannot re-establish one and
      // would otherwise grow out of view for the rest of its life.
      if (root._rowRevealed()) root.autoRevealIndex = -1
      // A grab is user motion: pre-empt any held landing lease.
      root._stillPreempt()
    }
  }

  // --- reconciliation ---

  onContentYChanged: {
    // A held swap offset answers its own writes and the engine's clamps
    // alike, and answers them in the turn they happen - a clamp that lands
    // after the content has stopped measuring is still the same event, and
    // the reconcile below cannot repair it: that path only pulls a view
    // that overshot back into range, never one left short of it.
    if (root._swapHold) {
      if (root._swapHoldsContentY()) {
        root._swapRestore()
        return
      }
      // Another writer owns contentY; the normal path below applies to it.
      root._swapRelease()
    }
    if (root._inSwap || root.moving || scrollAnim.running) return
    const maxY = Math.max(0, root.contentHeight - root.height)
    const oor = root.contentY < -0.5 || root.contentY > maxY + 0.5
    if (oor) {
      // The one direct contentY write outside seatTo, and the only place
      // the view can move without a tween. It fires whenever the bound
      // drops under the current position - which is what a CLOSING slot
      // does frame by frame as the content it displaced shrinks back, so
      // it can walk the view down in instant steps.
      scrollAnim.stop()
      root.contentY = root.clampY(root.contentY)
    }
  }

  // contentHeight settling must never strand the view past the real
  // end: growth clamps a stale contentY back into range (downward
  // only; clampY owns the real-bounds guard). Skipped mid-swap and
  // while a seat tween is in flight - that seat owns contentY this
  // frame and scrollAnim.onFinished reclamps on landing.
  onContentHeightChanged: {
    // A held swap offset IS this event's reconciliation: it puts the view
    // where the content that just measured says it belongs, which the clamp
    // below cannot do - that path only ever pulls a view that overshot back
    // into range, so it is blind to a swap that left the view SHORT of the
    // healed bound, which is exactly what a write under a half-built content
    // leaves behind. The heal moves the bound, and the hold walks the view
    // to it on this same change, before the frame paints.
    if (root._swapHold) {
      if (root._swapHoldsContentY()) {
        root._swapRestore()
        return
      }
      // Another writer owns contentY; the normal path below applies to it.
      root._swapRelease()
    }
    if (root._inSwap) return
    // Follow retarget: while a follow tween runs, layout shifts under
    // it (collapsing slots above the cursor) invalidate its fixed
    // target. Re-derive from live geometry instead of preserving a stale
    // position - the tween bends toward the moving target instead of
    // landing off and jumping back. Non-follow tweens keep the preserve
    // path below (their targets are absolute).
    if (scrollAnim.running && root._followIdx >= 0) {
      // Collapsing viewport (panel closing under a tween): freeze, never
      // re-derive into degenerate geometry.
      if (root.height <= 0) { scrollAnim.stop(); return }
      const t = root.centerTarget(root._followIdx)
      if (t >= 0) {
        scrollAnim.to = root.clampY(t)
        return
      }
    }
    if (scrollAnim.running) return
    root.seatTo(root.contentY, false, "reconcile")
    // A claim re-derived against the SETTLED extent. The reconcile above
    // only clamps: it puts the position back inside the new bound, and
    // nothing else re-derives the seat from it. That matters once the
    // region and the list share a reveal, because the bound both are read
    // against moves with the extent - a seat armed while the extent still
    // under-reported the row (Qt applies a resized delegate to the content
    // height on its own schedule) is clamped short and then has no owner.
    // The row then sits with its bottom under the region's edge, which is
    // the clipped dropdown, and the pursuit has no event left to hear:
    // the height and the position both stopped moving.
    //
    // pursue() is a no-op when nothing is owed, and the seat it takes is
    // capped at the same row top the region's own target is built from, so
    // this converges instead of alternating. No claim, no work.
    if (root.autoRevealIndex >= 0) root.pursue()
  }

  // --- base config ---

  // Breathing room below the last row (scrolls with the content).
  property real trailSpace: 0

  spacing: 2
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  // Small lists instantiate fully: with every delegate live the layout is
  // exact, so wrap seats land on real geometry and the engine never
  // resolves far-end estimates mid-traversal - the resolution is what
  // ratchets originY once per lap (growing top gap, persisting on the
  // instance). Proven offscreen: 19 variable rows drift origin 0->20 on
  // the first wrap at 300px, stay pinned at 0 across 8 laps fully
  // instantiated. Large lists keep the fixed buffer: exactness there
  // comes from uniform rows (estimate == real), and full instantiation
  // of 4-digit walls would be a rasterization storm. Bounds live in Ui
  // (listFullRows/listFullBuffer) like every other shared token.
  // autoCache (compat): the old engine exposed this opt-in; off restores
  // zero buffer. Consumers below rely on far-end wrap targets staying
  // instantiated (menu, launcher).
  property bool autoCache: true
  cacheBuffer: !autoCache ? 0 : (root.count < Ui.listFullRows ? Ui.listFullBuffer : 300)
  // Delegates are NOT recycled. The earlier `reuseItems: true` relied on
  // the invariant that every delegate paints purely from bindings (index/
  // model roles) and never from imperative per-row state set once at
  // creation. Real consumers (e.g. menu/Entry.qml) hold per-instance
  // imperative state and one-shot setup in Component.onCompleted, which
  // Qt does not re-run on recycle -- recycled delegates kept stale/empty
  // payloads while their rows stayed selectable (ghost rows). Correctness
  // of conditional reveals and model swaps outweighs the reuse micro-win;
  // the existing autoCache/listFullRows cap already bounds delegate cost.
  reuseItems: false
  keyNavigationEnabled: false
  // Non-interactive by default: no flick, no native wheel re-anchor.
  // Consumers set true explicitly for drag (menu).
  interactive: false
  // No snapping. Qt implements SnapToItem by writing contentY itself, which
  // makes it a second writer on the one property this file treats as
  // private to seatTo - and it is not a tween, so it lands as a step. The
  // snap points move whenever a delegate resizes, so an unfolding slot
  // re-aimed it every frame: measured on Cursor size, Qt wrote 49 into a
  // reveal tween running 0 -> 34, once per frame, the whole 120ms. That is
  // the jump - a hard step laid over the ease, every frame, in a direction
  // the ease was not going. Nothing here pages or sections, so there was
  // never a snap to take.
  snapMode: ListView.NoSnap

  // Applied as a view footer so the space scrolls with the content.
  footer: Component {
    Item {
      width: 1
      height: root.trailSpace
    }
  }

  // --- row-set motion ---
  //
  // Four transitions, all gated on `rowMotion`, and all of them a FALLBACK:
  // a per-row cross-fade for rows arriving or leaving, and a neighbour glide
  // for rows only being re-seated by that change. The consumer decides
  // whether a change is worth animating at all - the menu drives it from
  // whether the row set is gliding or was rebuilt wholesale (search, page
  // navigation, bundle load), where everything changes at once and there is
  // nothing to relate a slide to.
  //
  // The SLIDE half of the arriving/leaving pair is dead and is not restored.
  // It reads a travel from `ViewTransition.item`, which is null inside a
  // transition's `from` binding in this Qt, so the expression silently took
  // its 0 branch and no travel was ever applied - proven three ways on a bare
  // ListView: `ViewTransition.item`, `ViewTransition.targets` and the
  // animation's own `target` are all null at that point. What the eye reads
  // as movement is `addDisplaced` easing each row from wherever it was to
  // wherever it now belongs, which is why a newly created row and a row
  // pushed down by it read as two different motions. The opacity half is
  // unaffected - `from: 0` is a constant - so the fade always worked and the
  // slide never did. A real travel is expressible only where the item is
  // reachable: in the delegate.
  //
  // `remove` does not run at all. A `ListModel` remove destroys the delegate
  // inside the same turn, so by the time Qt would build the transition there
  // is nothing left to animate - which is why a row that leaves is not faded
  // here, and why anything that wants a departing row to move has to move it
  // BEFORE the removal is installed.

  add: Transition {
    enabled: root.rowMotion

    NumberAnimation { property: "opacity"; from: 0; to: 1; duration: Ui.fastMs }
  }

  remove: Transition {
    enabled: root.rowMotion

    NumberAnimation { property: "opacity"; to: 0; duration: Ui.fastMs }
  }

  // Neighbours easing into the slots the change left behind. Not faded: they
  // are not arriving or leaving, only being re-seated.
  addDisplaced: Transition {
    enabled: root.rowMotion

    Glide { property: "y" }
  }

  removeDisplaced: Transition {
    enabled: root.rowMotion

    Glide { property: "y" }
  }
}
