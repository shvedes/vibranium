pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
// The media set is owned by MediaState, so the warmer rides that state
// instead of taking a second subscription to the MPRIS backend.
import qs.services as Core

// Media art warmer: decodes covers up front and holds them, so island /
// OSD / bar Images hit the shared pixmap cache instead of fetching on
// open. Resident warmers are demand driven and bounded:
//
//   - demand is explicit. The active player's cover is demanded for it -
//     that is the cover every now-playing surface shows - and a surface
//     demands the one it is about to display. Nothing is warmed for a
//     player nobody is showing.
//   - a url is admitted only while it is a live player's cover, so the
//     warmer stays deduplicated to the current players: no player, no
//     entry, and nothing outlives the player it came from. There is no
//     historical cache here, on purpose.
//   - `cap` is the last word. A request past it is refused rather than
//     grown, and the coldest entry is evicted to make room. size,
//     atCap, evictedUrls and refusedRequests are the diagnostics.
//
// Eviction drops the coldest (least recently demanded) entry and the
// model is ordered oldest first, so a new cover appends instead of
// shifting every warmer's source. A cover evicted while a surface still
// shows it simply decodes on demand there.
Singleton {
  id: root

  readonly property string tag: "mediaArt"

  // Six covers: the active player plus a few surfaces mid-switch. A
  // pathological player set cannot grow the warmer past this.
  readonly property int cap: 6
  // The active player's cover, and the only trigger this file owns.
  readonly property string activeArtUrl: Core.MediaState.activeArtUrl

  // url -> { url, refs, active, order }. `refs` counts the surfaces
  // displaying it, `active` marks the active player's cover, `order` is
  // the recency stamp eviction reads. Replaced wholesale on every
  // mutation, so a reader re-reads instead of holding a stale entry.
  property var _entries: ({})
  property int _clock: 0
  property int _evicted: 0
  property int _refused: 0

  // Every live cover, deduplicated: one entry per url however many
  // players report it. This is also the membership the warmer is allowed
  // to hold, which is what keeps it to the current players.
  readonly property var playerUrls: {
    const out = []
    const ps = Core.MediaState.players
    for (let i = 0; i < ps.length; i++) {
      const u = ps[i] ? String(ps[i].trackArtUrl ?? "") : ""
      if (u !== "" && out.indexOf(u) < 0) out.push(u)
    }
    return out
  }
  readonly property var warmUrls: root._plan()
  readonly property int size: Object.keys(root._entries).length
  readonly property bool atCap: root.size >= root.cap
  readonly property int evictedUrls: root._evicted
  readonly property int refusedRequests: root._refused

  function _known(url) {
    return root.playerUrls.indexOf(url) >= 0
  }

  function _coldest(entries) {
    let url = ""
    let order = Number.POSITIVE_INFINITY
    for (const key of Object.keys(entries)) {
      if (entries[key].order < order) {
        order = entries[key].order
        url = key
      }
    }
    return url
  }

  // The one place the bound is applied: an entry nothing needs any more
  // goes first, then the oldest survivors past `cap`.
  function _store(next) {
    for (const key of Object.keys(next)) {
      if (next[key].refs > 0 || next[key].active) continue
      delete next[key]
    }
    while (Object.keys(next).length > root.cap) {
      const victim = root._coldest(next)
      if (victim === "") break
      delete next[victim]
      root._evicted += 1
    }
    root._entries = next
  }

  // A surface is about to display this cover. Refused past the cap rather
  // than grown, and refused outright for anything that is not a live
  // player's cover, so a stale url cannot start a cache.
  function request(url) {
    const want = String(url || "")
    if (want === "") return false
    // A url that is not a live player's cover is a stale or foreign
    // demand, not a cache to grow: refused, and counted as one.
    if (!root._known(want)) {
      root._refused += 1
      return false
    }
    const current = root._entries[want]
    if (!current && root.atCap) {
      root._refused += 1
      return false
    }
    const next = Object.assign({}, root._entries)
    next[want] = {
      url: want,
      refs: (current ? current.refs : 0) + 1,
      active: current ? current.active : false,
      order: ++root._clock,
    }
    root._store(next)
    return true
  }

  // A surface is done with this cover. The entry goes when the last
  // surface lets go of it and it is not the active cover either.
  function release(url) {
    const want = String(url || "")
    const current = root._entries[want]
    if (!current) return false
    const next = Object.assign({}, root._entries)
    const refs = current.refs - 1
    next[want] = {
      url: want,
      refs: refs > 0 ? refs : 0,
      active: current.active,
      order: current.order,
    }
    root._store(next)
    return true
  }

  // The active player's cover. The one url the warmer holds for a player
  // no surface is showing yet, because every now-playing surface asks for
  // it next; a player that leaves clears the flag, so its cover leaves
  // with it. A player with no cover at all clears the flag and admits
  // nothing, rather than standing in an entry for an empty url.
  function setActive(url) {
    const want = String(url || "")
    const next = Object.assign({}, root._entries)
    for (const key of Object.keys(next)) {
      if (key === want || next[key].active === false) continue
      next[key] = { url: next[key].url, refs: next[key].refs, active: false, order: next[key].order }
    }
    if (want !== "" && root._known(want)) {
      const current = next[want]
      next[want] = {
        url: want,
        refs: current ? current.refs : 0,
        active: true,
        order: ++root._clock,
      }
    }
    root._store(next)
    return root._entries[want] !== undefined
  }

  // Oldest first, so a fresh cover appends and no existing warmer sees
  // its source move. `_store` already bounds the map; the cut here is the
  // same number read from one place.
  function _plan() {
    const keys = Object.keys(root._entries).sort((a, b) => root._entries[a].order - root._entries[b].order)
    const urls = []
    for (let i = 0; i < keys.length && urls.length < root.cap; i++) urls.push(keys[i])
    return urls
  }

  onActiveArtUrlChanged: root.setActive(root.activeArtUrl)

  Component.onCompleted: root.setActive(root.activeArtUrl)

  // Resident warmers: hidden Images still decode on source set, so the
  // cover for the next track is ready whether or not a surface showed it.
  Repeater {
    model: root.warmUrls

    Image {
      required property string modelData

      visible: false
      asynchronous: true
      cache: true
      sourceSize.width: 256
      sourceSize.height: 256
      source: modelData
    }
  }
}
