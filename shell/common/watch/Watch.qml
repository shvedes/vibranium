pragma Singleton
pragma ComponentBehavior: Bound
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../text/UnitIpc.js" as UnitIpc

// Watch governor - one FileView per unique path, reference counted,
// coalesced per tick, echo suppression. Subscribers are notified on
// file change, creation, or deletion. The governor owns the echo
// suppression: a write the shell itself made is not dispatched back to
// the subscribers.
Singleton {
  id: root

  readonly property string tag: "watch"

  // path -> { subs: [cb], refCount: int, view: FileView, lastWritten: string, pending: bool, eventCount: int }
  property var _watchers: ({})

  // Coalesced dispatch: one event-loop tick batches rapid changes.
  property bool _dispatchScheduled: false

  // reload() completes asynchronously and announces completion by emitting
  // `loaded` (or `loadFailed` on a missing file). Both of those signals are
  // routed back into _markPending, so a reload issued from inside a dispatch
  // would re-arm the dispatch that issued it - unbounded. This flag holds
  // re-entry closed for the duration of the dispatch, which is exactly the
  // window in which the reload's own completion signals can arrive.
  // Only reload-driven re-entry is suppressed: a subscriber's write lands as
  // an inotify event delivered on the event loop after the dispatch returns.
  property bool _dispatching: false

  // One coalesced dispatch per event-loop tick; rapid file events batch
  // without a debounce Timer.
  //
  // Why not PersistentProperties: subscribers need inotify fan-out to N
  // paths plus a synchronous readback barrier (reload + waitForJob, see
  // _readView), not one persisted property. The coalescing here is the
  // whole of what a persistor would add.
  function _scheduleDispatch() {
    if (root._dispatchScheduled) return
    root._dispatchScheduled = true
    Qt.callLater(() => root._dispatchPending())
  }

  // Read the current body of a path through the view Watch already holds.
  //
  // A watched FileView does not republish on its own when the file changes:
  // measured on this build, text() still returned the pre-change body 1.5s
  // after fileChanged with no reload. reload() is what republishes it, and
  // reload() is asynchronous - text() read immediately after reload() still
  // returned the old body. waitForJob() is the barrier that makes the reload
  // observable: reload() followed by waitForJob() yields the new body
  // synchronously, 400/400 rounds on real external writes.
  //
  // Re-pointing the view at the path it already holds, without clearing
  // `path` first, is not an alternative: waitForJob() then reports false
  // while text() keeps returning the cached body.
  //
  // Returns { ok, text }. ok=false means the path is unreadable or absent.
  function _readView(path, view) {
    if (!view) return { ok: false, text: null }
    view.reload()
    const ok = view.waitForJob()
    return { ok: ok, text: ok ? view.text() : null }
  }

  // Subscribe to a path. Returns an unsubscribe closure.
  // The callback is invoked immediately if the file currently exists
  // (like Bus.latest replay), and on every subsequent change.
  function subscribe(path, cb) {
    if (typeof path !== "string" || path === "" || typeof cb !== "function") {
      return () => {}
    }
    let entry = root._watchers[path]
    let reusedInitial = null
    if (!entry) {
      entry = root._ensureWatcher(path)
      if (!entry) return () => {}
      if (entry._hasInitial) {
        reusedInitial = { ok: entry._initialOk, text: entry._initialText }
        entry._hasInitial = false
      }
    }
    entry.subs = entry.subs.concat([cb])
    entry.refCount++
    // Update the map with fresh object for change notification
    const next = Object.assign({}, root._watchers)
    next[path] = entry
    root._watchers = next

    // Immediate replay if file exists.
    // Reuses the probe _ensureWatcher already did for a fresh path, so a
    // new subscription costs one reload+waitForJob instead of two.
    const initial = reusedInitial !== null ? reusedInitial : _readView(path, entry.view)
    if (initial.ok && initial.text !== null && initial.text !== "") {
      cb(initial.text)
    } else {
      // File may not exist yet; still call with null to indicate absent
      cb(null)
    }

    let unsubscribed = false
    return () => {
      if (unsubscribed) return
      unsubscribed = true
      root._unsubscribe(path, cb)
    }
  }

  function _unsubscribe(path, cb) {
    const entry = root._watchers[path]
    if (!entry) return
    entry.subs = entry.subs.filter(s => s !== cb)
    entry.refCount--
    if (entry.refCount <= 0) {
      // No more subscribers - destroy the FileView
      if (entry.view) entry.view.destroy()
      if (entry.dirView) entry.dirView.destroy()
      const next = Object.assign({}, root._watchers)
      delete next[path]
      root._watchers = next
    } else {
      const next = Object.assign({}, root._watchers)
      next[path] = entry
      root._watchers = next
    }
  }

  function _ensureWatcher(path) {
    // Create watcher with declarative handlers via slotKey
    const view = watcherComp.createObject(root, { slotKey: path })
    view.path = path

    // Fallback: also watch parent dir for creation of absent file
    let dirView = null
    // Check if file exists initially; if not, watch parent.
    // The single probe here doubles as subscribe's immediate replay, so a
    // fresh path costs one reload+waitForJob total instead of two.
    const probe = _readView(path, view)
    const exists = probe.ok
    if (!exists) {
      const dir = path.substring(0, path.lastIndexOf("/"))
      if (dir !== "") {
        dirView = dirWatcherComp.createObject(root, { slotKey: path })
        dirView.path = dir
      }
    }

    const entry = {
      subs: [],
      refCount: 0,
      view: view,
      dirView: dirView,
      lastWritten: "",
      pending: false,
      eventCount: 0,
      _hasInitial: true,
      _initialOk: probe.ok,
      _initialText: probe.text
    }
    const next = Object.assign({}, root._watchers)
    next[path] = entry
    root._watchers = next
    return entry
  }

  function _markPending(path) {
    const entry = root._watchers[path]
    if (!entry) return
    // A reload issued by the dispatch below announces itself through this
    // same path. Letting it through would re-arm the dispatch that issued
    // it, once per completion signal, forever.
    if (root._dispatching) return
    entry.pending = true
    entry.eventCount++
    const next = Object.assign({}, root._watchers)
    next[path] = entry
    root._watchers = next
    root._scheduleDispatch()
  }

  function _dispatchPending() {
    root._dispatchScheduled = false
    root._dispatching = true
    for (const path in root._watchers) {
      const entry = root._watchers[path]
      if (!entry || !entry.pending) continue
      entry.pending = false
      // Read current content
      let text = null
      let ok = false
      const r = _readView(path, entry.view)
      ok = r.ok
      text = r.text
      // Echo suppression
      if (entry.lastWritten !== "" && text === entry.lastWritten) {
        // Our own write - skip dispatch, but clear the flag after one echo
        // Keep lastWritten for next comparison, but don't dispatch
        const next = Object.assign({}, root._watchers)
        next[path] = entry
        root._watchers = next
        continue
      }
      // Dispatch to subscribers
      for (let i = 0; i < entry.subs.length; i++) {
        entry.subs[i](text)
      }
      const next = Object.assign({}, root._watchers)
      next[path] = entry
      root._watchers = next
    }
    root._dispatching = false
  }

  // Diagnostic IPC: watch status (paths, subscriber counts, event counters)
  // Called via `qs ipc call watch status`
  function status() {
    const out = {}
    for (const path in root._watchers) {
      const e = root._watchers[path]
      out[path] = { subs: e.subs.length, refCount: e.refCount, events: e.eventCount, pending: e.pending }
    }
    const json = JSON.stringify(out)
    return out
  }

  Component {
    id: watcherComp
    FileView {
      property string slotKey: ""
      watchChanges: true
      printErrors: false
      onFileChanged: root._markPending(slotKey)
      onLoaded: root._markPending(slotKey)
      onLoadFailed: root._markPending(slotKey)
    }
  }

  Component {
    id: dirWatcherComp
    FileView {
      property string slotKey: ""
      watchChanges: true
      printErrors: false
      onFileChanged: {
        // Parent dir changed - the watched path may now exist.
        // Reading it through the view Watch holds for that path is the same
        // question the throwaway probe asked; a path that is still missing
        // reports ok=false and stays unwatched-by-file, since the dir
        // watcher is what brought us here.
        const e = root._watchers[slotKey]
        if (root._readView(slotKey, e ? e.view : null).ok) {
          root._markPending(slotKey)
        }
      }
    }
  }

  IpcHandler {
    target: "watch"
    function help(command: string): string {
      return UnitIpc.help("watch", "Watch", "file watch governor", [
        { name: "status", help: "paths, subs, events" },
      ], command)
    }
    function status(): string {
      const s = root.status()
      return JSON.stringify(s)
    }
    function ping(): string {
      return "pong"
    }
  }

  Component.onCompleted: {
    Registry.offer("watch", {
      title: "Watch",
      description: "file watch governor",
      verbNames: ["status", "help", "ping"]
    })
  }
  Component.onDestruction: Registry.unregister("watch")
}
