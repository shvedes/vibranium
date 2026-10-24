pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import qs.features.menu
import "../../../common/text/UnitIpc.js" as UnitIpc

// Font picker service. Ports font discovery into the shell: fc-list
// enumeration (monospace only, the same filter vb-font-set applies),
// one row per family, pick -> vb-font-set <family> <style> through the
// Registry hub (no shell spawn).
//
// The page is injected as a DYNAMIC page (Menu.injectPage), so it never
// joins the bundle - but its rows are still registered for global search
// under the page id, which is what makes a family name typed anywhere in
// Settings jump straight to that row. Within the page the menu's own '/'
// scoped filter trims the visible rows instead.
//
// Memory: the scan runs once per session on first open (fc-list child,
// output collected, process destroyed); the cache is a flat JS array of
// {family, style, label} rows handed to the page composer by reference.
// No FolderListModel, no warm timers - fonts rarely change mid-session
// and IPC refresh re-runs the scan on demand.
Singleton {
  id: root

  readonly property string tag: "fontPicker"
  readonly property string pageId: "font-picker"

  // Flat cache: [{family, style, label}] sorted by family, Regular first
  // within a family. null = never scanned.
  property var _cached: null
  property bool _scanRunning: false
  property var _pendingShow: null   // false = refresh silently, "open" = show when done
  // A scan that exited non-zero. Terminal: the arm stops retrying so a
  // missing fc-list does not leave a 400ms timer running for the session,
  // and a later refresh() clears it to try again on purpose.
  property bool _scanFailed: false
  // Lowercased US-separated "family style base" per row, built once per scan. claimsQuery
  // runs on EVERY keystroke through Menu.setQuery, and deriving it there cost
  // three toLowerCase() allocations per font per keypress; the needle is the
  // only thing that needs lowercasing now. null = never scanned.
  property var _hay: null

  // Current default from vb-font-get ("Family Style"), "" when unknown.
  property string _current: ""

  // Landing generation: bumped by open()/close() so a deferred Qt.callLater
  // landing from a superseded open (closed menu, another picker summoned)
  // can never push the font page over newer UI.
  property int _landingGen: 0

  Component.onCompleted: {
    Registry.offer("fontPicker", {
      title: "Font picker",
      description: "system font selection",
      verbNames: [
        "close",
        "open",
        "refresh",
        "set",
        "toggle",
        "status",
        "help",
        "ping",
      ]
    })
    // Registry.call routes runCall specs ("fontPicker pick %v") here;
    // offer() alone only feeds the IPC manifest.
    Registry.register("fontPicker", root)
    // A query naming a font family has to be able to reach these rows even
    // though the user never opened the page.
    // Registered as a lazy index provider, not a token list: a family name is
    // arbitrary text, so no fixed set of words can predict it (see
    // Menu._indexProviderFor). claimsQuery decides, from the real values.
    Menu.provideIndexFor(root)
    // Arm the scan now. The rows are indexed for global search, so they have
    // to exist before anyone can type a family name: gating the scan on
    // open() meant a fresh shell had no font rows in the index at all, and
    // searching one reported "No matches" until the picker happened to be
    // opened once. _armScan defers past construction and waits for Menu.
    root._armScan()
  }

  // --- one-shot scan process (created per run, destroyed after) ---

  Component {
    id: scanProcComp

    Process {
      // var, not bool: callers pass "open" (show when done), true (live
      // refresh) or false (silent). A bool would coerce "open" to true and
      // demote the first summon to a refresh that no-ops on a closed menu.
      property var wantShow: false

      stdout: StdioCollector {
        waitForEnd: true
      }
      stderr: StdioCollector {}

      onExited: (code, status) => {
        root._scanRunning = false
        const show = wantShow
        if (code !== 0) {
          // A failed scan must not leave a stale index registration behind,
          // or the font names stay searchable and land on an empty page.
          // Withdrawing is the honest state: the rows are not known. The
          // flag is terminal so the arm stops retrying a missing fc-list;
          // refresh() clears it.
          if (root._cached === null) root._withdraw()
          root._scanFailed = true
          root._pendingShow = null
          // Clear the waiters without answering them: a query held for these
          // rows must not stay pinned, and the field's own state is the
          // empty answer, which is what it already shows.
          root._scanWaiters = []
          destroy()
          return
        }
        root._scanFailed = false
        root._applyScan(stdout.text, show)
        // After _applyScan, so the page is composed and the index rows are
        // registered before any waiter recomputes a query against them.
        root._notifyScanned()
        destroy()
      }
    }
  }

  function _applyScan(text, show) {
    // Monospace faces only (spacing 100 mono / 90 dual - the system font
    // doubles as the terminal + bar font), US-separated fields (a family
    // name may itself contain a pipe), first element of the comma-separated
    // family/style lists (one file can carry several names), emoji and
    // symbol fonts dropped.
    const seen = {}
    const rows = []
    const lines = String(text || "").split("\n")
    for (let i = 0; i < lines.length; i++) {
      const parts = lines[i].split("\x1f")
      if (parts.length < 3 || parts[0].trim() === "") continue
      const spacing = parseInt(parts[2].trim(), 10)
      if (spacing !== 100 && spacing !== 90) continue
      let fam = parts[0].split(",")[0].trim()
      let sty = parts[1].split(",")[0].trim()
      if (fam === "") continue
      if (/emoji|signwriting|symbols/i.test(fam)) continue
      if (sty === "") sty = "Regular"
      const key = fam + "\x1f" + sty
      if (seen[key]) continue
      seen[key] = true
      rows.push({ family: fam, style: sty })
    }
    root._collapseRows(rows, show)
  }

  // Patched-variant grouping: "Foo NF" / "Foo PL" / "Foo NL" / "Foo PS"
  // collapse under the base name with the variant badged in the subtext,
  // so the list reads as fonts rather than patch builds. Plain and
  // patched rows stay separately installable (identity keeps the real
  // family).
  function _baseTag(family) {
    const m = String(family).match(/^(.*) (NF|PL|NL|PS)$/)
    if (!m) return { base: String(family), tag: "" }
    return { base: m[1], tag: m[2] }
  }

  // What the patch-build acronyms stand for. Unknown tags fall back to
  // themselves so a future suffix still renders something honest.
  function _tagLabel(tag) {
    if (tag === "NF") return "Nerd Font"
    if (tag === "PL") return "Powerline"
    if (tag === "NL") return "No Ligatures"
    if (tag === "PS") return "PostScript"
    return String(tag)
  }

  function _fullIdentity(family, style) {
    // Mirrors vb-font-get's echo shape ("Family [Style] size" minus the
    // size, Regular omitted) so _current matches rows directly.
    return style === "Regular" ? String(family) : String(family) + " " + String(style)
  }

  // One row per (base, variant): Regular face preferred within each group,
  // plain bases sort before their patched twins.
  function _collapseRows(rows, show) {
    const byKey = {}
    for (let r = 0; r < rows.length; r++) {
      const bt = root._baseTag(rows[r].family)
      const key = bt.base + "\x1f" + bt.tag
      const cur = byKey[key]
      if (cur === undefined) {
        byKey[key] = { family: rows[r].family, base: bt.base, tag: bt.tag, style: rows[r].style }
        continue
      }
      if (cur.style !== "Regular" && rows[r].style === "Regular") {
        cur.family = rows[r].family
        cur.style = rows[r].style
      }
    }
    const out = []
    for (const k in byKey) out.push(byKey[k])
    out.sort((a, b) => a.base.localeCompare(b.base) || a.tag.localeCompare(b.tag))
    root._cached = out
    root._hay = out.map(r => [r.family, r.style, r.base]
      .filter(v => typeof v === "string" && v !== "")
      .join("\x1f").toLowerCase())
    // Consume whichever request(s) arrived while the scan ran: an open
    // request (first summon or IPC) lands the page, a live refresh only
    // recomposes an already-open page.
    const wantOpen = show === "open" || root._pendingShow === "open"
    const wantLive = show === true || root._pendingShow === true
    root._pendingShow = null
    // Auto-open only when the menu is closed or already showing a page the
    // font landing owns (font page or its settings host): a scan finishing
    // while the user browses themes must not yank them into settings.
    const fontOwned = !Menu.open
      || (Menu.frame && (Menu.frame.id === root.pageId
        || (root._isSettingsFrame(Menu.frame.id))))
    if (wantOpen && fontOwned) root.open()
    else if (wantLive && Menu.open && Menu.frame && Menu.frame.id === root.pageId) root._compose()
    // A silent scan (the boot one) still has to publish its rows: the page
    // composition is what registers the index entries, so skipping it here
    // would leave the scan cached but unindexed, which is the same
    // "No matches" the boot scan was added to fix. _compose injects the page
    // without pushing a frame, so no navigation happens.
    else root._compose()
  }

  // True when the id belongs to the settings bundle family the font page
  // lands on (the entry page or any settings subpage).
  function _isSettingsFrame(id) {
    if (!Menu.bundle) return false
    if (Menu.bundle.byId[id] !== undefined) return true
    return id === Menu.bundle.entry
  }

  function _scan(show) {
    if (root._scanRunning) {
      // Concurrent requests: the strongest wins and is never clobbered by
      // a weaker one ("open" > live refresh > silent).
      if (show === "open") root._pendingShow = "open"
      else if (root._pendingShow !== "open" && show === true) root._pendingShow = true
      return
    }
    root._scanRunning = true
    const proc = scanProcComp.createObject(root, {
      wantShow: show === undefined ? false : show,
      command: ["fc-list", "-f", "%{family}\x1f%{style}\x1f%{spacing}\\n"]
    })
    proc.running = true
  }

  // Invalidates the cache and rescans (IPC `refresh`); silent unless the
  // page is open, which recomposes live. A closed menu still wants the
  // re-index, so the scan is requested whenever the cache was the only
  // thing holding the rows - the silent path recomposes and re-registers.
  function refresh() {
    root._cached = null
    root._hay = null
    root._scanFailed = false
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) root._scan(true)
    else root._armScan()
    return "ok"
  }

  // Arm the one session scan. Deferred to the first event-loop turn so it
  // never runs inside the singleton's construction: _applyScan composes a
  // page and injectPage rebuilds the search index, and doing that while the
  // type is still being created re-enters the menu framework underneath its
  // own instantiation. Boot orders the menu before this picker, so one
  // deferred attempt is enough - there is no retry timer.
  function _armScan() {
    Qt.callLater(root._armAttempt)
  }

  function _armAttempt() {
    if (root._cached !== null || root._scanRunning || root._scanFailed) return
    // Menu has to be constructed before injectPage can register anything.
    if (typeof Menu === "undefined" || !Menu || !Menu.openFile) return
    root._scan(false)
  }

  // Does this query name one of my fonts? Menu asks every provider that is
  // not ready yet, and defers the query for the ones that say yes.
  //
  // Two states, because the answer is only ever a guess before the scan:
  //
  // - Scanned: the real rows are here, so this is a plain case-insensitive
  //   test for the query as a substring of a family or style. "jetbrains"
  //   matches "JetBrains Mono NL" and "JetBrains Mono" and nothing else, so
  //   a query that names no installed font is NOT deferred - it answers
  //   immediately instead of waiting on a scan that cannot help.
  // - Not scanned: nothing to match against, so the guess is "maybe" for
  //   anything that could be a family name and a firm "no" for a single
  //   character, which cannot be one. Deferring the first keystroke of any
  //   search would fork fc-list for a query nobody means that way.
  //
  // Length is the only discriminator, never a word list: a family name is
  // arbitrary user text, so "jetbrains" matches no token table and such a
  // table would report "No matches" for a font the machine has (see
  // Menu._indexProviderFor). The residual is a two-character query on a
  // session whose scan has not landed - it still defers, which is the
  // cheaper error next to hiding an installed family.
  function claimsQuery(q) {
    const needle = String(q || "").trim().toLowerCase()
    if (needle === "") return false
    if (root._hay === null) return needle.length > 1
    for (let i = 0; i < root._hay.length; i++) {
      if (root._hay[i].indexOf(needle) >= 0) return true
    }
    return false
  }

  // Subscribers waiting for the rows to land, so a query Menu held back can
  // be recomputed against a finished index. A flat list of callbacks, fired
  // once each and cleared: a subscriber that wants to hear about the NEXT
  // scan registers again. A failed scan does not fire - there is nothing to
  // search - but the list is cleared either way, so a caller is never left
  // holding a callback that will never run.
  property var _scanWaiters: []

  function whenScanned(cb) {
    if (typeof cb !== "function") return false
    if (root._cached !== null) {
      // Already done: answer on the next turn, so a caller's ordering does
      // not depend on whether it subscribed before or after the scan.
      Qt.callLater(cb)
      return true
    }
    const next = root._scanWaiters.slice()
    next.push(cb)
    root._scanWaiters = next
    return true
  }

  function _notifyScanned() {
    if (root._scanWaiters.length === 0) return
    const waiting = root._scanWaiters
    root._scanWaiters = []
    for (let i = 0; i < waiting.length; i++) waiting[i]()
  }

  // Menu calls this when a container reload has dropped the page this owner
  // published. The rows are still cached, so the scan is NOT re-run: the
  // page is simply recomposed, which re-injects it and re-registers the
  // index entries. Without this a boot-time scan is unsearchable from the
  // first bundle open onward, and because the cache is warm nothing else
  // ever asks for the rows again.
  function republishIndex() {
    if (root._cached === null) return
    if (Menu.hasDynamicPage(root.pageId)) return
    root._compose()
  }

  // The arm above fires once past construction; no retry timer (Boot
  // orders the menu before this picker).

  // True once the rows are in the index, which is what Menu asks before it
  // holds a query back. The page composition registers them, so "cached" and
  // "indexed" are the same condition here.
  //
  // A FUNCTION, not a property: Menu holds a plain object as the provider, so
  // a QML property would arrive as an opaque QObject that answers nothing -
  // `owner.indexReady()` on a bool is not a call, and it threw instead of
  // deferring. The call shape is the contract; see Menu._indexProviderFor.
  function indexReady() {
    return root._hay !== null
  }

  // Menu calls this when a query names fonts and nothing is indexed yet.
  // Returns true when it took the scan on, so Menu knows to re-run the
  // held query once the rows land; false when the rows are already there or
  // a scan is in flight, and the caller should just search.
  function ensureScanned() {
    if (root._hay !== null) return false
    if (root._scanRunning) return true
    root._armScan()
    return true
  }

  // Drop the rows from the global index without touching the page. Used when
  // a scan fails, so a search hit can never point at a page whose contents
  // are unknown.
  function _withdraw() {
    Menu.unindexExternal(root.pageId)
  }

  // --- page composition ---

  function _compose() {
    // No injection into standalone picker bundles (themes): a scan landing
    // while one is open would register foreign rows into its search. The
    // rows stay cached; the next settings-bundle load replays them.
    if (!Menu.externalPagesAllowed()) return
    const rows = root._cached || []
    const items = []

    if (rows.length === 0) {
      items.push({
        type: "action",
        id: "font-none",
        label: "No monospace fonts found",
        sub: "Install fonts system-wide, then run: qs ipc call fontPicker refresh",
        icon: "font",
        command: "",
        selectable: false
      })
    }

    for (let i = 0; i < rows.length; i++) {
      const r = rows[i]
      // Active row trails an accent "• active" in the subtext: dynamic
      // pages never pass through buildGuardScript (bundle pages only), so
      // bash `checked` marks cannot work here - the flag recomposes when
      // the current font read lands instead. Identity compares the real
      // family (variants install separately), while the label shows the
      // collapsed base name.
      const active = root._current !== "" && root._current === root._fullIdentity(r.family, r.style)
      // Every row carries its style, so entries share one height; patched
      // variants lead with a bold expanded tag ("Nerd Font", "Powerline",
      // ...), dot-separated from the style.
      const sub = (r.tag !== "" ? "<b>" + root._tagLabel(r.tag) + "</b> · " : "") + r.style
      items.push({
        type: "action",
        id: "",
        label: r.base,
        previewFontFamily: r.family,
        sub: sub,
        subAccent: active ? "active" : "",
        icon: "font",
        value: r.family + "\u0001" + r.style,
        hideValue: true,
        call: "fontPicker pick %v",
        selectable: true
      })
    }

    // Build through the shared pipeline (Menu.buildDynamicPage ->
    // MenuLib.buildPage) so rows get the uid/hay/selectable contract
    // bundle pages have; raw injects left every uid undefined and
    // collapsed all rows onto one state slot.
    Menu.injectPage(Menu.buildDynamicPage(root.pageId, "Font selection", 360, items))
  }

  // Registry method behind the rows' `call` spec. The value packs
  // family<US>style so quotes/spaces survive the one-arg round trip.
  function pick(packed) {
    const sep = String(packed ?? "").indexOf("\u0001")
    if (sep <= 0) return "error"
    const family = String(packed).substring(0, sep)
    const style = String(packed).substring(sep + 1)
    return root.set(family, style)
  }

  // --- apply ---

  function set(family, style) {
    const fam = String(family ?? "").trim()
    const sty = String(style ?? "").trim() || "Regular"
    if (fam === "") return "error"
    Exec.run([Paths.vibraniumHome + "/bin/vb-font-set", fam, sty])
    // Optimistic active flag; the authoritative value is re-read from
    // vb-font-get on the next open.
    root._current = sty === "Regular" ? fam : fam + " " + sty
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) root._compose()
    return "ok"
  }

  // --- current default (cheap, on open) ---

  Component {
    id: currentProcComp

    Process {
      stdout: StdioCollector {
        waitForEnd: true
      }
      stderr: StdioCollector {}

      onExited: (code, status) => {
        // vb-font-get echoes the pango name incl. size ("Family Style 11").
        // Rows compare against "Family [Style]", so the trailing size is
        // stripped here; a missing binary just leaves _current unchanged.
        const out = String(stdout.text || "").trim().replace(/^'|'$/g, "")
        const m = out.match(/^(.*?)\s+\d+(?:\.\d+)?$/)
        const next = m ? m[1] : out
        const changed = next !== root._current
        root._current = next
        // Late read (fonts page already on screen): recompose so the
        // active row's sub flips without user action.
        if (changed && Menu.open && Menu.frame && Menu.frame.id === root.pageId)
          root._compose()
        destroy()
      }
    }
  }

  function _readCurrent() {
    const proc = currentProcComp.createObject(root, {
      command: [Paths.vibraniumHome + "/bin/vb-font-get"]
    })
    proc.running = true
  }

  // --- open/close (deferred, mirrors the picker flow) ---

  function open() {
    root._landingGen++
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return "ok"
    root._readCurrent()
    if (root._cached === null) {
      // First summon: scan, then show when it lands (_pendingShow path).
      root._scan("open")
      return "ok"
    }
    root._compose()
    const g = root._landingGen
    Qt.callLater(() => {
      // Superseded: a close or a newer open queued after this callback.
      if (g !== root._landingGen) return
      // Re-entrancy guard: a double summon queues two landings; the
      // second must not push a duplicate frame of the same page.
      if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return
      // The font page belongs to the settings bundle: route there when
      // summoned from a standalone picker bundle instead of pushing a
      // settings page onto a foreign stack.
      if (Menu.open && !Menu.externalPagesAllowed()) Menu.close()
      if (!Menu.open) Menu.openFile(Paths.settingsBundlePath)
      if (!Menu.hasDynamicPage(root.pageId)) root._compose()
      Menu.push(root.pageId)
    })
    return "ok"
  }

  function close() {
    root._landingGen++
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) Menu.close()
    return "ok"
  }

  function toggle() {
    if (Menu.open && Menu.frame && Menu.frame.id === root.pageId) return root.close()
    return root.open()
  }

  function status() {
    return JSON.stringify({
      cached: root._cached ? root._cached.length : 0,
      current: root._current,
      open: Menu.open && Menu.frame ? Menu.frame.id : ""
    })
  }

  IpcHandler {
    target: "fontPicker"
    function help(command: string): string {
      return UnitIpc.help("fontPicker", "Font picker", "system font selection", [
        { name: "close", help: "hide the picker" },
        { name: "open", help: "show the picker" },
        { name: "refresh", help: "rescan installed fonts" },
        { name: "set", help: "(family, style) set the system font" },
        { name: "toggle", help: "show/hide" },
      ], command)
    }
    function ping(): string { return "pong" }
    function open(): string { return root.open() }
    function close(): string { return root.close() }
    function toggle(): string { return root.toggle() }
    function refresh(): string { return root.refresh() }
    function set(family: string, style: string): string { return root.set(family, style) }
    function status(): string { return root.status() }
  }
}
