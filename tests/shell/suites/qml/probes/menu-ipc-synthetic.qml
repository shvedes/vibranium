// Headless probe for the public Menu gateway. No desktop shell is started:
// the real singleton is constructed offscreen (with a stubbed MenuView so no
// Wayland layer surface is needed), a synthetic inline bundle is installed
// through the gateway's own open operation, and every observation goes
// through the same frames the router hands to vb-shell.
import QtQuick
import Quickshell
import qs.common
import qs.features.menu
import "common/text/IpcProtocol.js" as P
import "common/text/IpcCatalog.js" as Catalog

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }
  function frame(text) { return text && typeof text === "object" ? text : {} }
  function code(text) {
    const r = frame(text)
    return r.ok === false ? r.error.code : "ok"
  }
  function payload(text) {
    const r = frame(text)
    return r.ok ? r.data : null
  }
  // A real v1 envelope through the real router: proves the catalog grammar,
  // the registered closure map and the reply framing agree with the gateway.
  function call(argv) {
    const raw = IpcRouter.invoke(P.encode({ v: 1, kind: "call", argv: argv, literalFrom: null }))
    const r = P.decode(raw)
    if (!r) return null
    if (r.ok === false) return { error: r.error.code }
    return r.data
  }
  function rows() { return payload(Menu.ipcList()) || [] }
  function row(id) { return rows().find(r => r.id === id) }
  function get(ref) { return payload(Menu.ipcItemGet(ref)) }

  Component.onCompleted: {
    try { run() } catch (e) { kv("probe.error", "" + (e && e.message ? e.message : e)) }
    Menu.close()
    console.log("##DONE##")
  }

  function bundle() {
    return {
      entry: "main",
      pages: [{
        id: "main", title: "Main", items: [
          { id: "flag", type: "toggle", label: "Flag", checked: false, onToggle: "true" },
          { id: "count", type: "number", label: "Count", value: 10, min: 0, max: 20, step: 5 },
          { id: "text", type: "text", label: "Text", value: "old", onSubmit: "true" },
          { id: "mode", type: "select", label: "Mode", value: "a",
            options: [{ value: "a", label: "A" }, { value: "b", label: "B", enabled: false }] },
          { id: "wizard", type: "action", label: "Wizard", flow: [
            { kind: "select", options: [{ value: "x" }, { value: "y" }] },
            { kind: "text", required: true, value: "" },
            { kind: "action", skipUnless: "x" }
          ] },
          { id: "armed", type: "action", label: "Armed", command: "true",
            confirm: { stages: 3 } },
          { id: "gone", type: "action", label: "Gone", delCommand: "@forget" },
          { id: "secret", type: "text", label: "Secret", value: "hidden", sensitive: true },
          { id: "outer", type: "group", label: "Outer", children: [
            { id: "inner", type: "toggle", label: "Inner", checked: false, onToggle: "true" }
          ] },
          { id: "blocked", type: "group", label: "Blocked", enabled: false, children: [
            { id: "vetoed", type: "toggle", label: "Vetoed", checked: false, onToggle: "true" }
          ] },
          { id: "jump", type: "submenu", label: "Jump", page: "other" },
          { id: "toCells", type: "submenu", label: "Cells", page: "cells" }
        ]
      }, {
        id: "other", title: "Other", items: [
          { id: "backRow", type: "action", label: "Back row", command: "true" }
        ]
      }, {
        id: "cells", title: "Cells", layout: "grid", items: [
          { id: "cell", type: "action", label: "Cell", value: "emoji", command: "true" }
        ]
      }]
    }
  }

  function run() {
    // Closed root is a successful projection, not an error.
    const closed = payload(Menu.ipcStatus())
    kv("closed.open", closed.open)
    kv("closed.page", closed.page)
    kv("closed.depth", closed.depth)
    kv("closed.scope", closed.scope)
    kv("closed.row", closed.row)
    kv("closed.revision", typeof closed.revision)
    kv("closed.currentOpen", payload(Menu.ipcCurrent()).open)
    kv("closed.listCode", code(Menu.ipcList()))
    kv("closed.pagesEmpty", payload(Menu.ipcPages()).length)
    kv("closed.goCode", code(Menu.ipcGo("other")))

    const text = JSON.stringify(bundle())
    kv("open.ok", payload(Menu.ipcOpen({ inline: true, text: text, frag: "" })).open)
    kv("open.page", payload(Menu.ipcCurrent()).page)
    kv("open.sameNoop", payload(Menu.ipcOpen({ inline: true, text: text, frag: "" })).page)
    kv("list.count", rows().length)
    kv("list.refShape", /^r[^.]+\.\d+\.\d+\.\d+$/.test(row("flag").ref))
    kv("list.parentShape", row("inner") !== undefined ? String(row("inner").parent).indexOf("r") === 0 : false)

    const toggle = row("flag")
    kv("toggle.before", get(toggle.ref).checked)
    kv("toggle.set", payload(Menu.ipcItem(toggle.ref, "set", { value: true })).value)
    kv("toggle.after", get(toggle.ref).checked)
    kv("toggle.wrongType", code(Menu.ipcItem(toggle.ref, "set", { value: "true" })))
    const activated = frame(Menu.ipcItem(toggle.ref, "activate", {}))
    kv("toggle.activate", activated.ok === true && activated.data === undefined)

    const number = row("count")
    kv("number.step", payload(Menu.ipcItem(number.ref, "step", { direction: "up" })).value)
    kv("number.clamp", payload(Menu.ipcItem(number.ref, "set", { value: 500 })).value)
    kv("number.wrongType", code(Menu.ipcItem(number.ref, "set", { value: "12" })))
    kv("number.stepDown", payload(Menu.ipcItem(number.ref, "step", { direction: "down" })).value)

    const textRow = row("text")
    kv("text.set", payload(Menu.ipcItem(textRow.ref, "set", { value: "  new  " })).value)
    kv("text.openAfterSet", get(textRow.ref).expanded)

    const mode = row("mode")
    const opts = payload(Menu.ipcItem(mode.ref, "options", {}))
    kv("options.ids", opts.map(o => o.id).join(","))
    kv("options.disabled", opts[1].enabled)
    kv("choose.badId", code(Menu.ipcItem(mode.ref, "choose", { option: "o9" })))
    kv("choose.disabled", code(Menu.ipcItem(mode.ref, "choose", { option: "o1" })))
    kv("select.setRefuses", code(Menu.ipcItem(mode.ref, "set", { value: "b" })))

    const secret = row("secret")
    kv("secret.protected", get(secret.ref).protected)
    kv("secret.valueRedacted", get(secret.ref).value)
    kv("secret.writeRefused", code(Menu.ipcItem(secret.ref, "set", { value: "oops" })))

    const vetoed = row("vetoed")
    kv("blocked.available", vetoed ? vetoed.available : "absent")
    kv("blocked.activate", code(Menu.ipcItem(vetoed.ref, "activate", {})))

    const wizard = row("wizard")
    kv("flow.open", payload(Menu.ipcItem(wizard.ref, "open", {})).open)
    kv("flow.set", code(Menu.ipcItem(wizard.ref, "flow", { verb: "set", step: 0, value: "x" })))
    kv("flow.skipStep", code(Menu.ipcItem(wizard.ref, "flow", { verb: "set", step: 1, value: "y" })))
    kv("flow.next", payload(Menu.ipcItem(wizard.ref, "flow", { verb: "next" })).step)
    kv("flow.setDraft", code(Menu.ipcItem(wizard.ref, "flow", { verb: "set", step: 1, value: "typed" })))
    kv("flow.back", payload(Menu.ipcItem(wizard.ref, "flow", { verb: "back" })).step)
    kv("flow.cancel", payload(Menu.ipcItem(wizard.ref, "flow", { verb: "cancel" })).active)
    kv("flow.noPersist", get(wizard.ref).value)

    const armed = row("armed")
    kv("confirm.arm", code(Menu.ipcItem(armed.ref, "activate", {})))
    kv("confirm.status1", payload(Menu.ipcItem(armed.ref, "confirm", { verb: "status" })).stage)
    kv("confirm.next2", payload(Menu.ipcItem(armed.ref, "confirm", { verb: "next" })).stage)
    kv("confirm.next3", payload(Menu.ipcItem(armed.ref, "confirm", { verb: "next" })).stage)
    kv("confirm.cancel", payload(Menu.ipcItem(armed.ref, "confirm", { verb: "cancel" })).stage)
    kv("confirm.nextIdle", code(Menu.ipcItem(armed.ref, "confirm", { verb: "next" })))

    kv("delete.1", code(Menu.ipcItem(row("gone").ref, "delete", {})))
    kv("delete.2", code(Menu.ipcItem(row("gone").ref, "delete", {})))
    kv("pages.count", payload(Menu.ipcPages()).length)
    kv("pages.reachable", payload(Menu.ipcPages()).filter(p => p.reachable).length)
    kv("go.other", payload(Menu.ipcGo("other")).page)
    kv("back.main", payload(Menu.ipcBack()).page)
    kv("current.refStillLive", row("flag").ref === rows().find(r => r.id === "flag").ref)

    // A re-injected page with the same ids but a new object retires its refs.
    const before = row("flag").ref
    const rebuilt = bundle()
    rebuilt.pages[0].items.push({ id: "extra", type: "action", label: "Extra", command: "true" })
    Menu.injectPage(pageFromRaw(rebuilt.pages[0]), null)
    kv("generation.pageRefChanged", before !== rows().find(r => r.id === "flag").ref)
    kv("generation.oldRefStale", code(Menu.ipcItemGet(before)))

    // Grid action uses the same rowRunAction as a list action.
    kv("go.cells", payload(Menu.ipcGo("cells")).page)
    kv("grid.action", code(Menu.ipcItem(rows().find(r => r.id === "cell").ref, "action", {})))
    kv("back.afterGrid", payload(Menu.ipcBack()).open)
    // The grid action dismisses the menu as a real action would; reopen the
    // same bundle before continuing the read-only search checks.
    kv("reopen", payload(Menu.ipcOpen({ inline: true, text: text, frag: "" })).open)

    kv("search.global", code(Menu.ipcSearch("global", "back")))
    const results = rows()
    kv("search.hasHits", results.some(r => r.type === "result"))
    const searchRef = results.find(r => r.type === "result") ? results.find(r => r.type === "result").ref : null
    // A partial rerender of the same results view must retire the old hit ref.
    kv("search.rerender", code(Menu.ipcSearch("global", "back row")))
    if (searchRef) kv("search.rerenderStale", code(Menu.ipcItemGet(searchRef)))
    kv("search.clear", payload(Menu.ipcSearch("clear", "")).scope)
    kv("select.noPanel", code(Menu.ipcSelect(row("flag").ref)))
    kv("bundle.isOpenOther", Menu.isBundleOpen("any.jsonc"))
    kv("close.ok", payload(Menu.ipcClose()).open)
    kv("closed.afterClose", payload(Menu.ipcCurrent()).open)
    kv("ref.staleAfterClose", code(Menu.ipcItemGet(toggle.ref)))

    // The catalog and the owner map, end to end.
    kv("router.registered", IpcRouter.registered("menu"))
    show("router.ping", call(["menu", "ping"]))
    // Opening is an order: the router answers with no data, so success is
    // the absence of a payload rather than an `open` field.
    kv("router.open", call(["menu", "open", "inline", text]) == null)
    kv("router.list", (call(["menu", "list"]) || []).length)
    kv("router.unknown", (call(["menu", "noSuchVerb"]) || {}).error)
    const branches = Catalog.findTarget("menu").branches
    kv("router.itemBranch", ["item", "search"].every(k => Object.prototype.hasOwnProperty.call(branches, k)))
    kv("router.rowCount", Catalog.findTarget("menu").rows.length)

    // Built-in Settings journey: open the shipped catalog, inject a live page
    // with an option list built at runtime, and operate it through the model.
    Menu.close()
    kv("settings.openCode", code(Menu.ipcOpen({ path: Paths.settingsCatalogPath })))
    kv("settings.isBundleOpen", Menu.isBundleOpen(Paths.settingsCatalogPath + "#other"))
    kv("settings.bundleEntry", payload(Menu.ipcStatus()).bundleEntry)
    const journey = Menu.buildDynamicPage("ipc-journey", "Journey", 0, [
      { id: "dynamic", type: "select", label: "Dynamic", value: "one",
        options: [{ value: "one", label: "One" }, { value: "two", label: "Two" }] }
    ], {})
    Menu.injectPage(journey, null)
    // The owning provider's action is what puts an injected page on the stack.
    Menu.push("ipc-journey")
    kv("settings.journeyPage", payload(Menu.ipcPages()).some(p => p.id === "ipc-journey"))
    kv("settings.journeyList", code(Menu.ipcList("ipc-journey")))
    show("settings.journeyRows", Menu.ipcList("ipc-journey").data)
    const dynRow = Menu.ipcList("ipc-journey").data[0]
    kv("settings.dynamicOptions", dynRow ? payload(Menu.ipcItem(dynRow.ref, "options", {})).length : -1)
    kv("settings.dynamicChoose", dynRow ? code(Menu.ipcItem(dynRow.ref, "choose", { option: "o1" })) : "no-row")
    kv("settings.dynamicValue", dynRow ? payload(Menu.ipcItemGet(dynRow.ref)).value : "no-row")
    Menu.close()
  }

  function pageFromRaw(raw) {
    return Menu.buildDynamicPage(raw.id, raw.title, 0, raw.items,
      { layout: raw.layout || "list" })
  }
}
