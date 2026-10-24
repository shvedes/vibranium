pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell.Services.Notifications
import qs.features.notifications

// One tracked notification, and the only object in the feature that holds a
// pointer to a Notification.
//
// The pointer is the whole problem this file exists for. The shell does not
// own these objects: the D-Bus server destroys one the moment its client
// closes it, or the moment the daemon closes it, at a moment the shell did
// not choose - and every `closed` handler runs before that destruction, so
// nothing downstream may keep reading the object afterwards. Everything a
// card draws or a history record holds is therefore a plain value in
// `snapshot`, refreshed on every content change and frozen at `closed`.
//
// The entry is also what a replacement lands on. `Notify()` resolves
// `replacesId` to this same object and calls updateProperties() on it, so
// `-r` produces no new entry, no new card and no new id: it fires the
// content signals below, one `touch()` refreshes the snapshot, and the
// deadline is re-armed because `expireTimeoutChanged` is one of them.
QtObject {
  id: root

  // The notification's own id. Named `notifId` because `id` is a QML keyword
  // and cannot be declared as a property at all.
  property int notifId: 0
  // The foreign pointer. Reads null once the server or the client has
  // destroyed the notification, which is the signal every guarded read here
  // checks rather than assuming.
  property var notif: null
  // How long this notification may stay, 0 for no timeout. Milliseconds.
  property int deadlineMs: 0
  // When that length was armed, so a replacement restarting the clock is one
  // assignment rather than a second source of time. `real`, not `int`: epoch
  // millis do not fit a 32-bit QML int, and a truncated stamp reads as a due
  // date thousands of years in the past or future.
  property real armedAt: 0
  // The height of this entry's card, published back by the card and read by
  // Notifications.yOf to place the cards under it. A card's height comes from
  // its own content - the eight-line body cap, the buttons, the reply field -
  // so the pile's geometry cannot be computed from anything else.
  property real cardHeight: 0

  // True while DND holds it out of the pile.
  property bool held: false
  // True once the notification has been released and the entry is only still
  // here for the exit fade. The card fades on this and the controller drops
  // the entry when the fade lands, which is what lets the rest of the pile
  // slide into the gap instead of jumping.
  property bool leaving: false
  // True once a synchronous replace tag has retired this entry. Set by the
  // controller before the entry is removed from `_tracked`: the entry is
  // already out of the pile, so its `closed` handler must not write history
  // (the replacement's admission already recorded current content) and must
  // not start an exit fade (the replacement is atomic, no flicker) - it only
  // frees the QML object.
  property bool superseded: false
  // The synchronous replace tag this entry carries, copied from the
  // notification's hints at admission and kept current on every content
  // change. "" when the sender sent none. Read by the controller's tag
  // match, so the match never has to dereference the live hints.
  property string replaceTag: ""
  // When it arrived, in epoch millis. `real`, not `int`: a QML int property
  // is 32-bit and Date.now() does not fit it.
  property real arrivedAt: 0
  // How many content revisions this notification has taken. One per touch(),
  // however many properties a single replacement changed.
  property int revisions: 0
  // The shape, with every field present. An entry's snapshot is empty for the
  // few statements between its construction and the controller's first read of
  // it, and a half-built object makes every field the card binds to evaluate
  // to `undefined` - one warning per typed property rather than one about the
  // cause. `progress: -1` is the "no progress hint" answer, not a stand-in for
  // "empty"; `vol: -1` is the same answer for the volume lane; `urgency: -1`
  // is the same answer for the urgency, which is none of the three.
  readonly property var emptySnapshot: ({
    id: 0,
    summary: "",
    body: "",
    appName: "",
    appIcon: "",
    desktopEntry: "",
    image: "",
    clock: "",
    progress: -1,
    vol: -1,
    volMuted: false,
    hideMeta: false,
    replaceTag: "",
    urgency: -1,
    actions: []
  })

  // Plain values, no QObjects: summary, body, app identity, actions by name,
  // the progress fraction and the clock. This is what the card renders and
  // what the history record is.
  property var snapshot: root.emptySnapshot


  // The one live-state question, asked as `alive` rather than as
  // `notif !== null` at every site, so the answer to "is the object this
  // entry points at still there?" is written once.
  readonly property bool alive: root.notif !== null && root.notif !== undefined
  // The urgency, read live. The deadline policy needs it while the object is
  // there; the card does not use this one, because the card outlives the
  // object and reads the urgency off the snapshot instead.
  readonly property bool critical: root.alive && root.notif.urgency === NotificationUrgency.Critical

  // A QtObject has no default property of its own, so the Connections block
  // below is declared through one. The same idiom ProcessJob uses for the
  // objects a non-visual type owns: without it the block cannot be a child of
  // anything and the entry holds no notification signals at all.
  //
  // It lives INSIDE the list rather than beside it, because a defaulted list
  // with a value and a second assignment of the same object to it is two
  // parents for one block.
  default property list<QtObject> _owned: [
    // The foreign-lifetime boundary. Every handler here runs while the
    // notification is still alive: `closed` is emitted from the server's
    // delete path before the object is retained-destroyed, and the content
    // signals are the same object's own property changes.
    Connections {
      id: notifConnections

      target: root.notif
      ignoreUnknownSignals: false

      // The only moment the object is alive AND final, so it is where the
      // controller writes `closedReason` - the one field no earlier moment can
      // know. The record itself already exists: it was written at admission and
      // kept current by the handlers below, so a caller reading history sees
      // this notification while it is on screen rather than only once it has
      // gone.
      function onClosed(reason) { Notifications.onEntryClosed(root, reason) }

      function onSummaryChanged() { root.touch() }
      function onBodyChanged() { root.touch() }
      function onHintsChanged() { root.touch() }
      function onActionsChanged() { root.touch() }
      function onAppNameChanged() { root.touch() }
      function onAppIconChanged() { root.touch() }
      function onImageChanged() { root.touch() }
      function onUrgencyChanged() { root.touch() }
      function onExpireTimeoutChanged() { root.touch() }
      function onHasActionIconsChanged() { root.touch() }
      function onDesktopEntryChanged() { root.touch() }
    }
  ]

  // Refresh the snapshot and re-arm the deadline. One call behind every
  // content signal, because the two things a content change has to cause are
  // the same: the card needs the new values and the clock restarts.
  //
  // `expireTimeoutChanged` is the load-bearing one. updateProperties()
  // assigns expireTimeout unconditionally, so a replacement always restarts
  // the clock - a client that streams the same notification is holding it
  // open, not asking for it to be timed out from the first send.
  function touch() {
    root.revisions++
    root.snapshot = Notifications.onEntryChanged(root)
  }

  // Invoke one action by identifier. The card names the action it draws; the
  // entry, which is the only holder of the live notification, resolves the
  // identifier against the live action list and calls invoke().
  //
  // invoke() closes the notification unless it is `resident`, so the card
  // fades out on its own afterwards and needs no branch of its own.
  function invokeAction(identifier) {
    if (!root.alive) return false
    const list = root.notif.actions ? root.notif.actions : []
    for (let i = 0; i < list.length; i++) {
      if (String(list[i].identifier) !== String(identifier)) continue
      list[i].invoke()
      return true
    }
    return false
  }

  Component.onDestruction: {
    // The controller drops an entry after its fade, and by then the pointer is
    // usually already null. Clearing it here makes the last holder the owner
    // of the last reference in both orders.
    root.notif = null
  }
}