pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common

// FilePresence - ONE watched path, ONE watcher, many observers.
//
// Neutral mechanism, no policy: it answers a single question - does this
// path currently hold readable, non-empty content - and it answers it for
// whoever asks. Which path is authoritative, and what its presence MEANS,
// stay with the feature that asks. A caller decides that the presence of
// some include file is a shader state, or that a marker file means a
// session is live, and reads that answer here; this file never learns any
// of it. A feature's policy does not move into a common file merely to
// make it loadable.
//
// Why it exists: a presence verdict is global state, and a file watcher is
// a backend tracker. A per-output delegate that builds its own is a
// per-output copy of global state and a per-output inotify handle, so N
// monitors meant N watchers and N booleans that could disagree for a frame
// after a change. Here the count follows the PATH, not the consumer: N
// observers of one path share one watcher, and the last observer leaving
// destroys it.
//
// Lifecycle per path:
//   track(owner, path)     -> handle (bindable `present` + `revision`)
//   refresh(handle)        -> re-read now, answer the new verdict
//   release(handle)        -> drop one observation; the last one releases
//                             the watcher and the parked prober
// The returned handle is the reference the count is keyed on, so two
// delegates of the same feature never share a count. The owner string is
// the consumer's own name and is carried for diagnostics only; it is not
// an identity, so a reload that mints the same name again cannot inherit or
// strand a previous observation.
//
// The verdict, in one pure function (verdict): a read that did not complete
// is INACTIVE, never active, and only completed non-empty content counts
// as present. Absence is read from the empty text rather than from the
// load's success flag, because waitForJob() reports "the load cycle
// finished", not "the load succeeded" - an absent file finishes too.
Singleton {
  id: root

  readonly property string tag: "filePresence"

  // Aggregate revision: bumped whenever any tracked path's verdict
  // changes, and when a path is added or dropped. Per-path consumers
  // follow their own handle's revision instead; this is for a caller that
  // wants to know something moved.
  property int rev: 0

  // path -> { path, watcher, prober, present, revision, handles: [] }
  // The map is replaced wholesale on every mutation so a reader that
  // captured it re-reads instead of holding a stale entry object.
  property var _entries: ({})

  // The verdict rule, exposed and pure so it can be exercised without a
  // filesystem: `ok` is whether the read cycle completed, `text` is what
  // it produced. An incomplete or non-string read is inactive; completed
  // content is present only when something survives the trim.
  function verdict(ok, text): bool {
    if (ok !== true) return false
    if (typeof text !== "string") return false
    return text.trim() !== ""
  }

  // One blocking read through the entry's own parked prober. The prober is
  // detached and re-pointed at the path so the read cannot answer from
  // whatever the watcher last cached: the watcher fires loaded,
  // loadFailed and fileChanged, and each of those only says "look now".
  // waitForJob()'s answer is deliberately not the verdict - it means the
  // cycle finished - so the text is, and a read that threw reads as empty.
  function _read(entry) {
    let ok = false
    try {
      entry.prober.path = ""
      entry.prober.path = entry.path
      ok = entry.prober.waitForJob()
    } catch (ignored) {
      ok = false
    }
    let text = ""
    try {
      text = ok ? entry.prober.text() : ""
    } catch (ignored) {
      text = ""
    }
    if (typeof text !== "string") text = ""
    return root.verdict(ok, text)
  }

  // Re-probe a tracked path and publish the new verdict to every observer
  // of it. Answers whether the verdict actually moved, so a caller can
  // tell "re-read, unchanged" from "re-read, changed".
  function reprobe(path): bool {
    if (typeof path !== "string" || path === "") return false
    const entry = root._entries[path]
    if (entry === undefined) return false
    const nextPresent = root._read(entry)
    if (nextPresent === entry.present) return false
    root._publish(path, Object.assign({}, entry, {
      present: nextPresent,
      revision: entry.revision + 1
    }))
    root.rev++
    return true
  }

  // Re-read a handle's path now and answer the verdict that read produced.
  // This is the entry a caller uses straight after a command it fired that
  // is expected to have changed the file: the command is fire-and-forget,
  // so this is the fast path and the watcher's own later event is the
  // confirmation. Every observer of the path follows the same verdict.
  function refresh(handle): bool {
    if (handle === null || handle === undefined) return false
    root.reprobe(String(handle.path))
    const entry = root._entries[String(handle.path)]
    return entry !== undefined ? entry.present : false
  }

  // Create the shared pair for a path if it does not exist yet and take
  // the first verdict synchronously, so an observer that binds on the same
  // turn already reads the real answer rather than a default.
  function _ensureEntry(path) {
    const existing = root._entries[path]
    if (existing !== undefined) return existing
    const prober = proberComp.createObject(root, { slotPath: path })
    const watcher = watcherComp.createObject(root, { slotPath: path })
    const entry = {
      path: path,
      watcher: watcher,
      prober: prober,
      present: false,
      revision: 0,
      handles: []
    }
    root._store(path, entry)
    // path goes on last: setting it arms the watch, and the first verdict
    // has to be taken through the prober rather than inherited from
    // whatever the watcher happens to have already reported.
    watcher.path = path
    root.reprobe(path)
    return root._entries[path]
  }

  // Register an observer of `path` and return its handle, or null when the
  // arguments do not answer the contract. Every call is its own
  // observation: the owner string is the consumer's name for diagnostics,
  // the handle is the identity the reference count is keyed on.
  //
  // The handle is created with a null parent on purpose. Parented to the
  // singleton it would outlive its own release - a feature that opened and
  // closed its bar a hundred times would leave a hundred observation
  // objects behind, since nothing but the entry's list ever referenced
  // them. Unparented, the handle lives exactly as long as the entry's list
  // and the consumer's own reference do.
  function track(owner, path) {
    if (typeof owner !== "string" || owner === "") return null
    if (typeof path !== "string" || path === "") return null
    const entry = root._ensureEntry(path)
    if (entry === undefined) return null
    let handle = null
    try {
      handle = handleComp.createObject(null, {
        trackOwner: owner,
        trackPath: path
      })
    } catch (ignored) {
      return null
    }
    if (handle === null) return null
    root._publish(path, Object.assign({}, entry, {
      handles: entry.handles.concat([handle])
    }))
    // The observation count for the path is what a reader wants here: the
    // FileView watcher is one per path by construction, so the number that
    // can disagree between outputs is the number of observers. DEBUG and
    // gated - track/release is lifecycle, and a per-monitor feature repeats
    // it once per surface.
    //
    // The parent of this DEBUG is the consumer's own line: the feature that
    // started watching a path already said what it was watching for, and this
    // mechanism cannot know which features those are - it is the neutral
    // mechanism, and a policy is not what it is here to report.
    //
    // Read back off the published entry rather than off `entry`, because
    // `_publish` replaced the map: the count that matters is the one every
    // observer of the path now holds, which is one higher than the count this
    // call started from. Path and owner are bounded because both are the
    // consumer's own strings rather than this file's vocabulary.
    const tracked = Log.at()
    if (tracked.allows("debug")) {
      tracked.debug("observed " + Log.summarize(owner) + " on " + Log.summarize(path)
        + ", " + root._entries[path].handles.length + " observers")
    }
    return handle
  }

  // Drop one observation. Answers whether an observation was actually
  // dropped, so a teardown can assert it: an unknown handle, a handle
  // twice released and a non-handle all answer false. The last observer
  // leaving destroys the watcher and the prober and removes the entry, so
  // a feature closed on every output leaves no watched path behind.
  function release(handle) {
    if (handle === null || handle === undefined) return false
    const path = String(handle.path)
    const entry = root._entries[path]
    if (entry === undefined) return false
    const remaining = entry.handles.filter(h => h !== handle)
    if (remaining.length === entry.handles.length) return false
    if (remaining.length > 0) {
      root._publish(path, Object.assign({}, entry, { handles: remaining }))
      return true
    }
    if (entry.watcher !== null && entry.watcher !== undefined) entry.watcher.destroy()
    if (entry.prober !== null && entry.prober !== undefined) entry.prober.destroy()
    const next = Object.assign({}, root._entries)
    delete next[path]
    root._entries = next
    root.rev++
    // The last observation leaving is the line that matters: it is the one
    // that takes the watcher and the parked prober down with it, and it is
    // the one a leaked surface would be missing. Only this branch reports,
    // because the branches above are a count going down and the entry below is
    // a count reaching zero.
    //
    // The parent of this DEBUG is the consumer's own teardown line, for the
    // same reason `track`'s parent is the consumer's own start line: this file
    // reports the count and not what the count was for.
    const released = Log.at()
    if (released.allows("debug")) {
      released.debug("released the last observer of " + Log.summarize(path)
        + " (" + Log.summarize(String(handle.owner))
        + "), watcher and prober released")
    }
    return true
  }

  // Per-path view of what is actually held: the watcher and prober object
  // counts, the live observer count, and the current verdict. This is what
  // "one watcher, many observers" is checked against - a consumer count
  // that grows while these stay at one is the whole point.
  function diagnostics() {
    const out = {}
    for (const path in root._entries) {
      const entry = root._entries[path]
      if (entry === undefined) continue
      out[path] = {
        watchers: entry.watcher !== null && entry.watcher !== undefined ? 1 : 0,
        probes: entry.prober !== null && entry.prober !== undefined ? 1 : 0,
        observers: entry.handles.length,
        present: entry.present,
        revision: entry.revision
      }
    }
    return out
  }

  // Publish an entry: hand every observer the new verdict as a fresh state
  // object, then swap the map so a reader that captured the old map
  // re-reads. The fresh object is what re-evaluates the handle's read-only
  // views without exposing them to an external write.
  function _publish(path, entry) {
    const handles = entry.handles
    for (let i = 0; i < handles.length; i++) {
      const handle = handles[i]
      if (handle === null || handle === undefined) continue
      handle.trackState = { present: entry.present, revision: entry.revision }
    }
    const next = Object.assign({}, root._entries)
    next[path] = entry
    root._entries = next
  }

  function _store(path, entry) {
    const next = Object.assign({}, root._entries)
    next[path] = entry
    root._entries = next
  }

  // The single watcher per path. Every watcher event - including a failed
  // load, which is what a deletion looks like - is only a "look now": the
  // verdict comes from the prober, so a failed read lands on inactive
  // rather than leaving the last good text standing.
  Component {
    id: watcherComp

    FileView {
      property string slotPath: ""

      watchChanges: true
      printErrors: false
      onLoaded: root.reprobe(slotPath)
      onLoadFailed: root.reprobe(slotPath)
      onFileChanged: root.reprobe(slotPath)
    }
  }

  // The parked prober: never given a path until a read is asked for, so it
  // holds no watch and no cached text between reads.
  Component {
    id: proberComp

    FileView {
      property string slotPath: ""
      printErrors: false
    }
  }

  // One observation. The two read-only views are derived from a state
  // object the tracker replaces, so a binding on `present` re-evaluates on
  // every verdict change and no consumer can write the verdict.
  Component {
    id: handleComp

    QtObject {
      id: observation

      property string trackOwner: ""
      property string trackPath: ""
      property var trackState: ({ present: false, revision: 0 })

      readonly property string owner: observation.trackOwner
      readonly property string path: observation.trackPath
      readonly property bool present: observation.trackState.present
      readonly property int revision: observation.trackState.revision
    }
  }
}
