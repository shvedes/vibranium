// Probe: the real Registry and Bus singletons, driven through the shapes the
// shell's own callers use.
//
// Two hubs, one probe. Registry is the name -> object service locator every
// layer reaches for (Menu.runCall, Bar modules, AnnotationEditor, Audio,
// Notification self-toasts); Bus is the one-way discrete-state topic bus the
// bar modules re-source from. Both are `pragma Singleton` with no lifecycle
// and no removal, so every name this probe creates is uniquely prefixed and
// the groups that read shared state (offers(), the bus store) filter to the
// probe's own prefix before asserting.
//
// The service object below is deliberately not a toy: it is the union of the
// shapes the real callers register - Notifications' `{ selfNotify }` literal
// whose return is compared with `=== true`, Screenshots' multi-arg noteSaved,
// Audio's `show(kind, level, text, icon, muted)` with a value, a gap and a
// bool, AppLauncher's `hasUsageHistory` property read, and a `label` member
// that is a string where a method is expected.

import QtQuick
import qs.common
// A second alias of the same module, so "the singleton is the same instance
// everywhere" is a measurement rather than an assumption about how the import
// statement happens to be cached.
import qs.common as Alias

Item {
  id: probe
  width: 1
  height: 1

  // Every function a probe of this shape has to observe through the hub.
  property var _calls: []
  // The first reads of the two singletons, kept so together() can prove the
  // instance that took the writes is still the one being read at the end.
  property var _firstRegistry: null
  property var _firstBus: null
  // offers() taken before the remaining offers are published, to show that a
  // caller holding the array is holding a copy and not a view of the store.
  property var _offerSnapshot: null

  // A value containing a newline is escaped so one KV stays one line and the
  // parser never sees a split record.
  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }
  function show(key, value) { kv(key, JSON.stringify(value)) }

  // Registry.call propagates whatever a callee throws - it guards the target
  // and the member, nothing else - so the probe is what catches, or one
  // throwing service would look like a dead probe.
  function caught(fn) {
    try {
      fn()
      return "no-throw"
    } catch (e) {
      return "threw:" + (e && e.message ? e.message : String(e))
    }
  }

  // --- offer() helpers -----------------------------------------------------
  //
  // offers() is every id ever offered, in insertion order, and the shell
  // sorts it itself at the display site (Boot.qml:926). Nothing in common/
  // offers anything, but the filtered helpers keep these assertions about the
  // ids this probe created, so a future common/ offer cannot decide them.
  function offerKeys() { return Registry.offers().filter((id) => id.indexOf("probe.") === 0) }
  function offerMeta(id) { return Registry._offers[id] }
  function offerTitles() { return offerKeys().map((id) => offerMeta(id).title) }

  // --- the fixture ---------------------------------------------------------
  //
  // One object with the union of the member shapes the shell registers. `self`
  // closes over the probe so the call log survives the hub.
  function service(tag) {
    const self = this
    return {
      tag: tag,
      name: "probe-service",
      open: false,
      hasUsageHistory: false,
      historySize: 3,
      // A member that is NOT a function, where call() looks for one.
      label: "not a function",
      // Notifications.selfNotify: returns true, and callers compare with
      // `=== true` so an unhandled call is distinguishable from a refusal.
      selfNotify: function (summary, body, appName) {
        self._calls.push({ method: "selfNotify", args: [summary, body, appName] })
        return true
      },
      // Audio/OSD: five positional args, and no return value at all.
      show: function (kind, level, text, icon, muted) {
        self._calls.push({ method: "show", args: [kind, level, text, icon, muted] })
      },
      stop: function () {
        self._calls.push({ method: "stop", args: [] })
        return true
      },
      bumpCondRev: function () {
        self._calls.push({ method: "bumpCondRev", args: [] })
        return true
      },
      // The bind Registry.call makes explicit with fn.apply(target, args).
      // A linter reads `this.tag` as a missing property here - it analyses the
      // literal statically and resolves `this` to the enclosing type. The run
      // is what settles it, and it is the whole point of the case.
      whoAmI: function () { return this.tag },
      argCount: function () { return arguments.length },
      explode: function () { throw new Error("explode") }
    }
  }

  Component.onCompleted: {
    try {
      run()
    } catch (e) {
      kv("probe.error", "" + (e && e.message ? e.message : e))
    }
    console.log("##DONE##")
  }

  function run() {
    reachable()
    registryContract()
    registryMisses()
    registryPrototypeNames()
    registryOffers()
    busContract()
    busPayloads()
    busTopics()
    together()
  }

  // ---------------------------------------------------------------------
  // Both singletons are reachable from one import of `qs.common`, and the
  // second alias resolves to the same instance: a singleton that rebuilt
  // would drop every registration and republish every topic invisibly.
  // ---------------------------------------------------------------------
  function reachable() {
    kv("both.registry.reachable", typeof Registry)
    kv("both.bus.reachable", typeof Bus)
    kv("both.registry.aliased", typeof Alias.Registry)
    kv("both.bus.aliased", typeof Alias.Bus)
    kv("both.registry.sameInstance", Registry === Alias.Registry)
    kv("both.bus.sameInstance", Bus === Alias.Bus)
    kv("both.registry.distinctFromBus", Registry !== Bus)
    kv("both.alias.registrySame", Alias.Registry === Registry)
    kv("both.alias.busSame", Alias.Bus === Bus)

    // An early write, read back through a second reference much later.
    const firstRegistry = Registry
    const firstBus = Bus
    Bus.publish("both.early", { phase: "reachable" })
    Registry.register("both.svc", service("both.svc"))
    kv("both.identity.viaCall", Registry.call("both.svc", "whoAmI") === "both.svc")
    // Kept for the together() group, which reads them after all the traffic.
    probe._firstRegistry = firstRegistry
    probe._firstBus = firstBus
  }

  // ---------------------------------------------------------------------
  // register() / call() / get(): the happy path, the shapes callers use, and
  // what the hub refuses to register.
  // ---------------------------------------------------------------------
  function registryContract() {
    Registry.register("reg.svc", service("reg.svc"))
    kv("reg.register.ok", Registry.get("reg.svc", "tag") === "reg.svc")
    kv("reg.register.objectAccepted", typeof Registry._registry["reg.svc"])

    // get() reads a property.
    kv("reg.get.boolProperty", Registry.get("reg.svc", "hasUsageHistory"))
    kv("reg.get.numberProperty", Registry.get("reg.svc", "historySize"))
    kv("reg.get.stringMember", Registry.get("reg.svc", "name"))
    kv("reg.get.falsyIsNotAMiss", Registry.get("reg.svc", "open"))
    // A falsy property is not a miss: `false` is a value a caller can use,
    // `undefined` is the shape it has to guard against.
    kv("reg.get.falsyIsNotUndefined", Registry.get("reg.svc", "open") !== undefined)
    kv("reg.get.missingIsUndefined", Registry.get("reg.svc", "nope") === undefined)
    // get() is a plain member read, so it will hand back a function and an
    // inherited Object.prototype member just as readily as a property. That
    // is why every caller that tests an answer tests it, e.g.
    // Entry.qml:365 `if (Registry.get("appLauncher", "hasUsageHistory"))`.
    kv("reg.get.methodMember", typeof Registry.get("reg.svc", "stop"))
    kv("reg.get.inheritedMember", typeof Registry.get("reg.svc", "constructor"))
    kv("reg.get.inheritedToString", Registry.get("reg.svc", "toString") !== undefined)
    // A missing member of a REGISTERED object is undefined - and that is
    // indistinguishable, from the caller's side, from the `=== undefined`
    // that the `!target` guard in get() returns for an unknown name.
    kv("reg.get.missingMemberOnRegistered", String(Registry.get("reg.svc", "nope")))

    // call() reads a method's return value.
    kv("reg.call.boolReturn", Registry.call("reg.svc", "stop"))
    kv("reg.call.voidReturn", Registry.call("reg.svc", "show", "volume", 0.5, "", "audio-volume-high", false))
    show("reg.call.voidCall.log", _calls[_calls.length - 1])
    kv("reg.call.logged", _calls.length)

    // Extra arguments are forwarded positionally, exactly the
    // Registry.call(name, method, ...args) shape Menu.runCall uses.
    Registry.call("reg.svc", "selfNotify", "Disk full", "root partition at 92%", "Vibranium")
    show("reg.call.args.selfNotify", _calls[_calls.length - 1])
    Registry.call("reg.svc", "show", "microphone", 0.25, "", "audio-input-microphone", true)
    show("reg.call.args.show", _calls[_calls.length - 1])
    kv("reg.call.args.spread", Registry.call("reg.svc", "argCount", ...["a", "b", "c"]))
    kv("reg.call.args.arity1", Registry.call("reg.svc", "argCount", "a"))
    kv("reg.call.args.arity0", Registry.call("reg.svc", "argCount"))
    // An explicit undefined is still an argument, so a callee that counts
    // arguments sees it - a defaulted parameter does not silently read 0.
    kv("reg.call.args.explicitUndefinedCounts", Registry.call("reg.svc", "argCount", undefined))

    // fn.apply(target, args): `this` inside the callee is the registered
    // object, not the registry and not undefined.
    kv("reg.call.thisIsTarget", Registry.call("reg.svc", "whoAmI"))
    kv("reg.call.thisIsTarget.identity", Registry.call("reg.svc", "whoAmI") === "reg.svc")

    // A bare literal with no `this` use, the Screenshots shape. The hub holds
    // the object by reference and does not require a QML type behind it.
    Registry.register("reg.bare", {
      noteSaved: function (uid, output) { _calls.push({ method: "noteSaved", args: [uid, output] }); return true },
      noteCancelled: function (uid) { _calls.push({ method: "noteCancelled", args: [uid] }); return true }
    })
    kv("reg.register.bareObject", Registry.get("reg.bare", "noteSaved") !== undefined)
    kv("reg.call.bareObject", Registry.call("reg.bare", "noteSaved", "uid-77", "/tmp/note.png"))
    show("reg.call.bareObject.log", _calls[_calls.length - 1])

    // register() refuses what it cannot key, and a refusal is only observable
    // as the name being absent: it returns undefined, and undefined is what a
    // refused call() also answers. So `undefined` is not a success signal for
    // a caller that means to check one.
    Registry.register("", service("reg.empty"))
    Registry.register("   ", service("reg.blank"))
    Registry.register(7, service("reg.number"))
    Registry.register(null, service("reg.null"))
    Registry.register("reg.noObject")
    Registry.register("reg.nullObject", null)
    Registry.register("reg.undefObject", undefined)
    Registry.register("reg.falseObject", false)
    Registry.register("reg.zeroObject", 0)
    Registry.register("reg.emptyStringObject", "")
    Registry.register("reg.arrayObject", [])
    kv("reg.name.emptyRefused", Registry.call("reg.empty", "stop") === null)
    // A blank name is NOT trimmed: register() only tests `name === ""`, so
    // "   " is a legal key and it is stored under those three spaces. Callers
    // that mean to reject a blank must trim before they get here.
    kv("reg.name.blankAccepted", Registry.get("   ", "tag"))
    kv("reg.name.numberRefused", Registry.call("reg.number", "stop") === null)
    kv("reg.name.nullRefused", Registry.call("reg.null", "stop") === null)
    kv("reg.obj.missingRefused", Registry.call("reg.noObject", "stop") === null)
    kv("reg.obj.nullRefused", Registry.call("reg.nullObject", "stop") === null)
    kv("reg.obj.undefinedRefused", Registry.call("reg.undefObject", "stop") === null)
    // A falsy object is refused because register() tests `!obj`, so an empty
    // string and 0 are refused the same way a null is. Every one of these is
    // a value that would have been a working key with a truthy object.
    kv("reg.obj.falseRefused", Registry.call("reg.falseObject", "stop") === null)
    kv("reg.obj.zeroRefused", Registry.call("reg.zeroObject", "stop") === null)
    kv("reg.obj.emptyStringRefused", Registry.call("reg.emptyStringObject", "stop") === null)
    kv("reg.obj.arrayAccepted", typeof Registry.get("reg.arrayObject", "length"))

    // A method name that is not a function on the object.
    kv("reg.call.nonFunctionMember", String(Registry.call("reg.svc", "label")))
    kv("reg.call.nonFunctionNumber", String(Registry.call("reg.svc", "historySize")))
    kv("reg.call.nullMethodName", String(Registry.call("reg.svc", null)))
    kv("reg.call.undefinedMethodName", String(Registry.call("reg.svc", undefined)))
    // A name that is not a member at all still exists on every object, so the
    // typeof guard cannot refuse it: it is called.
    kv("reg.call.inheritedToStringCalled", Registry.call("reg.svc", "toString"))
    kv("reg.call.inheritedHasOwnProperty", Registry.call("reg.svc", "hasOwnProperty"))

    // The hub does not contain a callee's throw: `!target` and
    // `typeof fn !== "function"` are the only guards, so the exception
    // reaches the caller. Every caller in the tree is a bare
    // `Registry.call(...)` with no try, so a throwing service takes out
    // whatever clicked.
    kv("reg.call.throws", caught(() => Registry.call("reg.svc", "explode", "boom")))
    kv("reg.call.throws.reachedTheCall", _calls.length)

    // Re-registering over a live name replaces it wholesale, last writer
    // wins, and the object the previous writer registered is not called again.
    Registry.register("reg.svc", { tag: "reg.svc-v2", stop: function () { _calls.push({ method: "v2stop", args: [] }); return "v2" } })
    kv("reg.reregister.replaced", Registry.get("reg.svc", "tag"))
    kv("reg.reregister.newMethod", Registry.call("reg.svc", "stop"))
    kv("reg.reregister.oldMethodGone", String(Registry.call("reg.svc", "selfNotify")))
    kv("reg.reregister.oldPropertyGone", String(Registry.get("reg.svc", "hasUsageHistory")))

    // unregister() is idempotent, takes the name alone, and leaves the rest of
    // the store alone.
    const before = Object.keys(Registry._registry).length
    Registry.unregister("reg.svc")
    kv("reg.unregister.gone", Registry.call("reg.svc", "stop"))
    kv("reg.unregister.getGone", String(Registry.get("reg.svc", "tag")))
    kv("reg.unregister.keyGone", Object.keys(Registry._registry).indexOf("reg.svc"))
    kv("reg.unregister.othersIntact", Registry.call("reg.bare", "noteCancelled", "uid-78"))
    kv("reg.unregister.countDroppedByOne", Object.keys(Registry._registry).length === before - 1)
    // A second unregister, and one for a name that was never there, are both
    // no-ops: unregister returns undefined for either.
    kv("reg.unregister.twice", String(Registry.unregister("reg.svc")))
    kv("reg.unregister.neverRegistered", String(Registry.unregister("reg.never")))
    kv("reg.unregister.badName", String(Registry.unregister(null)))
    kv("reg.unregister.countUnchanged", Object.keys(Registry._registry).length === before - 1)
    kv("reg.unregister.callAfter", Registry.call("reg.svc", "stop") === null)
  }

  // ---------------------------------------------------------------------
  // The miss contract, read straight off Registry.qml:50, :53 and :62. Every
  // one of these is a sentinel, not an exception - which is what lets
  // Notifications.qml:1608 write `if (Registry.call(...) === true) return` and
  // treat null as "nobody handled it".
  // ---------------------------------------------------------------------
  function registryMisses() {
    kv("reg.miss.callUnknownName", String(Registry.call("reg.nosuch", "stop")))
    kv("reg.miss.callUnknownName.isNull", Registry.call("reg.nosuch", "stop") === null)
    kv("reg.miss.getUnknownName", String(Registry.get("reg.nosuch", "tag")))
    kv("reg.miss.getUnknownName.isUndefined", Registry.get("reg.nosuch", "tag") === undefined)
    kv("reg.miss.callDoesNotThrow", caught(() => Registry.call("reg.nosuch", "stop")))
    kv("reg.miss.getDoesNotThrow", caught(() => Registry.get("reg.nosuch", "tag")))
    kv("reg.miss.callEmptyName", String(Registry.call("", "stop")))
    kv("reg.miss.getEmptyName", String(Registry.get("", "tag")))
    kv("reg.miss.callAfterUnregister", String(Registry.call("reg.unregistered", "stop")))
  }

  // ---------------------------------------------------------------------
  // Prototype-named services remain ordinary keys, and prototype members
  // are never mistaken for registered services.
  // ---------------------------------------------------------------------
  function registryPrototypeNames() {
    kv("reg.proto.getConstructor", String(Registry.get("constructor", "name")))
    kv("reg.proto.callConstructorToString", String(Registry.call("constructor", "toString")))
    kv("reg.proto.callReturnsTruthyForUnregistered", String(Registry.call("constructor", "valueOf")))
    kv("reg.proto.getHasOwnProperty", String(Registry.get("hasOwnProperty", "length")))
    kv("reg.proto.getUnderscoreProto", String(Registry.get("__proto__", "constructor")))
    kv("reg.proto.beforePollution", String(Registry.get("label", "toUpperCase")))
    kv("reg.proto.callBeforePollution", String(Registry.call("label", "toUpperCase")))
    kv("reg.proto.ordinaryMissStillUndefined", String(Registry.get("literally-anything", "tag")))
    Registry.register("__proto__", service("reg.proto"))
    kv("reg.proto.registerIsKey", Object.prototype.hasOwnProperty.call(Registry._registry, "__proto__"))
    kv("reg.proto.registerIsReadable", String(Registry.get("__proto__", "tag")))
    kv("reg.proto.callOnProtoName", Registry.call("__proto__", "whoAmI"))
    kv("reg.proto.callOnUnregisteredName", String(Registry.call("label", "toUpperCase")))
    kv("reg.proto.getUnregisteredName", String(Registry.get("label", "toUpperCase")))
    kv("reg.proto.registeredIdsHasProto", Registry.registeredIds().includes("__proto__"))
    Registry.unregister("__proto__")
    kv("reg.proto.callAfterUnregister", String(Registry.call("__proto__", "whoAmI")))
    kv("reg.proto.getLeakCleared", String(Registry.get("label", "toUpperCase")))
    Registry.offer("__proto__", { title: "Proto", description: "", verbNames: [] })
    kv("reg.proto.offerIsKey", Registry.offers().includes("__proto__"))
    kv("reg.proto.ownOffersUnaffected", offerKeys().length)
  }

  // ---------------------------------------------------------------------
  // offer()/offers(): the metadata the IPC surface describes itself with, and
  // the store Boot._audit() reads through Registry._offers.
  // ---------------------------------------------------------------------
  function registryOffers() {
    kv("offer.offers.isArray", Array.isArray(Registry.offers()))
    kv("offer.offers.ofStrings", Registry.offers().every((id) => typeof id === "string"))
    // Preserve the actual return array before adding probe offers.
    probe._offerSnapshot = Registry.offers()
    // Nothing offers under this probe's prefix yet, and the shell's own help
    // and audit both iterate whatever this returns.
    kv("offer.offers.initiallyEmpty", offerKeys().length === 0)

    Registry.offer("probe.timer", {
      title: "Timer",
      description: "countdown timer",
      verbNames: ["start", "startMinutes", "stop", "status", "help", "ping"]
    })
    kv("offer.present", offerKeys().indexOf("probe.timer") >= 0)
    kv("offer.meta.keys", Object.keys(offerMeta("probe.timer")).join(","))
    kv("offer.meta.title", offerMeta("probe.timer").title)
    kv("offer.meta.description", offerMeta("probe.timer").description)
    show("offer.meta.verbNames", offerMeta("probe.timer").verbNames)
    kv("offer.meta.verbCount", offerMeta("probe.timer").verbNames.length)
    // Boot._audit() warns for a meta with no verbs, so an empty verbNames
    // array is the one shape the shell itself complains about.
    Registry.offer("probe.verbless", { title: "Verbless", description: "", verbNames: [] })
    kv("offer.meta.emptyVerbs", offerMeta("probe.verbless").verbNames.length)
    kv("offer.meta.emptyVerbs.audited", offerMeta("probe.verbless").verbNames.length === 0)

    // A duplicate id overwrites the metadata in place: the store is keyed, so
    // a service that re-offers after a restart cannot leave two rows in
    // `qs ipc call shell help`.
    Registry.offer("probe.timer", { title: "Timer (v2)", description: "", verbNames: ["stop"] })
    kv("offer.duplicate.overwrote", offerTitles().indexOf("Timer (v2)") >= 0)
    kv("offer.duplicate.oldTitleGone", offerTitles().indexOf("Timer") === -1)
    kv("offer.duplicate.countUnchanged", offerKeys().length === 2)
    show("offer.duplicate.verbNames", offerMeta("probe.timer").verbNames)
    Registry.offer("probe.inhibitor", { title: "Inhibitor", description: "inhibit", verbNames: ["cycleForward"] })
    kv("offer.keys.inInsertionOrder", offerKeys().join(","))
    // Each call returns a fresh snapshot: later offers change the new result,
    // not the array already held by a caller.
    kv("offer.offers.snapshotIsStable", Registry.offers() !== _offerSnapshot
      && _offerSnapshot.indexOf("__proto__") >= 0
      && Registry.offers().length === _offerSnapshot.length + 3)

    // offer() refuses a non-string or empty id. Its return is undefined either
    // way, so - as with register() - the only evidence of a refusal is the
    // id's absence. A blank id is NOT refused, for the same reason it is not
    // refused by register(): neither trims.
    Registry.offer("", { title: "Empty", description: "", verbNames: [] })
    Registry.offer("   ", { title: "Blank", description: "", verbNames: [] })
    Registry.offer(7, { title: "Number", description: "", verbNames: [] })
    Registry.offer(null, { title: "Null", description: "", verbNames: [] })
    kv("offer.bad.onlyTheThreeGoodOnes", offerKeys().length === 3)
    kv("offer.bad.blankAccepted", String(Registry._offers["   "].title))
    kv("offer.bad.numbersRefused", String(Registry._offers["7"]))

    // Unlike register(), offer() does not test the meta at all: null, a
    // string and a number are all stored, and Boot._audit() then reads
    // `meta.verbNames` off whatever it finds.
    Registry.offer("probe.nullMeta", null)
    kv("offer.meta.nullAccepted", Registry._offers["probe.nullMeta"] === null)
    Registry.offer("probe.stringMeta", "not a meta object")
    kv("offer.meta.stringAccepted", Registry._offers["probe.stringMeta"])
    kv("offer.meta.stringAudited", String(Registry._offers["probe.stringMeta"].verbNames))
    Registry.offer("probe.partial", { title: "No verbs" })
    kv("offer.meta.partialAccepted", String(Registry._offers["probe.partial"].verbNames))
    kv("offer.offers.countAfterBadMetas", offerKeys().length === 6)
  }

  // ---------------------------------------------------------------------
  // Bus: one-way discrete state. The ordering guarantee is the whole contract
  // - the last publish of a topic wins, and a reader that binds to
  // Bus.latest() sees exactly that value, whenever it is created.
  // ---------------------------------------------------------------------
  function busContract() {
    kv("bus.latest.unpublished", String(Bus.latest("bus.never")))
    kv("bus.latest.unpublished.isNull", Bus.latest("bus.never") === null)
    kv("bus.latest.unpublished.doesNotThrow", caught(() => Bus.latest("bus.never")))

    Bus.publish("bus.timer", { active: true, remaining: 300 })
    show("bus.roundTrip.object", Bus.latest("bus.timer"))
    // The payload is stored as given, with no copy and no schema: the shell
    // publishes { active, expired, remaining, initial, formatted } and the
    // bar module reads exactly those keys.
    kv("bus.latest.isTheSameObject", Bus.latest("bus.timer") === Bus.latest("bus.timer"))
    kv("bus.latest.field.roundTrips", Bus.latest("bus.timer").remaining)

    // A binding created after a publish still sees current state: that is what
    // latest() replaying the last payload is for, and it is the reason a
    // late-loading bar module is correct on frame one.
    const late = Bus.latest("bus.timer")
    kv("bus.replay.lateReaderGetsTheObject", late === Bus.latest("bus.timer"))
    kv("bus.replay.lateReaderGetsTheValue", late.remaining)

    // Latest wins on a repeat, and a discarded payload is not observable at
    // all: the bus is state, not a log.
    Bus.publish("bus.timer", { active: false, remaining: 0 })
    Bus.publish("bus.timer", { active: true, remaining: 60 })
    show("bus.repeat.latest", Bus.latest("bus.timer"))
    kv("bus.repeat.firstPayloadGone", Bus.latest("bus.timer").remaining === 60)
    kv("bus.repeat.noHistory", Array.isArray(Bus.latest("bus.timer")) === false)

    // Ordering across a burst: the last publish in the loop is the value
    // latest() answers with, and nothing between is retained.
    const order = []
    for (let i = 0; i < 5; i++) {
      Bus.publish("bus.order", { seq: i })
      order.push(Bus.latest("bus.order").seq)
    }
    kv("bus.order.everyPublishVisible", order.join(","))
    kv("bus.order.lastWins", Bus.latest("bus.order").seq)
  }

  // ---------------------------------------------------------------------
  // Bus payload shapes, and the aliasing that is the price of not copying.
  // ---------------------------------------------------------------------
  function busPayloads() {
    Bus.publish("bus.shape.object", { a: 1, b: "two", c: true })
    show("bus.shape.object", Bus.latest("bus.shape.object"))
    Bus.publish("bus.shape.array", [1, 2, 3])
    show("bus.shape.array", Bus.latest("bus.shape.array"))
    Bus.publish("bus.shape.string", "hello")
    kv("bus.shape.string", Bus.latest("bus.shape.string"))
    Bus.publish("bus.shape.number", 42)
    kv("bus.shape.number", Bus.latest("bus.shape.number"))
    Bus.publish("bus.shape.float", 0.5)
    kv("bus.shape.float", Bus.latest("bus.shape.float"))
    Bus.publish("bus.shape.boolTrue", true)
    kv("bus.shape.boolTrue", Bus.latest("bus.shape.boolTrue"))
    Bus.publish("bus.shape.boolFalse", false)
    kv("bus.shape.boolFalse", Bus.latest("bus.shape.boolFalse"))
    // undefined is stored as undefined, and latest() cannot tell it from a
    // topic that was never published: both answer undefined / null. A reader
    // that has not seen the topic yet cannot tell "not yet" from "null".
    Bus.publish("bus.shape.undefined", undefined)
    kv("bus.shape.undefined", String(Bus.latest("bus.shape.undefined")))

    // A payload with a newline survives the round trip; the probe's kv()
    // escapes it so the record stays one line.
    Bus.publish("bus.newline", { note: "first line\nsecond line" })
    kv("bus.newline.count", Bus.latest("bus.newline").note.split("\n").length)
    kv("bus.newline.roundTrips", Bus.latest("bus.newline").note === "first line\nsecond line")

    // A large payload is stored whole, with no truncation and no cap.
    const items = []
    for (let i = 0; i < 2000; i++) items.push({ i: i, label: "item-" + i })
    const large = { items: items, generated: true }
    Bus.publish("bus.large", large)
    kv("bus.large.entryCount", Bus.latest("bus.large").items.length)
    kv("bus.large.lastEntry", Bus.latest("bus.large").items[1999].label)
    kv("bus.large.isTheSameObject", Bus.latest("bus.large") === large)
    kv("bus.large.jsonRoundTrips", JSON.parse(JSON.stringify(Bus.latest("bus.large"))).items.length)

    // The payload is a LIVE REFERENCE, not a copy. A publisher that keeps and
    // later mutates the object it published changes what every reader sees,
    // with no publish and so no re-evaluation of any binding on
    // Bus.latest(). Every publisher in the tree builds a fresh literal inside
    // _publish(), so this never bites today - but it is a property of the
    // store, not of the callers, and a future publisher that reuses a buffer
    // would corrupt readers silently.
    const live = { level: 1, source: "before" }
    Bus.publish("bus.live", live)
    kv("bus.live.initial", Bus.latest("bus.live").level)
    live.level = 2
    live.source = "after"
    kv("bus.live.mutationIsVisible", Bus.latest("bus.live").level)
    kv("bus.live.mutationSource", Bus.latest("bus.live").source)
    kv("bus.live.stillTheSameObject", Bus.latest("bus.live") === live)
    // A reader that stored latest()'s answer holds that same live object, so
    // it drifts too.
    const held = Bus.latest("bus.live")
    live.level = 3
    kv("bus.live.heldReaderDrifts", held.level)
    // Registry does not alias the way Bus does: the object registered is
    // stored as given, so a later mutation of it is equally visible, but the
    // registry never rewrites it - nothing here is Bus's copy-on-write.
    const regd = { tag: "both.live", level: 1 }
    Registry.register("both.live", regd)
    kv("both.live.registryHoldsTheSameObject", Registry.get("both.live", "level"))
  }

  // ---------------------------------------------------------------------
  // Topic names. Bus does no validation at all, so a topic it can key on is
  // whatever coerces to a non-empty property key.
  // ---------------------------------------------------------------------
  function busTopics() {
    Bus.publish("bus.unseen", { first: true })
    show("bus.topic.unseen", Bus.latest("bus.unseen"))
    kv("bus.topic.unseenThenRead", Bus.latest("bus.unseen").first)
    Bus.publish("bus.nested.topic.with.dots", { dots: true })
    kv("bus.topic.dotsAreJustCharacters", Bus.latest("bus.nested.topic.with.dots").dots)

    // "" is a legal property key, so unlike Registry.register("") this one
    // really does store - and it collides with every other empty-string topic.
    Bus.publish("", { empty: true })
    kv("bus.topic.emptyAccepted", Bus.latest("").empty)
    Bus.publish("", { empty: false, second: true })
    kv("bus.topic.emptyCollides", Bus.latest("").second)
    kv("bus.topic.emptyIsOneEntry", Object.keys(Bus._topics).filter((t) => t === "").length)

    // A non-string topic coerces to a key, so 7 and "7" are the SAME topic.
    // publish(7, ...) is a write to topic "7", and it lands in the same slot
    // as the string.
    Bus.publish(7, { numeric: true })
    kv("bus.topic.numberKey", Bus.latest(7).numeric)
    Bus.publish("7", { numeric: false, string: true })
    kv("bus.topic.numberAndStringCollide", Bus.latest(7).string)
    kv("bus.topic.boolKey", String(Bus.latest(true)))
    // null and undefined coerce to "null" and "undefined".
    Bus.publish(null, { fromNull: true })
    kv("bus.topic.nullKey", Bus.latest("null").fromNull)
    Bus.publish(undefined, { fromUndefined: true })
    kv("bus.topic.undefinedKey", Bus.latest("undefined").fromUndefined)
  }

  // ---------------------------------------------------------------------
  // Together: the two hubs are separate stores, and the identity taken in
  // reachable() still holds after every write above.
  // ---------------------------------------------------------------------
  function together() {
    // The same name used as a registry name and a bus topic at once: each
    // store answers only for its own kind and neither shadows the other.
    Registry.register("bus.timer", service("bus.timer-as-a-service"))
    kv("both.noCollision.busUnaffected", Bus.latest("bus.timer").remaining)
    kv("both.noCollision.registryUnaffected", Registry.get("bus.timer", "tag"))
    kv("both.noCollision.callGoesToRegistry", Registry.call("bus.timer", "whoAmI"))
    // An offer id is not a registry name: offering advertises, it does not
    // register, so a peer calling the offered id finds nothing.
    kv("both.noCollision.offerIdIsNotRegistered", String(Registry.get("probe.timer", "tag")))
    // And a registered name is not an offer: Boot._audit() walks offers(), so
    // a unit that registers without offering is invisible to `shell help` and
    // to the "offered but never drained" warning.
    kv("both.noCollision.registeredNameIsNotOffered", offerKeys().indexOf("reg.bare"))

    // unregister() withdraws the name only. The offer is a separate store with
    // no removal path at all, so an offered id stays in `shell help` for the
    // life of the process even after its unit is gone.
    Registry.register("both.retired", service("both.retired"))
    Registry.offer("both.retired", { title: "Retired", description: "", verbNames: [] })
    kv("both.retire.offeredWhileAlive", Registry.offers().indexOf("both.retired") >= 0)
    Registry.unregister("both.retired")
    kv("both.retire.nameGone", Registry.call("both.retired", "stop") === null)
    kv("both.retire.offerSurvives", Registry.offers().indexOf("both.retired") >= 0)
    kv("both.retire.auditReadsTheOrphan", JSON.stringify(Registry._offers["both.retired"].verbNames))

    // The identity the first reads recorded, after every write above. The
    // replacement is deliberate: a singleton that had rebuilt would be a
    // different object and would still be serving the pre-replacement service,
    // so this is the assertion that actually pins one instance.
    Registry.register("both.svc", { tag: "both.svc-v2", whoAmI: function () { return this.tag } })
    kv("both.identity.registryStillTheSame", _firstRegistry === Registry)
    kv("both.identity.registrySurvived", _firstRegistry.get("both.svc", "tag"))
    kv("both.identity.registrySeesReplacement", _firstRegistry.call("both.svc", "whoAmI"))
    kv("both.identity.busStillTheSame", _firstBus === Bus)
    kv("both.identity.busSurvived", _firstBus.latest("bus.timer").remaining)
    kv("both.identity.busSeesLaterWrites", _firstBus.latest("bus.shape.object").a)
  }
}
