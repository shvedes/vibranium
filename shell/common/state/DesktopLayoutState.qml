pragma Singleton

import QtQuick
import Quickshell
import qs.common

Singleton {
  id: root

  property var _barLayout: ({
    owner: null,
    enabled: false,
    position: "top",
    height: 0
  })

  readonly property bool barEnabled: root._barLayout.enabled
  readonly property string barPosition: root._barLayout.position
  readonly property real barHeight: root._barLayout.height
  readonly property bool wallpaperEnabled: Settings.ready && Settings.wallpaperEnabled
  readonly property var primaryScreen: Ui.primaryScreen

  // --- boot entrance -------------------------------------------------------
  //
  // True once the shell's boot construction has settled, which is when the
  // entrance animation may play. The bar latches it the moment every placed
  // module has built (and immediately when it has nothing to wait for), so the
  // surfaces that paint a boot animation start it on a warm frame instead of
  // playing while modules are still constructing. Traced on a cold boot: the
  // wallpaper's 200ms fade took 433ms because it overlapped exactly that
  // construction, and the hitch at its tail was the overlap, not the fade.
  //
  // Background work that only needs to exist (the boot drain) waits for this
  // milestone and not for the animation it starts, so it can neither overlap
  // the construction the entrance is choreographed around nor hide behind the
  // entrance's own duration.
  //
  // The backstop is not a tuning knob: a shell with no bar, or one whose bar
  // never latches, must not hold a boot animation - or every service waiting
  // on the same milestone - forever. Its number is a boot's own outer bound
  // rather than a frame budget, and it has to cover the bar's deferred load:
  // the bar's module registry rides the async half (see Boot._bootVisuals),
  // so the latch lands a type-load after first paint instead of during it.
  // The timer stops the moment the real latch lands.
  readonly property int bootEntranceBackstopMs: 2000
  property bool bootEntranceSettled: false

  function noteBootEntranceSettled() {
    if (root.bootEntranceSettled) return false
    root.bootEntranceSettled = true
    return true
  }

  Timer {
    interval: root.bootEntranceBackstopMs
    running: !root.bootEntranceSettled
    repeat: false
    onTriggered: root.noteBootEntranceSettled()
  }

  // True once the boot entrance has finished DRAWING. The milestone above says
  // when the surfaces may start animating; this one says when the motion is
  // over, and it exists for work that is cheap to postpone and expensive to run
  // inside an animation: the launcher's index build and the menu's bundle
  // prewarm were each measured as frame stalls of ~100ms in the middle of the
  // boot entrance.
  //
  // Two surfaces draw that entrance and they do not finish together: the bar's
  // entrance is a fixed window from the latch (its strip slides in, then the
  // modules fade onto it), while the wallpaper's first fade starts after its
  // own decode and routinely ends later. So the milestone
  // is what the LAST of them reports - a first-report-wins flag would release
  // background work into the other one's motion, which is the stall this
  // exists to remove. The backstop covers a shell whose surface never reports
  // (no bar, wallpaper switched off), the same reasoning as the settle backstop
  // above.
  readonly property int bootEntrancePlayedBackstopMs: 1000
  property bool bootEntrancePlayed: false
  property var _bootPlayLeft: ({ bar: true, wallpaper: true })

  // A surface reports when its own boot motion ends; the milestone is what the
  // last of them reports. There is deliberately no "settled" precondition: the
  // wallpaper's fade now runs before the bar's construction settles (the bar
  // rides the async half), so requiring it would discard that report and leave
  // the milestone to its backstop.
  function noteBootEntrancePlayed(participant): bool {
    if (root.bootEntrancePlayed) return false
    const key = String(participant === undefined || participant === null ? "" : participant)
    if (root._bootPlayLeft[key] !== true) return false
    const left = Object.assign({}, root._bootPlayLeft)
    delete left[key]
    root._bootPlayLeft = left
    if (Object.keys(left).length > 0) return false
    root.bootEntrancePlayed = true
    return true
  }

  // The backstop: a surface that never reports (the wallpaper switched off, a
  // bar that was never built) must not hold the background prewarms off for
  // the whole session.
  function _forceBootEntrancePlayed() {
    if (root.bootEntrancePlayed) return
    root._bootPlayLeft = ({})
    root.bootEntrancePlayed = true
  }

  Timer {
    interval: root.bootEntrancePlayedBackstopMs
    running: root.bootEntranceSettled && !root.bootEntrancePlayed
    repeat: false
    onTriggered: root._forceBootEntrancePlayed()
  }

  // --- boot construction ---------------------------------------------------
  //
  // True once every late boot half that adopts units on this thread has
  // loaded, which is the end of the shell's one-time construction: the bar
  // half builds the bar, the services half the singletons, and each adoption
  // makes its units in single GUI turns. Measured on a cold boot those turns
  // are 100ms and 150ms of blocked thread, so a surface animating through them
  // freezes at whatever point it reached and jumps: the wallpaper's first fade
  // lost its middle and its tail to exactly that, which reads as a flicker
  // rather than a crossfade. So the first fade waits for this milestone
  // (WallpaperView) and nothing else does.
  //
  // The feature half is deliberately not part of it. Its adoption builds
  // nothing - BootLate.qml only dispatches - while its compile is the longest
  // of the three, so counting it would hold the first fade behind a type load
  // that cannot block this thread.
  //
  // Earlier than bootEntranceSettled, which waits for the bar's module build
  // after it: that build runs on the async halves' worker threads and is quiet
  // on this thread, while the construction before it is not.
  //
  // The backstop is the same last resort as the two milestones above: a half
  // that never lands must not hold a surface on the theme fill for the
  // session, and the construction declares itself settled either way.
  readonly property int bootConstructionBackstopMs: 2000
  property bool bootConstructionSettled: false

  function noteBootConstructionSettled(): bool {
    if (root.bootConstructionSettled) return false
    root.bootConstructionSettled = true
    return true
  }

  Timer {
    interval: root.bootConstructionBackstopMs
    running: !root.bootConstructionSettled
    repeat: false
    onTriggered: root.noteBootConstructionSettled()
  }

  // --- island pile-clearance ------------------------------------------------
  //
  // One IslandHost per bar view (per screen) publishes its card footprint
  // here as PLAIN DATA; the notification pile reads the record for its own
  // screen by name. Values, never object refs: every publish writes a fresh
  // record and reassigns the map, so any host move re-fires every reader by
  // value instead of depending on cross-object binding chains (which miss
  // open/close edges). Copy-on-write, no-op-guarded.
  property var _islands: ({})

  // Upsert the record for `screenName`. The footprint is the parked card's
  // vertical span (`top`, `bottom`) and its horizontal span (`left`, `right`),
  // all in screen coordinates; the notification pile reads the horizontal span
  // to tell an island over its column from one elsewhere on the bar. A no-op
  // (same six values) writes nothing and returns false, so parks that change
  // nothing stay silent.
  function publishIsland(screenName, showing, top, bottom, left, right) {
    const key = String(screenName || "")
    if (key === "") return false
    const on = showing === true
    const t = Number(top)
    const b = Number(bottom)
    const l = Number(left)
    const r = Number(right)
    const cur = root._islands
    const old = cur[key]
    if (old !== undefined && old !== null && typeof old === "object"
      && old.showing === on
      && Number(old.top) === (isFinite(t) ? t : 0)
      && Number(old.bottom) === (isFinite(b) ? b : 0)
      && Number(old.left) === (isFinite(l) ? l : 0)
      && Number(old.right) === (isFinite(r) ? r : 0)) return false
    const next = Object.assign({}, cur)
    next[key] = {
      showing: on,
      top: isFinite(t) ? t : 0,
      bottom: isFinite(b) ? b : 0,
      left: isFinite(l) ? l : 0,
      right: isFinite(r) ? r : 0
    }
    root._islands = next
    return true
  }

  // Drop the record for `screenName`. Hosts call this for their last key on
  // teardown so a destroyed-while-open host cannot hold the pile down.
  function releaseIsland(screenName) {
    const key = String(screenName || "")
    if (key === "") return false
    const cur = root._islands
    if (cur[key] === undefined) return false
    const next = Object.assign({}, cur)
    delete next[key]
    root._islands = next
    return true
  }

  // The record for `screenName` (null when none). Reads the map itself,
  // which is reassigned on every publish/release, so the lookup subscribes
  // and every reader re-evaluates on registration changes.
  function islandFor(screenName) {
    const key = String(screenName || "")
    if (key === "") return null
    const rec = root._islands[key]
    return rec === undefined ? null : rec
  }

  // Returns true when this call actually moved the published layout. The
  // caller needs that, not just "accepted": the bar calls this from a binding
  // on enabled/position/height, and a binding re-evaluates on every
  // dependency change - so the call arrives two or three times for one
  // state, and a caller that cannot tell the difference prints its own line
  // two or three times.
  function publishBarLayout(owner, enabled, position, height): bool {
    if (owner === null || owner === undefined) return false
    if (root._barLayout.owner !== null && root._barLayout.owner !== owner) return false

    const nextPosition = String(position)
    if (nextPosition === "") return false
    const nextHeight = Number(height)
    if (!Number.isFinite(nextHeight) || nextHeight < 0) return false

    // The store is still written: an unchanged republish is a no-op for
    // anything reading it, and skipping the write would change which bindings
    // re-evaluate.
    const prev = root._barLayout
    const changed = prev.owner !== owner
      || prev.enabled !== Boolean(enabled)
      || prev.position !== nextPosition
      || prev.height !== nextHeight
    root._barLayout = {
      owner: owner,
      enabled: Boolean(enabled),
      position: nextPosition,
      height: nextHeight
    }
    if (!changed) return false
    // The layout moved, which is the only event on this contract. A binding
    // on enabled/position/height calls this again for the state it just
    // published, and the `changed` test above is what keeps that to one line
    // rather than one per evaluation.
    //
    // DEBUG, and the reason is the owner: `_ownerName` returns `owner.tag`, and
    // the only publisher in the tree is `Bar.qml`, whose tag is "bar". So the
    // most prominent part of this line can only ever read "published by bar" -
    // a constant spending the place a fact should go. What varies is on/off,
    // position and height, and all three are on screen and in Settings at the
    // moment this prints. The shell announcing its own bookkeeping is not an
    // event a reader can act on.
    Log.debug("bar layout published by " + root._ownerName(owner) + ": "
      + (Boolean(enabled) ? "on" : "off") + " at " + nextPosition + ", "
      + nextHeight + "px")
    // The half of the transition the line above cannot carry: a position is
    // only a change if the reader knows where it came from.
    Log.debug("bar layout was " + root._ownerName(prev.owner) + ": "
      + (prev.enabled ? "on" : "off") + " at " + prev.position + ", "
      + prev.height + "px")
    return true  // changed: the only path that reaches here after a write
  }

  function releaseBarLayout(owner): bool {
    if (owner === null || owner === undefined || root._barLayout.owner !== owner)
      return false

    root._barLayout = {
      owner: null,
      enabled: false,
      position: "top",
      height: 0
    }
    // DEBUG for the same reason, and one more: a release happens when the bar
    // is torn down, which on the ordinary path is the shell exiting. That is
    // not an event, it is the end of the session.
    Log.debug("bar layout released by " + root._ownerName(owner))
    return true
  }

  // The published owner is a live QML object and an object is not a value
  // this log publishes: the ownership check is by reference, while the line
  // needs a name. `tag` is the shell's own name for a singleton, so it is
  // what a reader joins against the unit scope and the registry entry.
  //
  // Both call sites above pass the caller that is on the stack right now,
  // which is what makes this a derivation rather than a guard: the reference
  // tests in front of them refuse a `prev.owner` that is not this same live
  // object, so the one read is one read of a live singleton. A name read off
  // some other live object would need a guard against a half-destroyed read,
  // and this derivation has none.
  function _ownerName(owner) {
    if (owner === null || owner === undefined) return "unpublished"
    if (typeof owner === "string") return Log.summarize(owner)
    if (typeof owner.tag === "string" && owner.tag !== "") return owner.tag
    return "unknown"
  }
}
