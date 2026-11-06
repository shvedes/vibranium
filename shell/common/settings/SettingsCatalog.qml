pragma Singleton
pragma ComponentBehavior: Bound

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "SettingsLib.js" as SL

// One read and one parse of the unified settings catalog for every store that
// projects a group out of it.
//
// Settings, HyprlandSettings and MiscSettings each used to own a FileView onto
// the same catalog.jsonc and each called waitForJob() + parseUnifiedCatalog on
// it while the floor was still constructing: three blocking reads and three
// parses of ~5k lines before the first frame, of the same bytes. Both are
// memoized here, so the first store to ask pays for them and the other two get
// the same object.
//
// Synchronous on purpose. The three stores are floor units with a
// deterministic construction order, and this keeps that order intact instead
// of making them wait on a signal they would each have to re-enter.
Singleton {
  readonly property string tag: "settingsCatalog"

  // Parsed catalog: { sections, rootWidth, rootTitle }. null until load()
  // succeeds, and stays null after a failure so a later store does not retry a
  // file that is already known bad.
  property var catalog: null
  property bool ready: false
  // Why the catalog is unavailable, with no store prefix: the caller logs it
  // under its own name. Empty while it is simply unasked.
  property string error: ""
  // True when the last attempt failed only because the catalog path could
  // not be resolved yet; such a failure is not latched.
  property bool _pathPending: false

  FileView {
    id: catalogFile
    printErrors: false
  }

  // Read and parse once. Returns the catalog, or null with `error` set.
  function load() {
    if (catalog !== null) return catalog
    // An unresolved VIBRANIUM home (a session that starts the shell without
    // the env file) makes the path relative to "/", and a read that fails
    // there would latch a "could not be read" verdict about a file nobody
    // looked for. Report the real reason and stay retryable: a later call
    // re-resolves the path instead of replaying a stale failure.
    if (_pathPending) {
      _pathPending = false
      error = ""
    }
    if (error !== "") return catalog
    if (!Paths.vibraniumHome) {
      _pathPending = true
      error = "the catalog path is unresolved (VIBRANIUM is unset)"
      return null
    }
    catalogFile.path = ""
    catalogFile.path = Paths.settingsCatalogPath
    if (!catalogFile.waitForJob()) {
      error = "the catalog could not be read: " + Paths.settingsCatalogPath
      return null
    }
    let parsed = null
    try {
      parsed = SL.parseUnifiedCatalog(catalogFile.text())
    } catch (err) {
      error = "the catalog did not parse: "
        + (err && err.message ? err.message : String(err))
      return null
    }
    if (!parsed) {
      error = "the catalog did not parse: empty catalog"
      return null
    }
    catalog = parsed
    ready = true
    return catalog
  }
}
