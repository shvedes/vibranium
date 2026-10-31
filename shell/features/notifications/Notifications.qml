pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import QtQuick
// Quickshell for the `Singleton` base and the LazyLoader the surface is
// instantiated through.
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications
import qs.common
// For Privacy.shareOn, the one forced-DND source that is not a compositor fact.
// A feature reading a service is ordinary here (OSD reads MediaState), and the
// boot descriptor names `privacy` in `dependencies` so the service is up and
// resolved before this singleton reads it.
import qs.services as Core
import "NotificationsLib.js" as NotificationsLib
import "../../common/text/UnitIpc.js" as UnitIpc

// Notification daemon and pile. Owns the tracked notifications, the deadline
// policy, the DND rules, the history, and the `notifications` IPC target. The
// surface is in NotificationsView.qml, the card is NotificationCard.qml and the
// per-notification lifetime is NotificationEntry.qml; this file is state and
// policy only, exactly like OSD.qml.
//
// Two facts shape the whole model, and both are about a lifetime the shell
// does not own:
//
//   1. The D-Bus server destroys a Notification the instant its client closes
//      it. Notify() emits `notification` and then, for an untracked
//      notification, closes and deletes it synchronously - so `tracked = true`
//      is the first statement of the handler below and nothing else may run
//      before it.
//   2. A replacement (`-r`) is not a new notification. Notify() resolves
//      `replacesId` to the existing object, calls updateProperties() on it
//      and emits nothing at all, so the same entry, the same card and the same
//      id stay on screen with new content. Only the history record and the
//      clock need handling, and both are handled by the entry's touch().
//
//      That only covers a replaces_id the server still holds. Quickshell
//      0.3.x answers an UNKNOWN replaces_id with a fresh server id instead of
//      echoing it (spec 1.2: a non-zero replaces_id is echoed back), so a
//      fixed `-r 2` never stabilises - every send is a new card. The second
//      replacement path is the synchronous tag
//      (`x-dunst-stack-tag` / `x-canonical-private-synchronous` /
//      `x-vb-tag`, see NotificationsLib.replaceTagOf): a new arrival
//      carrying a tag is ADOPTED by the live entry carrying it - the keeper
//      survives with its card, its place and its clock, and only the pointer
//      moves to the new object. Same visible answer - one card, new content,
//      restarted clock - for an identity the server ids cannot carry, and
//      without a new delegate: the bar glides from the old value instead of
//      re-animating, and nothing fades.
//
// Deadlines live on the entries and are fired by the single timer below: the
// pile is a Column over a JS array, so any state that lived in a card would
// restart every time anything else was dismissed.
Singleton {
  id: root

  readonly property string tag: "notifications"

  // --- policy numbers -----------------------------------------------------
  //
  // A client that says nothing about its timeout gets this one. Milliseconds:
  // the D-Bus `expire_timeout` is in milliseconds and the Quickshell
  // documentation calling it seconds is wrong.
  readonly property int defaultTimeoutMs: 5000
  // The pile is bounded because it is docked to a bar in a screen corner: more
  // cards than this and the pile runs into the bar it is docked to, and on a
  // short screen into the desktop itself.
  //
  // The bound is the PILE's, not one caller's: `_enforceCardBound()` runs after
  // every arrival as well as after every do-not-disturb flush. It runs on the
  // arrival path too, so a client firing forty notifications with no interval
  // does not put forty cards on screen where the same forty through the buffer
  // get eight. A bound that only one path applies is not a bound.
  readonly property int maxCards: 8
  // The daemon's own history. Bounded for the same reason every history in
  // this shell is: a session that never clears it must not grow it without
  // limit, and the oldest record is the one worth losing.
  readonly property int historyLimit: 200

  // --- do not disturb -----------------------------------------------------
  //
  // One flag per forced source rather than a single one, because each source
  // has to be answerable for itself: a screen share starting must not be undone
  // by fullscreen ending, and a notification pile that needs a reason can only
  // be given one by naming it. `status` reads all three.
  //
  // Fullscreen forces DND on so a notification cannot appear over a video. A
  // screen share forces it on for the same reason about a wider audience: the
  // recorder's dot is already on the bar, so the pile is the other half of the
  // same warning. Both are read from a service rather than re-derived here -
  // fullscreen from the compositor, the share from the privacy service, which
  // is the one place that already classifies the PipeWire graph and knows a
  // portal screencast from a camera.
  //
  // Neither may clear a DND the user set by hand, and neither clearing may
  // clear it either - hence the manual flag, the forced flags, and the
  // effective state as their disjunction.
  property bool dndManual: false
  readonly property bool dndForcedFullscreen: FullscreenProbe.anyActive
  readonly property bool dndForcedShare: Core.Privacy.shareOn
  readonly property bool dndForced: root.dndForcedFullscreen || root.dndForcedShare
  readonly property bool dnd: root.dndManual || root.dndForced

  // --- placement ----------------------------------------------------------
  //
  // The pile follows the bar: a top bar puts the pile under the bar, a bottom
  // bar puts it above, and no bar (or a hidden one) leaves the default, top.
  readonly property bool atTop: DesktopLayoutState.barEnabled
    ? DesktopLayoutState.barPosition === "top" : true

  // The bar clock's own hour format, read off the shared verdict rather
  // than the key: a notification's clock is a timestamp of the same wall
  // clock, so a pile that formatted it differently from the bar would be
  // a second, contradicting answer to "what time is it".
  readonly property bool use12h: TimeFormat.use12h

  // Whether the pile is being hovered, which freezes every visible card's
  // deadline - the hovered one included, because a card that expires under the
  // pointer is a card the user was reading.
  //
  // Written by the view, which is the only thing that knows where the pointer
  // is, and read here because this is the only thing that decides whether a
  // deadline is honoured. `surfaceVisible` is half of the answer rather than an
  // afterthought: a window that unmaps under the pointer never receives the
  // leave event, so a hover recorded here could otherwise outlive the surface
  // that reported it and leave the next pile frozen with nobody over it.
  property bool hoverPaused: false
  // Whether a pause is REALLY running, which is not the same as `hoverPaused`
  // alone: a window that unmaps under the pointer never receives the leave
  // event, so the hover flag can outlive the surface that reported it and freeze
  // the next pile with nobody over it. Both edges of the pause are driven off
  // THIS property rather than off `hoverPaused` for that reason - a handler on
  // the raw flag misses the unmap case entirely, and the time between the two
  // events would be discounted as paused when nothing was on screen.
  readonly property bool _hoverActive: root.hoverPaused && root.surfaceVisible

  // Total time spent paused, milliseconds, accumulated across every hover. It is
  // an offset rather than a "paused since" stamp on each entry because a card
  // can arrive OR be replaced while the pause is running, and a per-entry stamp
  // would have to be rewritten to know which cards that was. Subtracting one
  // running total from the clock keeps every armed entry's own arithmetic intact
  // and needs no rewrite at all.
  property real _pausedTotalMs: 0
  property real _pausedSinceMs: 0

  // --- state --------------------------------------------------------------
  //
  // `_tracked` is arrival order, index 0 the oldest, and nothing sorts it in
  // place: every deadline, every flush and every history overwrite is read off
  // this order, and the visual order is a second question answered separately.
  property var _tracked: []
  // Newest first, bounded, and one record per notification id - a replacement
  // overwrites its entry rather than appending a second one. A record exists for
  // as long as the notification does: it is written when the notification is
  // admitted, refreshed on every content change, and only its `closedReason` is
  // filled in when the notification closes.
  property var _history: []

  // The visual order the view draws: arrival order when the pile grows upward
  // toward a bottom bar, reversed when it grows downward from the top.
  // `arrivalOrder` is named in the chain because the storage order and the
  // drawing order are two different claims about the same list.
  readonly property var pile: NotificationsLib.pileOrder(
    NotificationsLib.arrivalOrder(root._shown()), root.atTop)
  // A card that is fading out is still in `pile` - the release path keeps it
  // there until the fade lands - so the "is a card up" test and the "is a card
  // fading" test are the same test here.
  readonly property bool surfaceVisible: root.pile.length > 0

  // How many cards the last change to the pile put on screen at once, and the
  // length that number was measured against.
  //
  // Counted from the pile's own length rather than carried through the two
  // admission paths on purpose: there are more than two - an arrival, a
  // do-not-disturb release, the re-bound after either - and a count set at each
  // is a claim that has to be kept true by hand at every one of them. The
  // length delta is the fact itself.
  //
  // Read by `isArriving`, which is what decides whether a card is placed by the
  // pile's current geometry or its final one. It survives a change that does not
  // alter the length - a card re-measuring rebuilds the derived list without
  // adding anything - and is cleared by one that shortens it, because a
  // dismissal means whatever was arriving has already been dealt with.
  property int arriving: 0
  property int _pileLength: 0

  function _noteGrowth(): void {
    const n = root.pile.length
    if (n > root._pileLength) root.arriving = n - root._pileLength
    else if (n < root._pileLength) root.arriving = 0
    root._pileLength = n
  }

  onPileChanged: {
    root._noteGrowth()
    // -> Pile reassign/arrival/dismiss invalidates the geometry cache.
    root._bumpGeom()
    root._ensureGeom()
  }

  // Is this entry one of the cards the pile is currently growing room for?
  //
  // The bottom dock is the only dock with a question here, and the reason is the
  // box the cards live in. At the top dock the box's y is the constant
  // `topInset`, so a newcomer placed at its own offset is already where it
  // belongs and nothing has to be second-guessed. At the bottom dock the pile is
  // anchored by its BOTTOM edge: adding a card moves the box's y target up by a
  // slot while its height - which is what says how far up the pile reaches -
  // only catches up over the length of the slide. A card placed by `yOf` in that
  // window is laid out against the box's OLD top and hangs a full card height
  // below the bar, off the bottom of the screen, until the box carries it up.
  // Measured at the bottom dock with the bar edge at 386 and the screen ending
  // at 426: a newcomer drawn at 392..446 for six frames, which is the
  // "slides in from outside the screen and over the statusbar" report.
  //
  // An arriving card is therefore placed against the box's CURRENT height
  // rather than its final one - `yOf` plus the box's shortfall, which cancels
  // the box's motion exactly. It then sits flush against the bar edge from its
  // first frame and the cards above it do the sliding, which is the part that
  // should move.
  function isArriving(entry): bool {
    if (!entry || root.atTop || root.arriving <= 0) return false
    const cards = root.pile
    return cards.indexOf(entry) >= cards.length - root.arriving
  }

  // Drop the oldest cards until the pile is within `maxCards`. Called after every
  // arrival and after every do-not-disturb flush, because both are ways for the
  // pile to grow.
  //
  // `expire()` rather than `dismiss()`: the client is told the notification
  // timed out, which is the honest answer for one the pile has no room for. The
  // history record was written at admission, so nothing is lost - the card is
  // simply not on screen any more.
  function _enforceCardBound(): void {
    // Counted the same way the DND flush counted them: every tracked entry that
    // is neither held nor already fading. A held entry is in the buffer, not on
    // the pile, so expiring it to make room for a card that IS on the pile would
    // be dropping a notification the user has not been shown yet in order to
    // keep one they are looking at.
    const live = []
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      if (!entry || entry.held || entry.leaving) continue
      live.push(entry)
    }
    const excess = live.length - root.maxCards
    if (excess <= 0) return
    // Oldest first. Arrival order puts them at the front of this list, and the
    // card that falls off the far end from the bar is the oldest one whichever
    // end of the pile that is.
    for (let i = 0; i < excess; i++) root._expire(live[i])
  }

  readonly property int trackedCount: root._tracked.length
  readonly property int historyCount: root._history.length
  // The single global motion switch, wired at library level like
  // PanelCard/OverlayWindow so the card's Behaviours need not bind it.
  readonly property bool animationsEnabled: MotionPolicy.enabled

  // --- the daemon ---------------------------------------------------------
  //
  // Every capability here is one the card actually honours, and the ones it
  // does not are declared false on purpose. Advertising a capability the
  // surface cannot render is worse than not advertising it: the client then
  // sends data that arrives as something wrong rather than as plain text.
  // bodyImagesSupported is false because the body is a Text and cannot paint
  // an image; actionIconsSupported is false because the card draws no action
  // icons.
  NotificationServer {
    id: server

    persistenceSupported: true
    bodySupported: true
    bodyMarkupSupported: true
    bodyHyperlinksSupported: true
    bodyImagesSupported: false
    actionsSupported: true
    actionIconsSupported: false
    imageSupported: true
    // False, and it is the reason a chat client falls back to a button instead
    // of a text field. Inline replies are deliberately not offered: a reply
    // field needs the keyboard, and this surface is a pile of cards that has no
    // business taking the keyboard from whatever the user is typing into. Left
    // false, the server also leaves the literal `inline-reply` action in
    // `actions`, so a client that sends one anyway gets an ordinary button
    // rather than a field that would steal focus to be typed into.
    inlineReplySupported: false
  }

  Connections {
    target: server

    function onNotification(notification) {
      // FIRST STATEMENT, before anything else. Notify() emits `notification`
      // and then, for an untracked notification, emits NotificationClosed and
      // deletes the object - all synchronously, inside this handler. Anything
      // admitted after that line would be holding a pointer to an object that
      // no longer exists, and a card built on it would read freed memory.
      notification.tracked = true
      root._admit(notification)
    }
  }

  // --- admission and release ----------------------------------------------
  //
  // Nothing is expired on arrival. A notification that arrives while DND is on
  // waits in the buffer with its own deadline and is flushed when DND lifts, or
  // expired from that deadline in the meantime; dropping it on the way in
  // would make DND's buffer a queue of notifications the user never gets to
  // see and cannot answer for.
  function _admit(notification) {
    if (!notification) return null
    // A tagged arrival is adopted by the live entry carrying the same tag:
    // the keeper survives with its card, its place and its clock, and only
    // the pointer moves to the new object. The card therefore updates in
    // place - the progress bar glides from the old value instead of
    // re-animating from zero, and nothing fades or repaints. A
    // retire-and-rebuild (dismiss the old entry, admit a new one) reads as
    // flicker for exactly that reason: a new entry is a
    // new delegate, and a new delegate starts its bar at zero with no
    // distance travelled.
    //
    // Held entries adopt too, so a burst arriving during do-not-disturb
    // waits as one buffered card rather than many; leaving entries do not,
    // they are already out of the business of showing and are only kept for
    // their fade. A second live card with the same tag is a duplicate the
    // tag promises cannot exist, so it goes the superseded way (no history,
    // no fade) and only the first is kept.
    const tag = NotificationsLib.replaceTagOf(notification.hints)
    if (tag !== "") {
      let keeper = null
      let dropped = false
      const keep = []
      for (let i = 0; i < root._tracked.length; i++) {
        const old = root._tracked[i]
        if (old && !old.leaving && !old.superseded && old.replaceTag === tag) {
          if (keeper === null) {
            keeper = old
            keep.push(old)
            continue
          }
          old.superseded = true
          if (old.alive) {
            try { old.notif.dismiss() } catch (e) {}
          } else {
            try { old.destroy() } catch (e) {}
          }
          dropped = true
          continue
        }
        keep.push(old)
      }
      if (keeper !== null) {
        // The one `_tracked` write, and only when a duplicate actually
        // left: the common case changes no membership at all, so the pile -
        // and the row model diffed off it - never churns.
        if (dropped) root._tracked = keep
        // Repoint BEFORE retiring the old object: dismiss() emits `closed`
        // synchronously, and while the keeper still listens to it that close
        // would fade the very card being kept. After the repoint nobody
        // listens to the old object, so its close frees the server id in
        // silence. The clock stays the keeper's: like an in-place `-r`, an
        // adoption refreshes content and restarts the deadline, it does not
        // re-announce.
        const doomed = keeper.alive ? keeper.notif : null
        keeper.notif = notification
        keeper.notifId = Number(notification.id)
        // Snapshot, clock re-arm and history through the one path every
        // content change takes: the new id overwrites the tag's old history
        // row by the tag rule, so one tag stays one record.
        keeper.touch()
        if (doomed !== null && doomed !== notification) {
          try { doomed.dismiss() } catch (e) {}
        }
        // The geometry cache is keyed by notifId, which just changed under
        // it: rebuild now, or yOf misses and parks the card past the pile.
        root._bumpGeom()
        root._ensureGeom()
        return keeper
      }
    }
    // Through a Component rather than an inline construction expression,
    // because an object literal cannot appear inside a function body. The
    // entry is parented to this singleton, so its lifetime is the daemon's:
    // there is nothing else that would destroy it if a notification were
    // somehow never closed.
    const entry = entryComp.createObject(root, {
      notif: notification,
      notifId: Number(notification.id),
      arrivedAt: Date.now(),
      held: root.dnd,
      replaceTag: tag
    })
    if (!entry) return null
    // The snapshot before the entry joins the pile, and the order is the
    // point: the pile's change is what creates the card, so a card built
    // against an empty snapshot would paint its first frame without the
    // urgency it has - and the border's own tween would carry that wrong
    // color into the card's arrival.
    //
    // Built once and used for both: `createObject` hands back a plain QObject,
    // so reading a member off it back is a name qmllint cannot resolve, and the
    // snapshot is wanted on both sides of the assignment anyway.
    const snapshot = root._snapshotOf(entry)
    entry.snapshot = snapshot
    root._tracked = root._tracked.concat([entry])
    // Recorded on admission, not only on close. The history answers "what was I
    // notified about", and a caller asking that while the notification is still
    // on screen - which is when asking is the only thing that makes sense -
    // would otherwise be told nothing at all. `closed` below finalises the
    // record; it does not create it.
    root._publishHistory(snapshot)
    // Every arrival is a way for the pile to grow, so every arrival is checked.
    // Held entries are skipped inside the call, which is what makes a burst
    // arriving during do-not-disturb wait in the buffer rather than being
    // expired on the way in.
    root._enforceCardBound()
    root._arm(entry)
    root._armDeadline()
    return entry
  }

  Component {
    id: entryComp

    NotificationEntry {}
  }

  // The entry reports a content change and the controller answers it, because
  // the two answers are policy: the snapshot the card draws, and the clock.
  // Returns the new snapshot because the entry cannot build one itself - it
  // holds the pointer, it does not own the state the pointer is read for.
  //
  // The history row is refreshed here too, for the same reason the snapshot is:
  // a replacement changes the content and bumps `revisions` without emitting a
  // single signal of its own, so `onEntryChanged` is the only place that learns
  // about it. pushHistory overwrites the row where it stands, so a replacement
  // stays ONE record at ITS position rather than appending a second.
  function onEntryChanged(entry) {
    const snapshot = root._snapshotOf(entry)
    if (entry) {
      // The tag rides the hints, and the hints can be rewritten by an
      // in-place replacement: keep the entry's match key current, or the
      // next tagged arrival will not find this card.
      if (snapshot && typeof snapshot.replaceTag === "string") entry.replaceTag = snapshot.replaceTag
      root._arm(entry)
      root._publishHistory(snapshot)
    }
    root._armDeadline()
    return snapshot
  }

  // `closed` is the last moment the object is alive and its state is final, so
  // it is the only moment that can FINALISE a record: it is the only place the
  // close reason exists, and the only place a client-driven close is reported at
  // all. It is not where the record is created - it was written at admission
  // and kept current on every content change, because a history that only knows
  // about notifications once they have gone answers the question the caller is
  // asking while they are still on screen with an empty array.
  function onEntryClosed(entry, reason) {
    if (!entry) return
    // Retired by a tag replacement in `_admit`: already out of `_tracked`,
    // and the replacement's admission already recorded current content. Only
    // free the QML object and re-arm - no history write, no exit fade.
    if (entry.superseded) {
      try { entry.destroy() } catch (e) {}
      root._armDeadline()
      return
    }
    root._remember(entry, reason)
    root._release(entry)
    root._armDeadline()
  }

  // The one write to `_history`, shared by admission, refresh and close, so the
  // three cannot disagree about the bound or the ordering. pushHistory owns the
  // overwrite-by-id rule and the bound; this owns nothing else.
  function _publishHistory(snapshot) {
    root._history = NotificationsLib.pushHistory(root._history, snapshot, root.historyLimit)
  }

  function _remember(entry, reason) {
    const snapshot = root._snapshotOf(entry)
    // NotificationCloseReason is 1-BASED: Expired 1, Dismissed 2,
    // CloseRequested 3. Zero is the "not closing" sentinel `close()` uses, and
    // it is also what the record carries for as long as the notification is
    // open, so one field answers "how did this end" for every record instead of
    // the caller having to tell an absent field from a present zero. The
    // generated type description lists the three names in order without their
    // values, which is where the 0/1/2 reading comes from. Measured on 0.3.1:
    // the pile's own expire reports 1 and a right-click dismiss reports 2.
    // Kept as the number rather than the name because this object is answered as
    // JSON and a caller should not have to parse a string to compare it.
    snapshot.closedReason = Number(reason)
    root._publishHistory(snapshot)
  }

  // Start keeping a released card for its exit fade: the pile keeps it in the
  // array until the fade lands, so the rest of the pile slides into the gap
  // instead of jumping and the window stays mapped until the last card is gone.
  function _release(entry) {
    if (!entry || entry.leaving) return
    entry.leaving = true
    exitTimer.restart()
  }

  // One entry out of the array per exit fade, and out of the process too.
  // The destroy waits one turn past the removal: the Repeater that draws the
  // pile draws from _tracked, and a delegate that still holds a destroyed
  // entry is a broken binding, so a same-turn destroy trades a leak for a
  // visual fault. The leak it replaces was the larger of the two - an entry is
  // a QML object parented to this singleton, so the engine owns it and
  // dropping the last JS reference does not collect it. One QtObject, one
  // Connections block and one snapshot were retained for every notification
  // that had ever arrived, for the life of the shell.
  function _dropLeaving() {
    const keep = []
    const gone = []
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      if (entry && entry.leaving) { gone.push(entry); continue }
      keep.push(entry)
    }
    if (gone.length === 0) return
    root._tracked = keep
    root._armDeadline()
    Qt.callLater(() => {
      for (let i = 0; i < gone.length; i++) {
        if (gone[i] === null || gone[i] === undefined) continue
        try { gone[i].destroy() } catch (e) {}
      }
    })
  }

  // --- deadlines ----------------------------------------------------------
  //
  // The deadline policy in one place. `expireTimeout` is milliseconds; urgency
  // wins outright, because a critical notification is persistent by
  // definition, and the arming time is stamped here so a replacement is one
  // assignment away from restarting the clock.
  function _arm(entry) {
    const n = entry && entry.alive ? entry.notif : null
    entry.deadlineMs = NotificationsLib.timeoutMs(
      n ? n.expireTimeout : -1, entry.critical, root.defaultTimeoutMs)
    // In the deadline clock, not wall time: a card re-armed under the pointer
    // gets its full length from the moment the pointer leaves, which is the
    // same answer every other card gets.
    entry.armedAt = root._now()
  }

  // Enter and leave the pause, both edges off `_hoverActive` and nothing else.
  // Accumulating the elapsed stretch into one total is what makes resume exact
  // for cards that arrived or were replaced while it ran: their stamps were
  // taken against the frozen clock too, so nothing is reconciled per entry and
  // nothing gets time the pile did not spend.
  on_HoverActiveChanged: {
    if (root._hoverActive) {
      // Guarded rather than assigned outright: this handler sees both edges, and
      // an activation with no matching leave must not rewind the start of a
      // pause that is still running.
      if (root._pausedSinceMs <= 0) root._pausedSinceMs = Date.now()
      deadlineTimer.stop()
      return
    }
    if (root._pausedSinceMs <= 0) return
    root._pausedTotalMs += Date.now() - root._pausedSinceMs
    root._pausedSinceMs = 0
    root._armDeadline()
  }

  // Now, in the clock the deadlines are written against: wall time less
  // everything the pile has spent hovered. One subtraction, so arming, arming
  // the pile and expiring all read the same instant and a pause needs no
  // per-entry bookkeeping at either end.
  function _now() {
    return Date.now() - root._pausedTotalMs - (root._hoverActive ? Date.now() - root._pausedSinceMs : 0)
  }

  // The whole pile's earliest remaining deadline, armed on one timer. A timer
  // per card would restart every time the pile shifted, so a notification in a
  // churned pile would never expire.
  //
  // Nothing is armed while the pile is hovered: the timer is stopped on the way
  // in and re-armed by the pause's own change handler on the way out, so no
  // card's deadline can land in the gap between them.
  function _armDeadline() {
    if (root._hoverActive) {
      deadlineTimer.stop()
      return
    }
    let remaining = -1
    const now = root._now()
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      // A released entry contributes nothing: it is out of the business of
      // expiring and is only kept for its fade.
      if (!entry || entry.leaving || entry.deadlineMs <= 0) continue
      const due = entry.armedAt + entry.deadlineMs - now
      if (remaining < 0 || due < remaining) remaining = due
    }
    // A critical notification contributes no deadline at all, so it simply
    // never comes due - which is what "never expires" means here.
    if (remaining < 0) {
      deadlineTimer.stop()
      return
    }
    deadlineTimer.interval = Math.max(1, remaining)
    deadlineTimer.restart()
  }

  function expireDue() {
    if (root._hoverActive) return
    const now = root._now()
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      if (!entry || entry.leaving || entry.deadlineMs <= 0) continue
      if (entry.armedAt + entry.deadlineMs > now) continue
      root._expire(entry)
    }
    root._armDeadline()
  }

  // expire() and not dismiss(): a notification dropped off a bounded pile was
  // dropped because the daemon would not keep holding it, and telling the
  // client it expired is the honest answer. Either way the history snapshot is
  // taken by the close handler before the object dies, so nothing is lost.
  function _expire(entry) {
    if (!entry || entry.leaving) return
    if (entry.alive) entry.notif.expire()
    else root._release(entry)
  }

  function _dismiss(entry) {
    if (!entry || entry.leaving) return
    if (entry.alive) entry.notif.dismiss()
    else root._release(entry)
  }

  // --- pile queries -------------------------------------------------------

  function _shown() {
    const out = []
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      if (!entry || entry.held) continue
      out.push(entry)
    }
    return out
  }

  function _held() {
    const out = []
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      if (!entry || !entry.held) continue
      out.push(entry)
    }
    return out
  }

  function _leaving() {
    let n = 0
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      if (entry && entry.leaving) n++
    }
    return n
  }

  // The pile top to bottom, by summary. Read off the same `pile` the view
  // draws rather than off `_tracked`, so `status` reports the visual order
  // and not the storage order.
  function _pileSummaries() {
    const out = []
    for (let i = 0; i < root.pile.length; i++) {
      const shot = root.pile[i] ? root.pile[i].snapshot : null
      out.push(shot && shot.summary !== undefined ? String(shot.summary) : "")
    }
    return out
  }

  function _entryById(id) {
    const wanted = Number(id)
    if (!isFinite(wanted)) return null
    for (let i = 0; i < root._tracked.length; i++) {
      if (Number(root._tracked[i].notifId) === wanted) return root._tracked[i]
    }
    return null
  }

  // The pile's geometry: one card's y, in the view's coordinates.
  //
  // This exists instead of a Column because a Column will not carry the slide.
  // Measured on Quickshell 0.3.1 / Qt 6.11.2: a Column assigns its children's
  // y itself and a `Behavior on y` never sees that assignment - a Column whose
  // middle child collapsed moved the cards below from y=48 to y=24 in a single
  // frame - while the same property driven by a binding tweened across the
  // interval. A Column also re-asserts y on every polish, so an imperative
  // write from the card is overwritten rather than animated. The requirement
  // is a smooth slide when the pile reflows, so the y is a binding here and the
  // card's Behavior has something to see.
  //
  // Walked per card rather than precomputed into an array because a card's
  // height depends on its body and a precomputed layout would have to be
  // invalidated from the cards themselves. At the pile's bound of eight this
  // is eight additions.
  //
  // -> Cached below: one walk per pile version builds every offset plus the
  // -> total, and each delegate read is an O(1) lookup with identical pixels.
  property int _geomVersion: 0
  property int _geomBuiltFor: -1
  property var _geomYById: ({})
  property real _geomTotal: 0

  // -> Bump on every pile reassign/arrival/dismiss (via onPileChanged) and on
  // -> every cardHeight write-back (via noteCardHeight).
  function _bumpGeom(): void {
    root._geomVersion++
  }

  // -> The single walk: offsets keyed by notifId (unique per tracked entry)
  // -> plus the pile total. Rebuilt EAGERLY at every mutation (onPileChanged
  // -> and noteCardHeight, the only two writers of its inputs) and NEVER
  // -> lazily from a read path: _ensureGeom assigns fresh objects to
  // -> _geomYById/_geomTotal, and a read (yOf/pileHeight) that writes the
  // -> very properties its own binding depends on is a binding loop
  // -> ("Binding loop detected for property y/height/growing").
  function _ensureGeom(): void {
    if (root._geomBuiltFor === root._geomVersion) return
    const cards = root.pile
    const byId = {}
    let y = 0
    for (let i = 0; i < cards.length; i++) {
      const e = cards[i]
      if (e) byId[Number(e.notifId)] = y
      y += (Number(e ? e.cardHeight : 0) || 0) + root.cardSpacing
    }
    root._geomYById = byId
    root._geomTotal = cards.length === 0 ? 0 : y - root.cardSpacing
    root._geomBuiltFor = root._geomVersion
  }

  // -> The single write-back for card heights so the cache cannot go stale.
  function noteCardHeight(entry, h): void {
    if (!entry) return
    const v = Number(h) || 0
    if (entry.cardHeight === v) return
    entry.cardHeight = v
    root._bumpGeom()
    root._ensureGeom()
  }

  // Pure lookup: the cache is always fresh here because both mutation paths
  // rebuild it synchronously (see _ensureGeom). Must stay write-free - see
  // above - or the card y binding loops.
  function yOf(entry): real {
    if (!entry) return 0
    const y = root._geomYById[Number(entry.notifId)]
    if (y !== undefined) return Number(y)
    // -> A missing entry takes the bottom of the stack: the full stack height
    // plus one gap.
    return root.pile.length === 0 ? 0 : root._geomTotal + root.cardSpacing
  }

  // The pile's own height: the same walk with a different stopping point. The
  // view needs it to dock to the bottom edge and to size the input region to
  // the cards rather than to the window. Pure read, like yOf: the box height
  // binding evaluates this, so a write here would loop it too.
  function pileHeight(): real {
    return root._geomTotal
  }

  // The gap between cards. A property so the view and yOf cannot disagree, and
  // a step below Ui.s so a full pile sits closer together - the pile is read as
  // one stack, and Ui.s gaps drew eight separate cards rather than a stack.
  readonly property real cardSpacing: 6

  // -> Single source for the exit lifetime: the card fade and the drop timer
  // -> both read this, so a fade retune cannot desync the drop. Same value as
  // -> the Ui.fastMs both read before.
  readonly property int exitMs: Ui.fastMs

  // --- public actions -----------------------------------------------------

  // Fire one of a notification's own actions, by notification id.
  //
  // The card draws a notification's actions and invokes them through the live
  // entry, which only works while the notification is alive. A consumer reading
  // the history therefore cannot invoke anything by itself: it holds a record,
  // not the object, and the client is free to have withdrawn its actions the
  // moment the notification closed. This is the one door from a record back to
  // a live notification, and it answers false rather than pretending - a button
  // on a dead row is a button that says so.
  function invokeAction(id, identifier): bool {
    const entry = root._entryById(id)
    if (!entry) return false
    return entry.invokeAction(identifier)
  }

  // Dismiss one notification by id. A right click on a card and the `dismiss`
  // verb are this one call, so both are answered by the same handler.
  function dismiss(id): bool {
    const entry = root._entryById(id)
    if (!entry) return false
    root._dismiss(entry)
    return true
  }

  // Dismiss what is in the pile, leaving the DND buffer alone: this is the pile
  // verb, and a notification the user has not been shown yet is not part of
  // what they dismissed.
  function dismissAll(): int {
    const shown = root._shown()
    for (let i = 0; i < shown.length; i++) root._dismiss(shown[i])
    return shown.length
  }

  // Dismiss everything the daemon holds, buffer included, and answer with how
  // many went. `clear` is the verb that empties the daemon, so it should say
  // whether it emptied anything.
  function clear(): int {
    const all = root._tracked.slice()
    for (let i = 0; i < all.length; i++) root._dismiss(all[i])
    return all.length
  }

  function clearHistory(): void {
    root._history = []
  }

  function setDnd(on): bool {
    root.dndManual = on !== false
    return root.dnd
  }

  function toggleDnd(): bool {
    root.dndManual = !root.dndManual
    return root.dnd
  }

  // Do not disturb takes down what is already up, not only what arrives after
  // it. A card that was on screen when a video went fullscreen is exactly the
  // card the forced flag exists to keep off the screen, and holding only
  // arrivals makes the rule a statement about the future - so entering
  // fullscreen with three cards up left all three sitting over the video, which
  // is what this withdraws.
  //
  // Into the buffer, not expired: `held` is what the existing release path
  // already drains in arrival order when DND lifts, so the cards come back
  // rather than being lost. Their own deadlines keep running throughout, because
  // `_armDeadline` reads every tracked entry that is not leaving - a card that
  // has been up for four of its five seconds is still gone four seconds later
  // whether it was on screen or in the buffer.
  //
  // Not `leaving`: that is the exit fade, and the entry is dropped from
  // `_tracked` when it lands, so a card faded that way would not come back at
  // all. The removal is immediate for the same reason - the thing being removed
  // from the screen is the thing the user is watching.
  function _withdraw(): void {
    for (let i = 0; i < root._tracked.length; i++) {
      const entry = root._tracked[i]
      // A released entry is already out of the business of showing and is
      // held for its fade; putting it in the buffer would resurrect it.
      if (!entry || entry.held || entry.leaving) continue
      entry.held = true
    }
  }

  // Lifting DND is the one event that can make a whole queue appear at once, so
  // the buffer is released in arrival order and the pile is re-bounded
  // afterwards - whatever no longer fits is expired, because the screen corner
  // has no room for it.
  onDndChanged: {
    root._armDeadline()
    if (root.dnd) {
      root._withdraw()
      return
    }
    const held = root._held()
    for (let i = 0; i < held.length; i++) held[i].held = false
    root._enforceCardBound()
  }

  // A plain object, and it has to be plain: the Notification is destroyed the
  // moment `closed` returns, so every field the card draws and every field the
  // history answers with is copied here as a value.
  //
  // The early-out is the guard against blanking a record that already exists.
  // Once the object is gone the last good snapshot IS the record, so it is
  // returned unchanged - including its `closedReason`, which a caller reading
  // this for a refresh must not see reset. Returning `{}` here would replace a
  // row of real content with an empty one on the very call that follows the
  // destruction.
  function _snapshotOf(entry) {
    if (!entry) return ({})
    const n = entry.alive ? entry.notif : null
    if (!n) return entry.snapshot
    const actions = []
    const live = n.actions ? n.actions : []
    for (let i = 0; i < live.length; i++) {
      actions.push({ identifier: String(live[i].identifier), text: String(live[i].text) })
    }
    return {
      id: entry.notifId,
      summary: String(n.summary ?? ""),
      body: String(n.body ?? ""),
      appName: String(n.appName ?? ""),
      appIcon: String(n.appIcon ?? ""),
      desktopEntry: String(n.desktopEntry ?? ""),
      image: String(n.image ?? ""),
      urgency: Number(n.urgency),
      expireTimeout: Number(n.expireTimeout),
      arrivedAt: entry.arrivedAt,
      revisions: entry.revisions,
      // Open, not closed: 0 is the "not closing" sentinel Notification::close()
      // itself uses, so the field a caller reads is the same vocabulary whether
      // the notification is still up or already gone. `_remember` overwrites it
      // with the real 1/2/3 at `closed`. One field that is always present, rather
      // than a field that is absent until the notification ends.
      closedReason: 0,
      actions: actions,
      // -1 when the notification carries no progress hint at all, which is
      // what keeps "no bar" distinct from "a bar at 0%".
      progress: NotificationsLib.progressOf(n.hints),
      // The volume-lane level (percent 0..100, VOL_NONE when unsent) and
      // mute flag. The card draws the NowPlaying slider language off these
      // instead of the generic bar above.
      vol: NotificationsLib.volOf(n.hints),
      volMuted: NotificationsLib.volMutedOf(n.hints),
      // Per-notification chrome switch: hide the meta line (clock + sender)
      // for OSD-style cards that have nothing to say about when they
      // arrived. A value, like every other field here, so it survives the
      // object and refreshes on every content change.
      hideMeta: NotificationsLib.hideMetaOf(n.hints),
      // The synchronous replace tag ("" when the sender sent none). Copied
      // as a value like every other field here, and what keeps one history
      // row per tag: pushHistory evicts the tag's other rows, so a sender
      // streaming new server ids keeps one record rather than one per send.
      replaceTag: NotificationsLib.replaceTagOf(n.hints),
      // "" unless the sender asked for a tone with
      // `-h string:x-vb-icon-color:<key>`, and a palette key rather than
      // a hex: the card resolves it against the live palette through
      // AppIcons -> Icons.url, so the same card stays correctly toned across a
      // theme switch. Copied as a value for the reason every other field here
      // is one.
      iconColor: NotificationsLib.iconColorOf(n.hints),
      // The same key the bar's clock module reads, so the two clocks cannot
      // disagree: a 12-hour bar and a 24-hour notification pile would each be
      // "correct" and still look like a bug.
      clock: NotificationsLib.clockLabel(entry.arrivedAt, root.use12h)
    }
  }

  // --- timers -------------------------------------------------------------
  //
  // Two, both on the controller and both outside the pile's way: one fires the
  // earliest deadline, one ends an exit fade. The pair mirrors OSD's hide and
  // exit timers for the same reason - a card is regenerated by the Repeater on
  // every pile change, so nothing that has to keep time can live in one.
  Timer {
    id: deadlineTimer
    repeat: false
    onTriggered: root.expireDue()
  }

  Timer {
    id: exitTimer
    // -> Reads the shared exit token so the drop lands with the card fade.
    interval: root.exitMs
    repeat: false
    onTriggered: root._dropLeaving()
  }

  // Instantiate the surface once the singleton is boot-touched. The view reads
  // this singleton's properties directly, no prop threading.
  // LazyLoader moves that construction off the boot frame without gating it:
  // `loading: true` with no `active` builds once and stays resident.
  // Deliberately NOT gated on surfaceVisible - that would unmap and re-map the
  // window between notifications, which is the regression specs/04 measured
  // and removed from the OSD.
  LazyLoader {
    loading: true

    NotificationsView {}
  }

  Component.onCompleted: {
    Registry.offer("notifications", {
      title: "Notifications",
      description: "desktop notification daemon and pile",
      verbNames: [
        "clear",
        "clearHistory",
        "dismiss",
        "dismissAll",
        "dnd",
        "help",
        "history",
        "ping",
        "status",
        "toggleDnd"
      ]
    })
    Registry.register(root.tag, root)
  }
  Component.onDestruction: Registry.unregister(root.tag)

  IpcHandler {
    target: "notifications"
    function help(command: string): string {
      return UnitIpc.help("notifications", "Notifications", "desktop notification daemon and pile", [
        { name: "clear", help: "dismiss everything, buffer included; answers the count" },
        { name: "clearHistory", help: "forget the daemon's own history" },
        { name: "dismiss", signature: "(id)", help: "dismiss one notification by id" },
        { name: "dismissAll", help: "dismiss everything in the pile" },
        { name: "dnd", signature: "(on)", help: "on / off / toggle do-not-disturb; empty reads it" },
        { name: "history", help: "own history as JSON, newest first" },
        { name: "toggleDnd", help: "flip do-not-disturb" },
      ], command)
    }
    function ping(): string { return "pong" }

    // "on" / "off" / "toggle"; an empty or unrecognised word is a read, so
    // `dnd ""` answers the state without changing it. The answer is the
    // EFFECTIVE state, so a fullscreen-forced DND answers "on" even after
    // "off" - the honest answer is the one the pile is acting on.
    //
    // The argument is declared rather than optional because Quickshell 0.3.1
    // checks a verb's arity and refuses a mismatch: a default value is
    // rejected outright at load ("Type annotations are not supported (yet)")
    // and a rest parameter likewise, so `dnd` with no argument answers "Too
    // few arguments provided (1 required but 0 were provided.)" and changes
    // nothing. `toggleDnd` is the zero-argument form.
    function dnd(on: string): string {
      const want = String(on ?? "").trim().toLowerCase()
      if (want === "toggle") root.toggleDnd()
      else if (want === "on" || want === "true" || want === "1") root.setDnd(true)
      else if (want === "off" || want === "false" || want === "0") root.setDnd(false)
      return root.dnd ? "on" : "off"
    }

    // The zero-argument toggle, separate from `dnd` because a Quickshell 0.3.1
    // verb's arity is fixed: `dnd toggle` is one argument and this is none, so
    // a caller that wants to flip the switch has a verb that takes no argument
    // at all rather than one that has to be spelled with a placeholder.
    function toggleDnd(): string {
      root.toggleDnd()
      return root.dnd ? "on" : "off"
    }

    function history(): string {
      return JSON.stringify(root._history)
    }

    function clear(): string {
      return "ok: " + root.clear()
    }

    function clearHistory(): string {
      root.clearHistory()
      return "ok"
    }

    function dismiss(id: int): string {
      return root.dismiss(id) ? "ok" : "error: " + id
    }

    function dismissAll(): string {
      root.dismissAll()
      return "ok"
    }

    function status(): string {
      return JSON.stringify({
        dnd: root.dnd,
        dndManual: root.dndManual,
        dndForced: root.dndForced,
        // Per source, because "why is DND on" has two different answers and a
        // caller that has to guess cannot tell a video from a screen share.
        dndForcedFullscreen: root.dndForcedFullscreen,
        dndForcedShare: root.dndForcedShare,
        atTop: root.atTop,
        surfaceVisible: root.surfaceVisible,
        // Both halves, because "is a deadline frozen" has a cause and a state
        // and they differ while the surface is down: the hover flag can outlive
        // the pile that reported it, and only `_hoverActive` says whether
        // deadlines are actually suspended.
        hoverPaused: root.hoverPaused,
        deadlinesFrozen: root._hoverActive,
        tracked: root.trackedCount,
        shown: root.pile.length,
        leaving: root._leaving(),
        // The pile's own summaries, top to bottom. The counts above say how
        // many cards there are; this says which they are and in what order,
        // which is the one property of the surface a caller cannot otherwise
        // check and the one the dock decision exists for.
        pileOrder: root._pileSummaries(),
        // The bar clock's own hour format, which this pile's clocks follow.
        use12h: root.use12h,
        history: root.historyCount,
        maxCards: root.maxCards,
        defaultTimeoutMs: root.defaultTimeoutMs,
        animationsEnabled: root.animationsEnabled,
        capabilities: {
          body: server.bodySupported,
          bodyMarkup: server.bodyMarkupSupported,
          bodyHyperlinks: server.bodyHyperlinksSupported,
          bodyImages: server.bodyImagesSupported,
          actions: server.actionsSupported,
          actionIcons: server.actionIconsSupported,
          image: server.imageSupported,
          inlineReply: server.inlineReplySupported,
          persistence: server.persistenceSupported
        }
      })
    }
  }
}