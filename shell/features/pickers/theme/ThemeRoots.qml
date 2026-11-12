pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Io
import Qt.labs.folderlistmodel
import qs.common
import qs.features.menu

// The two theme roots as one listing pair: $VIBRANIUM/themes and the user
// themes root, their FileView watchers, and the settle/re-arm policy that
// both theme pages need before they can scan.
//
// The picker and the remover had a byte-for-byte copy of this block. The
// policy is subtle in one place - a FolderListModel aimed at a missing root
// resolves to the working directory and reports Ready with foreign rows
// before settling to Null - so a second copy is a second chance to scan the
// wrong directory. It lives here once.
//
// The listings are armed at the first real need, never at construction: a
// session that never opens a theme page reads no directory and no theme file.
// `ready` fires whenever both listings are settled and usable, so a page can
// rescan; `changed` fires after a debounced add/remove, so a page can drop its
// cache and rescans once per burst.
Item {
  id: root

  // Whether the menu is showing the remover's page right now. The remover
  // asks this before closing, rescanning or reopening; the check stays here
  // beside the listings both theme surfaces share.
  function isPageOpen(pageId) {
    return Menu.open && Menu.frame !== null && Menu.frame !== undefined
      && Menu.frame.id === pageId
  }

  readonly property string officialRoot: Paths.vibraniumHome + "/themes"
  readonly property string userRoot: Paths.themesUserRoot

  // Assigned-folder latch and the listed-and-scannable verdict. An unset
  // folder is not an empty folder, so `listed` is the discriminator every
  // scan and model read sits behind.
  property bool armed: false
  property bool _listed: false
  readonly property bool listed: root._listed

  signal ready()
  signal changed()

  readonly property alias officialModel: officialModel
  readonly property alias userModel: userModel

  FolderListModel {
    id: officialModel

    showDirs: true
    showDotAndDotDot: false
    showFiles: false
    sortField: FolderListModel.Name
    onCountChanged: root._onDirCountChanged()
    onStatusChanged: root._onListingReady()
  }

  FolderListModel {
    id: userModel

    showDirs: true
    showDotAndDotDot: false
    showFiles: false
    sortField: FolderListModel.Name
    onCountChanged: root._onDirCountChanged()
    onStatusChanged: root._onListingReady()
  }

  // Inotify fallback for added/removed theme dirs. A FileView pointed at a
  // directory emits fileChanged when entries come and go, and one pointed at
  // a missing path emits it when that path is created, so every add, remove
  // and created-root funnels into the same debounced rescan even when the
  // models' own count signals miss it (a model aimed at a missing root
  // settles to Null and never emits again on its own).
  FileView {
    id: officialDirWatch

    path: root.officialRoot
    watchChanges: true
    printErrors: false
    onFileChanged: root._onDirChanged()
  }

  FileView {
    id: userDirWatch

    path: root.userRoot
    watchChanges: true
    printErrors: false
    onFileChanged: root._onDirChanged()
  }

  // Assigning the folder is the only thing that starts a directory scan, so
  // this is the one place it happens. Both are assigned together because
  // every scan needs both listings Ready; arming one alone would scan a
  // directory whose pair can never complete.
  function arm() {
    if (root.armed) return
    root.armed = true
    officialModel.folder = "file://" + root.officialRoot
    userModel.folder = "file://" + root.userRoot
  }

  // Directory-count debounce, named: one rescan per burst of add/remove
  // events.
  readonly property int dirDebounceMs: 250

  Timer {
    id: dirDebounce

    interval: root.dirDebounceMs
    repeat: false
    onTriggered: root.changed()
  }

  function _onDirCountChanged() {
    // A count that lands while the listing is still being armed is the
    // first population, not a directory change: the scan it would schedule
    // is the one the first real need already asked for. Count events only
    // ever come from a live model, so unlike the dir watchers below this
    // never re-arms: re-aiming here would chase the working-directory
    // flash a resolving model reports before settling.
    if (!root._listed) return
    dirDebounce.restart()
  }

  // The FileView dir watchers land here. External changes are the one thing
  // that can leave a model behind (a root created after the arming sits at
  // Null, dead to further model events), so the models are re-aimed first
  // and the listing-ready handler picks up the settle.
  function _onDirChanged() {
    if (!root.armed) return
    root.rearmUnready()
    root._onListingReady()
    if (!root._listed) return
    dirDebounce.restart()
  }

  // Whether a listing model freshly lists its root: Ready with rows under
  // it, or Ready and empty. Anything else - still loading, settled to Null
  // on a missing root, or Ready with the working directory's rows (the
  // flash a missing root reports before settling to Null) - needs a re-aim
  // before it can be scanned.
  function modelFresh(m, rootPath) {
    if (m.status !== FolderListModel.Ready) return false
    if (m.count === 0) return true
    const p = String(m.get(0, "filePath"))
    return p.lastIndexOf(rootPath + "/", 0) === 0
  }

  // Whether the pair can be scanned: fresh, or settled to Null on a missing
  // root, which reads as empty (a missing dir contributes no rows). The
  // flash above never passes: it is Ready with foreign rows.
  function modelsUsable() {
    const ou = officialModel.status === FolderListModel.Null
      || root.modelFresh(officialModel, root.officialRoot)
    const uu = userModel.status === FolderListModel.Null
      || root.modelFresh(userModel, root.userRoot)
    return ou && uu
  }

  // The gate every page's scan passes through: a listing that is not armed
  // is not an empty root, and a model pair that is not usable is re-aimed and
  // held for the settle that follows. False means the page must not scan.
  function beginScan() {
    if (!root.listed) return false
    if (!root.modelsUsable()) {
      root.rearmUnready()
      return false
    }
    return true
  }

  // The page verbs the remover publishes. They are one rule each, so the
  // policy lives beside the page-open test it reads.
  function refreshPage(page) {
    if (!root.listed) return "error"
    page._cached = null
    page._doScan(root.isPageOpen(page.pageId))
    return "ok"
  }

  function closePage(page) {
    if (root.isPageOpen(page.pageId)) Menu.close()
    return "ok"
  }

  function togglePage(page, open) {
    if (root.isPageOpen(page.pageId)) {
      Menu.close()
      return "ok"
    }
    if (Menu.open) Menu.close()
    return open()
  }

  // A themes root that does not exist yet settles its model to Null. Null is
  // terminal - the model will not recover on its own - so it counts as
  // settled and reads as empty while the official themes still list. Only
  // Loading is still in flight.
  function isSettled(m) {
    return m.status !== FolderListModel.Loading
  }

  // Re-aim every model that does not freshly list its root: still loading,
  // settled to Null on a directory that did not exist when it was armed
  // (a themes root created later is picked up), or Ready with foreign rows
  // (the working-directory flash a missing root reports before settling).
  // Reassigning the same URL is a no-op, so the folder is blanked first on a
  // later turn. `_listed` drops while the re-aim is in flight, so the
  // transient listing the blank folder resolves to is never scanned. Only
  // ever called from a page's open() and the dir-watcher handler, never from
  // the listing-ready handler and never from a count event, so a flash can
  // never retrigger its own re-aim in a loop.
  function rearmUnready() {
    if (!root.armed) return false
    let rearmed = false
    const jobs = [
      [officialModel, "file://" + root.officialRoot, root.officialRoot],
      [userModel, "file://" + root.userRoot, root.userRoot]
    ]
    for (let i = 0; i < jobs.length; i++) {
      const m = jobs[i][0]
      if (root.modelFresh(m, jobs[i][2])) continue
      m.folder = ""
      const url = jobs[i][1]
      Qt.callLater(() => { m.folder = url })
      rearmed = true
    }
    if (rearmed) root._listed = false
    return rearmed
  }

  // One listing landing is the only event that can finish a pending show or
  // refresh a live cache, so both status handlers route here. Both listings
  // are required: a half-armed pair is not a listing, and the scan waits for
  // the second one.
  function _onListingReady() {
    if (!root.armed) return
    if (!root.isSettled(officialModel) || !root.isSettled(userModel)) return
    // Never latch or scan the working-directory flash: a model aimed at a
    // missing root reports Ready with foreign rows before settling to Null.
    // Dropping `_listed` keeps the debounced scan and any pending show gated
    // until the settle that follows re-invokes this handler.
    if (!root.modelsUsable()) {
      root._listed = false
      return
    }
    root._listed = true
    root.ready()
  }
}
