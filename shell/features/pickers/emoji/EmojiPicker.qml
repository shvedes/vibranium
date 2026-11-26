pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
// qmllint disable unqualified
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import qs.features.menu
import "../../../common/text/IpcCatalog.js" as Catalog
import "../../menu/MenuLib.js" as MenuLib

// Emoji picker service. The entry page lists the face emojis only; the rest
// of the set sits on the companion bundle and is reachable through search.
// The lazy bundle is registered at boot but NOT parsed: `copy` loads the
// two shipped catalogs on first use, and `help`/`status` never do.
Singleton {
  id: root

  readonly property string tag: "emojiPicker"
  readonly property string bundlePath: Paths.vibraniumHome + "/shell/features/pickers/emoji/emojis.jsonc"
  readonly property string companionPath: Paths.vibraniumHome + "/shell/features/pickers/emoji/emojis-all.jsonc"
  property var _catalog: null
  property bool _catalogReady: false
  property bool _ipcRegistered: false

  // Parked readers: a path set once at construction finishes loading before
  // the first copy, and waitForJob() then reports no live job. Re-setting the
  // path on each read is what makes the synchronous barrier meaningful.
  FileView { id: entryFile; printErrors: false }
  FileView { id: companionFile; printErrors: false }

  Component.onCompleted: {
    Registry.offer("emojiPicker", {
      title: "Emoji picker",
      description: "Search for and copy emoji",
      verbNames: Catalog.topLevelVerbs("emojiPicker")
    })
    // The menu reads this at its late idle prewarm, so boot order does not
    // matter: the bundle path belongs to the picker that owns the data.
    Registry.register("lazySearchBundles", { paths: [root.bundlePath] })
    root._ipcRegistered = IpcRouter.register("emojiPicker", root, {
      "emojiPicker.open": function () { return root._ipcOpen() },
      "emojiPicker.close": function () { return root._ipcClose() },
      "emojiPicker.toggle": function () { return root._ipcToggle() },
      "emojiPicker.copy": function (args) { return root._ipcCopy(args.ID) },
      "emojiPicker.status": function () { return root.ipcStatus() },
      "emojiPicker.ping": function () { return root._ok("pong") }
    })
  }

  Component.onDestruction: {
    IpcRouter.unregister("emojiPicker", root)
  }

  function _ok(data, format) {
    const frame = { v: 1, ok: true }
    if (data !== undefined) frame.data = data
    if (format) frame.format = format
    return frame
  }

  function fail(code, message) {
    return { v: 1, ok: false, error: { code: code, message: String(message || code) } }
  }

  // One parse of both shipped catalogs, on first `copy` only. Entries and
  // companion share one glyph-indexed table so source order breaks ties.
  function _ensureCatalog() {
    if (root._catalog !== null) return root._catalog
    const entries = []
    const byGlyph = Object.create(null)
    const files = [entryFile, companionFile]
    const paths = [root.bundlePath, root.companionPath]
    for (let f = 0; f < files.length; f++) {
      const file = files[f]
      file.path = ""
      file.path = paths[f]
      if (!file.waitForJob()) continue
      let parsed = null
      try {
        parsed = JSON.parse(MenuLib.stripJsonc(String(file.text() === undefined ? "" : file.text())))
      } catch (e) {
        continue
      }
      const pages = parsed && Array.isArray(parsed.pages) ? parsed.pages : []
      for (let p = 0; p < pages.length; p++) {
        const items = pages[p] && Array.isArray(pages[p].items) ? pages[p].items : []
        for (let i = 0; i < items.length; i++) {
          const item = items[i]
          if (!item || typeof item !== "object") continue
          const glyph = typeof item.glyph === "string" ? item.glyph : ""
          if (glyph === "" || byGlyph[glyph]) continue
          byGlyph[glyph] = true
          const label = String(item.label || "")
          const hay = label.toLowerCase()
          entries.push({ glyph: glyph, label: label, hay: hay, words: hay.split(/\s+/) })
        }
      }
    }
    root._catalog = { entries: entries, byGlyph: byGlyph }
    root._catalogReady = entries.length > 0
    return root._catalog
  }

  // Exact glyph, then U+ code points, then exact normalized label/token,
  // then the menu's own fuzzy score. Never loads a catalog for help/status.
  function _resolve(id) {
    const cat = root._ensureCatalog()
    const text = String(id === undefined || id === null ? "" : id)
    if (text === "") return null
    if (cat.byGlyph[text]) return text
    if (text.indexOf("U+") === 0) {
      const parts = text.split(/\s+/)
      let glyph = ""
      for (let i = 0; i < parts.length; i++) {
        if (!/^U\+[0-9A-Fa-f]+$/.test(parts[i])) return null
        const cp = parseInt(parts[i].slice(2), 16)
        if (!isFinite(cp) || cp < 0 || cp > 0x10ffff || (cp >= 0xd800 && cp <= 0xdfff)) return null
        glyph += String.fromCodePoint(cp)
      }
      return cat.byGlyph[glyph] ? glyph : null
    }
    const q = text.toLowerCase()
    for (let i = 0; i < cat.entries.length; i++) {
      const e = cat.entries[i]
      if (e.hay === q || e.words.indexOf(q) >= 0) return e.glyph
    }
    let best = null
    let bestScore = -1
    for (let j = 0; j < cat.entries.length; j++) {
      const candidate = cat.entries[j]
      const score = MenuLib.fuzzyScore(candidate.hay, candidate.words, q)
      if (score > bestScore) {
        bestScore = score
        best = candidate.glyph
      }
    }
    return bestScore >= 0 ? best : null
  }

  // Success is RC-only: the frame carries the state for JSON readers but
  // renders as no text output.
  function _openState() {
    return _ok({ open: Menu.isBundleOpen(root.bundlePath) }, { kind: "none" })
  }

  function _ipcOpen() {
    if (!Menu.isBundleOpen(root.bundlePath)) Menu.openFile(root.bundlePath)
    return _openState()
  }

  function _ipcClose() {
    if (Menu.isBundleOpen(root.bundlePath)) Menu.close()
    return _openState()
  }

  function _ipcToggle() {
    if (Menu.isBundleOpen(root.bundlePath)) Menu.close()
    else Menu.openFile(root.bundlePath)
    return _openState()
  }

  function _ipcCopy(id) {
    const glyph = root._resolve(id)
    if (glyph === null) return root.fail("not-found", "no such emoji")
    const verdict = Registry.call("clipboard", "writePublicText", glyph)
    if (!verdict)
      return root.fail("unavailable", "clipboard service is unavailable")
    if (verdict.ok !== true) return verdict
    return _ok({ glyph: glyph, state: "accepted" }, { kind: "none" })
  }

  function ipcStatus() {
    return _ok({
      open: Menu.isBundleOpen(root.bundlePath),
      catalogReady: root._catalogReady
    }, { kind: "record" })
  }
}
