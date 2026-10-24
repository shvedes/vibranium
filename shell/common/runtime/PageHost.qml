pragma Singleton

import Quickshell

// Neutral page-injection contract between a state owner and the resident page
// surface that renders it. A state owner publishes page descriptors and the
// surface builds and registers them, so neither side names the other and the
// page table stays on the surface.
//
//   PageHost.adopt(handler)                 // page surface
//   const answer = PageHost.publish(page)   // state owner  { ok, code }
//   PageHost.reportDropped()                 // page surface
//   PageHost.replayPages()                   // page surface
//
// One surface answers at a time: a second handler is refused, because two
// surfaces would each hold a page table and a publish could land in either.
// Every entry point answers a defined value, so a state owner never infers
// whether its page is live - "published" means the surface registered the
// page, "no_surface" means no surface is adopted and the request is held for
// replay, "invalid_request" means the descriptor does not answer the contract
// shape, "rejected" means the surface declined it, and "handler_error" means
// the surface threw while registering.
Singleton {
  id: root

  // The surface discarded its page table, so every published page is gone and
  // its owner republishes. Emitted rather than inferred: a requester cannot
  // see the table, and a surface that comes and goes without reporting a
  // discard would leave a published page missing with nothing to retry it.
  signal pagesDropped()

  // Bounded so a caller can spend neither the retained request queue nor the
  // page-id key space without limit, the same reason the request gate caps its
  // labels.
  readonly property int idLimit: 128
  readonly property int pendingLimit: 8

  property var _handler: null
  property var _pending: []

  // The newest request per page id, kept whatever the delivery answered.
  // A request the surface declined for a reason that may pass - this
  // bundle does not take settings pages - is still the owner's newest
  // content, so the surface can ask for it again (see replayPages).
  // Bounded like the pending queue: a caller must not be able to grow the
  // retained map without limit.
  property var _latest: ({})

  // A surface installs its injection handler. Identity comparison is what
  // keeps a re-adopt of the same surface idempotent and keeps release
  // possible, so the handler is a stable reference and not a per-call closure.
  // A first adopt also replays the requests that arrived before any surface
  // existed: state owners are instantiated ahead of the page surface, and a
  // request from that window is honored instead of being dropped.
  function adopt(handler) {
    if (typeof handler !== "function") return false
    if (root._handler !== null && root._handler !== handler) return false
    root._handler = handler
    root._replayPending()
    return true
  }

  function release(handler) {
    if (root._handler !== handler) return false
    root._handler = null
    return true
  }

  // Publish one page described as { id, title, width, items, opts? }. The rows
  // are caller data: the contract checks the descriptor envelope only and
  // hands the rest to the surface untouched, so page layout stays with the
  // surface that renders it.
  function publish(page) {
    const request = root._request(page)
    if (request === null) return { ok: false, code: "invalid_request" }
    root._setLatest(request)
    const code = root._deliver(request)
    if (code === "published") root._setPending(request.id, null)
    else if (code === "no_surface") root._setPending(request.id, request)
    return { ok: code === "published", code: code }
  }

  // Deliver the newest request per page id again. The surface asks for
  // this when it activates a bundle that takes the pages it declined
  // before: a container reload drops the surface's page table and the
  // owners republish after the drop - but a cached reload does not
  // reload the containers, so the table the surface keeps can be empty
  // while the bundle that is active does take those pages.
  function replayPages() {
    const ids = Object.keys(root._latest)
    for (let i = 0; i < ids.length; i++) root._deliver(root._latest[ids[i]])
  }

  function _setLatest(request) {
    const next = Object.assign({}, root._latest)
    if (next[request.id] === undefined && Object.keys(next).length >= root.pendingLimit) {
      return false
    }
    next[request.id] = request
    root._latest = next
    return true
  }

  // The page surface dropped its table. Held requests survive it: a request
  // that no surface ever accepted is owed to the next one that appears.
  function reportDropped() {
    root.pagesDropped()
  }

  function _deliver(request) {
    if (root._handler === null) return "no_surface"
    try {
      return root._handler(request) === true ? "published" : "rejected"
    } catch (ignored) {
      return "handler_error"
    }
  }

  // The held queue carries one request per page id: a repeat publish replaces
  // the held request, a delivered publish drops it, and a full queue refuses
  // the hold rather than growing. A replay empties the queue before it
  // delivers, so a surface that publishes again while replaying cannot
  // deliver the same request twice.
  function _setPending(id, request) {
    let index = -1
    for (let i = 0; i < root._pending.length; i++) {
      if (root._pending[i].id === id) {
        index = i
        break
      }
    }
    if (request === null) {
      if (index < 0) return false
      const dropped = root._pending.slice()
      dropped.splice(index, 1)
      root._pending = dropped
      return true
    }
    const entry = Object.freeze({ id: id, request: request })
    if (index >= 0) {
      const replaced = root._pending.slice()
      replaced[index] = entry
      root._pending = replaced
      return true
    }
    if (root._pending.length >= root.pendingLimit) return false
    const appended = root._pending.slice()
    appended.push(entry)
    root._pending = appended
    return true
  }

  function _replayPending() {
    if (root._handler === null || root._pending.length === 0) return
    const held = root._pending
    root._pending = []
    for (let i = 0; i < held.length; i++) root._deliver(held[i].request)
  }

  function _request(page) {
    if (page === null || typeof page !== "object" || Array.isArray(page)) return null
    if (typeof page.id !== "string" || page.id.trim() === "" || page.id.length > root.idLimit) return null
    if (typeof page.title !== "string") return null
    if (typeof page.width !== "number" || !isFinite(page.width)) return null
    if (!Array.isArray(page.items)) return null
    if (page.opts !== undefined && (page.opts === null || typeof page.opts !== "object" || Array.isArray(page.opts))) return null
    return Object.freeze({
      id: page.id,
      title: page.title,
      width: page.width,
      items: page.items,
      opts: page.opts === undefined ? null : page.opts
    })
  }
}
