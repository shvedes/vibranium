import QtQml

// Scroll and selection frames for one list view, namespaced by owner
// and bounded per owner.
//
// `owner` is an opaque string handed over by the consumer. The store
// never derives it from a view, a component type or an object identity,
// and it is a namespace and a bound, never a second view: `view` stays
// a single per-instance property, so one instance backs one list while
// frames from several owners share it without cross-talk.
//
// A live restore token pins exactly one record: the frame of the active
// key the open transition is anchored on, in the owner that opened it.
// The destination key is not known until commit(), so the pin is what
// keeps a frame from vanishing under a transition still in flight -
// forget, forgetPrefix, LRU eviction and releaseOwner all refuse it. The
// pin lives only between begin() and the commit or clear that closes the
// window, so a consumer that must clean a namespace the window protects
// waits for `tokenLive` to fall and retries.
QtObject {
  id: root

  property var view: null

  readonly property bool suspended: root._suspended
  readonly property string activeKey: root._activeKey
  readonly property int generation: root._generation
  // True between begin() and the commit or clear that closes the window.
  readonly property bool tokenLive: root._activeToken >= 0

  // Retained frames per owner. PassPanel navigation touches roughly 140
  // distinct view keys across a long open session, so 32 keeps the pages
  // navigation actually returns to while bounding a pathological key
  // loop. Eviction is least recently used and skips the active key, so a
  // dropped frame only means a re-visit starts at the top instead of the
  // remembered row.
  property int maxFramesPerOwner: 32

  property bool _suspended: false
  // The transition claim is per instance, not per owner: one instance
  // has one view, so only one transition window can be open at a time
  // and the frames of every owner are read against that same view.
  property string _activeKey: ""
  property string _windowOwner: ""
  property int _generation: 0
  property int _nextToken: 0
  property int _activeToken: -1
  property int _touchClock: 0
  property var _frames: Object.create(null)

  function _validOwner(owner) {
    return typeof owner === "string" && owner.length > 0
  }

  function _validKey(key) {
    return typeof key === "string" && key.length > 0
  }

  function _validIndex(value) {
    return typeof value === "number" && isFinite(value)
      && Math.floor(value) === value && value >= 0
  }

  function _validFrame(frame) {
    if (frame === null || typeof frame !== "object")
      return false
    if (!root._validIndex(frame.index))
      return false
    if (frame.y !== null && (typeof frame.y !== "number" || !isFinite(frame.y)))
      return false
    return typeof frame.identity === "string"
  }

  // Live half of a restore: the row must still exist, still be
  // selectable and still carry the identity the frame was captured with.
  function _matchesView(frame) {
    const view = root.view
    if (!view)
      return false
    if (frame.index >= view.count)
      return false
    if (typeof view.isSelectable === "function" && view.isSelectable(frame.index) !== true)
      return false
    if (typeof view.rowIdentity !== "function")
      return false
    const identity = view.rowIdentity(frame.index)
    if (identity === null || identity === undefined)
      return false
    return String(identity) === frame.identity
  }

  function _bucket(owner, create) {
    if (!Object.prototype.hasOwnProperty.call(root._frames, owner)) {
      if (create !== true)
        return null
      root._frames[owner] = Object.create(null)
    }
    return root._frames[owner]
  }

  function _activeKeyFor(owner) {
    return owner === root._windowOwner ? root._activeKey : ""
  }

  function _pinned(owner, key) {
    return root._activeToken >= 0 && root._validKey(key)
      && key === root._activeKeyFor(owner)
  }

  // Ungated removal. Public removals gate on the token window; begin()
  // uses this directly, before its own window exists.
  function _drop(owner, key) {
    const bucket = root._bucket(owner, false)
    if (!bucket || !Object.prototype.hasOwnProperty.call(bucket, key))
      return false
    delete bucket[key]
    if (Object.keys(bucket).length === 0)
      delete root._frames[owner]
    return true
  }

  function _write(owner, key, index, y, identity) {
    const bucket = root._bucket(owner, true)
    root._touchClock++
    bucket[key] = { index: index, y: y, identity: identity, touch: root._touchClock }
    root._trim(owner)
  }

  // Least recently used eviction, active key exempt (a window pinning it
  // never loses it either). Runs after every write, so a key loop cannot
  // grow the store past the bound.
  function _trim(owner) {
    const bucket = root._bucket(owner, false)
    if (!bucket)
      return 0
    const keys = Object.keys(bucket)
    if (keys.length <= root.maxFramesPerOwner)
      return 0
    const active = root._activeKeyFor(owner)
    const ordered = keys.slice().sort((a, b) => {
      const delta = (bucket[a].touch || 0) - (bucket[b].touch || 0)
      if (delta !== 0)
        return delta
      return a < b ? -1 : 1
    })
    let removed = 0
    for (let i = 0; i < ordered.length; i++) {
      if (removed >= keys.length - root.maxFramesPerOwner)
        break
      if (ordered[i] === active)
        continue
      if (!Object.prototype.hasOwnProperty.call(bucket, ordered[i]))
        continue
      delete bucket[ordered[i]]
      removed++
    }
    if (Object.keys(bucket).length === 0)
      delete root._frames[owner]
    return removed
  }

  function _capture(force) {
    if (!force && root._suspended)
      return false
    if (!root._validKey(root._activeKey) || !root._validOwner(root._windowOwner))
      return false

    const view = root.view
    if (!view)
      return false

    const index = view.currentIndex
    if (!root._validIndex(index) || index >= view.count)
      return false
    if (view.currentItem === null || view.currentItem === undefined)
      return false
    if (typeof view.isSelectable === "function" && view.isSelectable(index) !== true)
      return false
    if (typeof view.rowIdentity !== "function")
      return false

    const rawIdentity = view.rowIdentity(index)
    if (rawIdentity === null || rawIdentity === undefined)
      return false
    const y = view.contentY
    if (typeof y !== "number" || !isFinite(y))
      return false

    root._write(root._windowOwner, root._activeKey, index, y, String(rawIdentity))
    return true
  }

  // Opens the restore window and returns its token. forgetSource drops
  // the frame of the key this transition abandons, before the new window
  // exists: that key is the one the store is leaving, so the window it
  // just opened must not refuse its own cleanup.
  function begin(owner, forgetSource) {
    if (!root._validOwner(owner))
      return -1
    if (!root._suspended)
      root._capture(false)
    if (forgetSource === true)
      root._drop(root._windowOwner, root._activeKey)
    root._windowOwner = owner
    root._suspended = true
    root._nextToken++
    root._activeToken = root._nextToken
    return root._activeToken
  }

  function commit(token, destinationKey) {
    if (token !== root._activeToken || !root._validKey(destinationKey))
      return false
    root._activeKey = destinationKey
    root._activeToken = -1
    root._suspended = false
    root._capture(true)
    return true
  }

  function track() {
    if (root._suspended)
      return false
    return root._capture(false)
  }

  function frameFor(owner, key) {
    if (!root._validOwner(owner) || !root._validKey(key) || !root.view)
      return null
    const bucket = root._bucket(owner, false)
    if (!bucket || !Object.prototype.hasOwnProperty.call(bucket, key))
      return null

    const frame = bucket[key]
    if (!root._validFrame(frame))
      return null
    if (!root._matchesView(frame))
      return null

    return { index: frame.index, y: frame.y, identity: frame.identity }
  }

  // A frame with a position (y !== null) claims the live view, so it is
  // validated against it exactly like a restore and a stale index is
  // refused at write time. A seed (y === null) names a row of the view
  // the next rebuild installs - that row does not exist yet, and its
  // index would be meaningless against the rows on screen - so it is
  // validated on read instead, by frameFor().
  function put(owner, key, frame) {
    if (!root._validOwner(owner) || !root._validKey(key) || !root._validFrame(frame))
      return false
    // An empty identity can never match rowIdentity(), so the frame
    // could only ever be dead weight.
    if (frame.identity === "")
      return false
    if (frame.y !== null && !root._matchesView(frame))
      return false
    root._write(owner, key, frame.index, frame.y, frame.identity)
    return true
  }

  function forget(owner, key) {
    if (!root._validOwner(owner) || !root._validKey(key))
      return false
    if (root._pinned(owner, key))
      return false
    return root._drop(owner, key)
  }

  // The pinned record is skipped and not counted, so a caller can tell
  // that a prefix outlived the window it was issued in.
  function forgetPrefix(owner, prefix) {
    if (!root._validOwner(owner))
      return 0
    if (typeof prefix !== "string" || prefix.length === 0)
      return 0
    const bucket = root._bucket(owner, false)
    if (!bucket)
      return 0
    const keys = Object.keys(bucket)
    let removed = 0
    for (let i = 0; i < keys.length; i++) {
      if (!keys[i].startsWith(prefix))
        continue
      if (root._pinned(owner, keys[i]))
        continue
      if (!Object.prototype.hasOwnProperty.call(bucket, keys[i]))
        continue
      delete bucket[keys[i]]
      removed++
    }
    if (Object.keys(bucket).length === 0)
      delete root._frames[owner]
    return removed
  }

  // Drops every frame the owner holds and gives up its active-key claim.
  // An outstanding token is deliberately left alone: a commit arriving
  // afterwards still resolves, but with no frame left to restore, so the
  // owner restarts cold. Use clearOwner() when the token must die too.
  function releaseOwner(owner) {
    if (!root._validOwner(owner))
      return 0
    const bucket = root._bucket(owner, false)
    let removed = 0
    if (bucket) {
      const keys = Object.keys(bucket)
      for (let i = 0; i < keys.length; i++) {
        if (root._pinned(owner, keys[i]))
          continue
        delete bucket[keys[i]]
        removed++
      }
    }
    if (!Object.prototype.hasOwnProperty.call(root._frames, owner)
        || Object.keys(root._frames[owner]).length === 0)
      delete root._frames[owner]
    if (root._windowOwner === owner) {
      root._activeKey = ""
      root._suspended = true
    }
    return removed
  }

  // releaseOwner() plus a dead token and a generation bump, so a token
  // the consumer is still holding for this owner is rejected by its next
  // commit instead of landing on a cleared namespace. The window dies
  // first, so the frame it pinned is dropped with the rest.
  function clearOwner(owner) {
    if (!root._validOwner(owner))
      return 0
    if (root._windowOwner === owner)
      root._activeToken = -1
    const removed = root.releaseOwner(owner)
    root._generation++
    return removed
  }

  function clear() {
    root._frames = Object.create(null)
    root._activeKey = ""
    root._windowOwner = ""
    root._suspended = true
    root._activeToken = -1
    root._generation++
  }
}
