pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io

// DocumentAdoption - ONE read of a document, many observers, once.
//
// Neutral mechanism, no policy: it reads the file a caller names exactly
// once while somebody is observing, and hands the text to whoever asked.
// What the text MEANS, what a record in it is, whether it is adopted into
// a cache or a table or a config, and when a fresh copy is needed - all of
// that stays with the caller. A caller's policy does not move into a
// common file merely to make it loadable: the caller still parses the
// document and still decides what to do with the answer.
//
// Why it exists: a cold start has no answer yet, so every consumer that
// needs one reaches for a reader - and a reader per consumer is a reader
// per output, all of them on the same file, all of them racing to publish
// the same thing. Here the read follows the PATH, not the consumer: the
// first observer opens the single reader, every observer that arrives
// while it is pending joins it instead of opening another, and every
// observer is told the same text when it settles.
//
// One-shot, on purpose. A document that another owner watches is not this
// file's business: the reader is released the moment it has an answer, and
// a later observer of the same path joins the settled observation rather
// than reading again. The last observer leaving releases a read that never
// settled, so a shell with no consumer holds no reader and no watch.
//
// Lifecycle per path:
//   observe(owner, path) -> handle (read-only `text` + `decided`)
//   release(handle)      -> drop one observation; the last one destroys
//                           the reader, pending or already settled
// The returned handle is the reference the count is keyed on, so two
// consumers of one document never share a count. The owner string is the
// consumer's own name and is carried for diagnostics only; it is not an
// identity, so a reload that mints the same name again cannot inherit or
// strand an observation.
//
// `adopted(path, text)` is emitted once per read, to every consumer in the
// shell: a consumer that is watching for a document's first content acts
// on it there, and a consumer that arrived after the read settled sees the
// same text on its handle.
Singleton {
  id: root

  readonly property string tag: "documentAdoption"

  // Aggregate revision: bumped whenever a tracked document settles, and
  // when an observation is added or dropped. Per-path consumers follow
  // their own handle's revision instead; this is for a caller that wants to
  // know something moved.
  property int rev: 0

  // path -> { path, reader, text, decided, revision, handles: [] }
  // The map is replaced wholesale on every mutation so a reader that
  // captured it re-reads instead of holding a stale entry object.
  property var _entries: ({})

  // A read that failed is an EMPTY document, never a stale one: the reader
  // still holds the text it read last time on a path that has since
  // vanished, and only completed content is content. Exposed as a pure
  // function so the rule can be exercised without a filesystem.
  function answer(ok, text): string {
    if (ok !== true) return ""
    if (typeof text !== "string") return ""
    return text
  }

  // The single read of a path, answered once and published to every
  // observer of it. `reader` is cleared before anyone is told, so an
  // observer that releases itself from inside its `adopted` handler cannot
  // make this destroy the same reader twice.
  function _settle(path, ok) {
    const entry = root._entries[path]
    if (entry === undefined) return
    const reader = entry.reader
    let text = ""
    try {
      text = root.answer(ok, reader !== null && reader !== undefined ? reader.text() : null)
    } catch (ignored) {
      text = ""
    }
    root._publish(path, Object.assign({}, entry, {
      reader: null,
      text: text,
      decided: true,
      revision: entry.revision + 1
    }))
    // One-shot: the reader exists to answer the question, so it goes as
    // soon as it has. Whatever watches this document from here on is
    // another owner's own view, not a second reader of ours.
    if (reader !== null && reader !== undefined) reader.destroy()
    root.rev++
    root.adopted(path, text)
  }

  // Create the shared reader for a path if it does not exist yet. The
  // handles list is the reference count, so an observer that arrives after
  // the read settled joins the settled observation instead of reading the
  // document again.
  function _ensureEntry(path) {
    const existing = root._entries[path]
    if (existing !== undefined) return existing
    const reader = readerComp.createObject(root, { docPath: path })
    if (reader === null || reader === undefined) return undefined
    root._store(path, {
      path: path,
      reader: reader,
      text: "",
      decided: false,
      revision: 0,
      handles: []
    })
    // path goes on last: setting it is what starts the read. A reader that
    // answers on the spot settles inside this call, and _ensureEntry hands
    // back the settled entry rather than the one it stored.
    reader.path = path
    return root._entries[path]
  }

  // Register an observation of `path` and return its handle, or null when
  // the arguments do not answer the contract. Every call is its own
  // observation: the owner string is the consumer's name for diagnostics,
  // the handle is the identity the reference count is keyed on.
  //
  // The handle is created with a null parent on purpose. Parented to the
  // singleton it would outlive its own release - a consumer that opened and
  // closed a hundred times would leave a hundred observation objects
  // behind, since nothing but the entry's list ever referenced them.
  // Unparented, the handle lives exactly as long as the entry's list and
  // the consumer's own reference do.
  function observe(owner, path) {
    if (typeof owner !== "string" || owner === "") return null
    if (typeof path !== "string" || path === "") return null
    if (root._ensureEntry(path) === undefined) return null
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
    // Re-read the entry: a read that answered before the handle existed is
    // already the settled one, and publishing from the entry captured
    // before that would claim the document was still unread.
    const entry = root._entries[path]
    if (entry === undefined) return null
    root._publish(path, Object.assign({}, entry, {
      handles: entry.handles.concat([handle])
    }))
    return handle
  }

  // Drop one observation. Answers whether an observation was actually
  // dropped, so a teardown can assert it: an unknown handle, a handle
  // released twice and a non-handle all answer false. The last observer
  // leaving destroys the reader - including one whose read is still
  // pending, whose answer nobody is left to hear.
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
    const reader = entry.reader
    if (reader !== null && reader !== undefined) reader.destroy()
    const next = Object.assign({}, root._entries)
    delete next[path]
    root._entries = next
    root.rev++
    return true
  }

  // Per-path view of what is actually held: the reader's existence, the
  // live observer count, and whether the read has settled. This is what
  // "one read, many observers" is checked against - a consumer count that
  // grows while the reader stays at one and then goes to zero is the whole
  // point.
  function diagnostics() {
    const out = {}
    for (const path in root._entries) {
      const entry = root._entries[path]
      if (entry === undefined) continue
      out[path] = {
        readers: entry.reader !== null && entry.reader !== undefined ? 1 : 0,
        observers: entry.handles.length,
        decided: entry.decided,
        revision: entry.revision
      }
    }
    return out
  }

  // Publish an entry: hand every observer the answer as a fresh state
  // object, then swap the map so a reader that captured the old map
  // re-reads. The fresh object is what re-evaluates the handle's read-only
  // views without exposing them to an external write.
  function _publish(path, entry) {
    const handles = entry.handles
    for (let i = 0; i < handles.length; i++) {
      const handle = handles[i]
      if (handle === null || handle === undefined) continue
      handle.trackState = {
        text: entry.text,
        decided: entry.decided,
        revision: entry.revision
      }
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

  // The single reader per path. A loaded and a failed read are only "the
  // answer is in" - the answer itself is settled by _settle, so a document
  // that cannot be read settles as empty rather than standing on whatever
  // the reader happened to cache. It is not a watcher: watching a document
  // is the job of whoever owns it, and a watcher here would be a second
  // reader of the same file.
  signal adopted(string path, string text)

  Component {
    id: readerComp

    FileView {
      property string docPath: ""

      printErrors: false
      onLoaded: root._settle(docPath, true)
      onLoadFailed: root._settle(docPath, false)
    }
  }

  // One observation. The read-only views are derived from a state object
  // the tracker replaces, so a binding on `text` or `decided` re-evaluates
  // when the read answers and no consumer can write the answer.
  Component {
    id: handleComp

    QtObject {
      id: observation

      property string trackOwner: ""
      property string trackPath: ""
      property var trackState: ({ text: "", decided: false, revision: 0 })

      readonly property string owner: observation.trackOwner
      readonly property string path: observation.trackPath
      readonly property string text: observation.trackState.text
      readonly property bool decided: observation.trackState.decided
      readonly property int revision: observation.trackState.revision
    }
  }
}
