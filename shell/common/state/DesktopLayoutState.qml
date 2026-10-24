pragma Singleton

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

  // --- island pile-clearance ------------------------------------------------
  //
  // One IslandHost per bar view (per screen) publishes its card footprint
  // here as PLAIN DATA; the notification pile reads the record for its own
  // screen by name. Values, never object refs: every publish writes a fresh
  // record and reassigns the map, so any host move re-fires every reader by
  // value instead of depending on cross-object binding chains (which miss
  // open/close edges). Copy-on-write, no-op-guarded.
  property var _islands: ({})

  // Upsert the record for `screenName`. A no-op (same showing/top/bottom)
  // writes nothing and returns false, so parks that change nothing stay
  // silent.
  function publishIsland(screenName, showing, top, bottom) {
    const key = String(screenName || "")
    if (key === "") return false
    const on = showing === true
    const t = Number(top)
    const b = Number(bottom)
    const cur = root._islands
    const old = cur[key]
    if (old !== undefined && old !== null && typeof old === "object"
      && old.showing === on
      && Number(old.top) === (isFinite(t) ? t : 0)
      && Number(old.bottom) === (isFinite(b) ? b : 0)) return false
    const next = Object.assign({}, cur)
    next[key] = {
      showing: on,
      top: isFinite(t) ? t : 0,
      bottom: isFinite(b) ? b : 0
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
