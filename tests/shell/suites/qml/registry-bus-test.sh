#!/bin/bash
# Suite: Registry + Bus - the shell's two neutral hubs, observed through a live
# Quickshell.
#
# The probe (suites/qml/probes/registry-bus.qml) drives the real `qs.common`
# singletons and prints one key per observation. This file turns those keys into
# assertions.
#
# Registry is the name -> object service locator every layer reaches for
# (Menu.runCall, the bar modules, AnnotationEditor, Audio, the notification
# self-toasts). Bus is the one-way discrete-state topic bus the bar modules
# re-source from. Neither has a lifecycle, so every name the probe creates is
# uniquely prefixed and the shared-store assertions filter to that prefix.
#
# Headless: QT_QPA_PLATFORM=offscreen, and the probe runs as an ordinary Item
# with no window, so nothing needs a compositor. qp_run kills the process as
# soon as the probe prints ##DONE##.

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/qmlprobe.sh"

t_init "registry-bus" "Registry and Bus: the service locator and the state bus"
require_qs

trap qp_teardown EXIT

if ! qp_run "$TESTS_SHELL_DIR/suites/qml/probes/registry-bus.qml" 30; then
  t_no "the probe reached ##DONE##" "$(printf 'the probe did not finish.\n%s' "$(qp_out)")"
  t_summary
  exit $?
fi

# A probe that dies partway prints this and stops, which would otherwise look
# like a suite full of empty-value passes.
if qp_probe_ran "probe.error"; then
  t_no "the probe ran to the end without throwing" "$(qp_get probe.error)"
else
  t_empty "the probe ran to the end without throwing" "$(qp_get probe.error)"
fi

t_not_empty "the probe produced observations" "$(qp_get both.registry.reachable)"

# --- reachability -----------------------------------------------------------

t_section "both hubs are reachable from one import of qs.common, as one instance"
t_eq "Registry is constructed" "object" "$(qp_get both.registry.reachable)"
t_eq "Bus is constructed" "object" "$(qp_get both.bus.reachable)"
t_eq "Registry through a second module alias" "object" "$(qp_get both.registry.aliased)"
t_eq "Bus through a second module alias" "object" "$(qp_get both.bus.aliased)"
t_eq "the two aliases of Registry are one object" "true" "$(qp_get both.registry.sameInstance)"
t_eq "the two aliases of Bus are one object" "true" "$(qp_get both.bus.sameInstance)"
t_eq "the alias and the bare name agree on Registry" "true" "$(qp_get both.alias.registrySame)"
t_eq "the alias and the bare name agree on Bus" "true" "$(qp_get both.alias.busSame)"
t_eq "Registry and Bus are separate objects" "true" "$(qp_get both.registry.distinctFromBus)"
t_eq "a name registered is callable straight away" "true" "$(qp_get both.identity.viaCall)"

# --- register / get ---------------------------------------------------------

t_section "register() keys a name, get() reads a member of it"
t_eq "the registered object is reachable by name" "true" "$(qp_get reg.register.ok)"
t_eq "a QML-shaped object is stored as an object" "object" "$(qp_get reg.register.objectAccepted)"
t_eq "a bool property reads back" "false" "$(qp_get reg.get.boolProperty)"
t_eq "a number property reads back" "3" "$(qp_get reg.get.numberProperty)"
t_eq "a string member reads back" "probe-service" "$(qp_get reg.get.stringMember)"
t_eq "a falsy property is not a miss" "false" "$(qp_get reg.get.falsyIsNotAMiss)"
t_eq "and it is not undefined either" "true" "$(qp_get reg.get.falsyIsNotUndefined)"
t_eq "a missing member of a registered object is undefined" "true" "$(qp_get reg.get.missingIsUndefined)"
t_eq "it reads as undefined" "undefined" "$(qp_get reg.get.missingMemberOnRegistered)"
# get() is a bare member read, so it filters nothing: a method and an inherited
# Object.prototype member come back just as readily as a property.
t_eq "a method member reads back as a function" "function" "$(qp_get reg.get.methodMember)"
t_eq "an inherited member reads back as a function" "function" "$(qp_get reg.get.inheritedMember)"
t_eq "an inherited member is present" "true" "$(qp_get reg.get.inheritedToString)"

# --- call -------------------------------------------------------------------

t_section "call() dispatches and returns the callee's own answer"
t_eq "a bool return" "true" "$(qp_get reg.call.boolReturn)"
t_eq "a void return is undefined" "undefined" "$(qp_get reg.call.voidReturn)"
t_eq "the void call still reached the callee" \
  '{"method":"show","args":["volume",0.5,"","audio-volume-high",false]}' "$(qp_get reg.call.voidCall.log)"
t_eq "both calls so far were logged" "2" "$(qp_get reg.call.logged)"
t_eq "the callee's this is the registered object" "reg.svc" "$(qp_get reg.call.thisIsTarget)"
t_eq "and not a copy of it" "true" "$(qp_get reg.call.thisIsTarget.identity)"

t_section "arguments past the method name are forwarded positionally"
t_eq "three args reach the callee in order" \
  '{"method":"selfNotify","args":["Disk full","root partition at 92%","Vibranium"]}' "$(qp_get reg.call.args.selfNotify)"
t_eq "a five-arg call keeps its gaps and its bool" \
  '{"method":"show","args":["microphone",0.25,"","audio-input-microphone",true]}' "$(qp_get reg.call.args.show)"
t_eq "a spread argument list forwards every element" "3" "$(qp_get reg.call.args.spread)"
t_eq "one argument" "1" "$(qp_get reg.call.args.arity1)"
t_eq "no argument" "0" "$(qp_get reg.call.args.arity0)"
t_eq "an explicit undefined is still an argument" "1" "$(qp_get reg.call.args.explicitUndefinedCounts)"

t_section "a bare object literal registers as well as a QML type"
t_eq "its method is stored" "true" "$(qp_get reg.register.bareObject)"
t_eq "and it dispatches" "true" "$(qp_get reg.call.bareObject)"
t_eq "with its args forwarded" \
  '{"method":"noteSaved","args":["uid-77","/tmp/note.png"]}' "$(qp_get reg.call.bareObject.log)"

# --- what register() refuses ------------------------------------------------

t_section "register() refuses a name it cannot key"
t_eq "an empty name" "true" "$(qp_get reg.name.emptyRefused)"
t_eq "a numeric name" "true" "$(qp_get reg.name.numberRefused)"
t_eq "a null name" "true" "$(qp_get reg.name.nullRefused)"
# register() tests `name === ""` and never trims, so a whitespace-only name is
# a legal key stored under those three spaces. A caller that means to reject a
# blank has to trim before it gets here.
t_eq "a blank name is NOT refused" "reg.blank" "$(qp_get reg.name.blankAccepted)"

t_section "register() refuses an object it cannot hold"
t_eq "no object at all" "true" "$(qp_get reg.obj.missingRefused)"
t_eq "a null object" "true" "$(qp_get reg.obj.nullRefused)"
t_eq "an undefined object" "true" "$(qp_get reg.obj.undefinedRefused)"
# `!obj` is the whole test, so every falsy value is refused the same way - each
# of them would have been a working key with a truthy object.
t_eq "a false object" "true" "$(qp_get reg.obj.falseRefused)"
t_eq "a zero object" "true" "$(qp_get reg.obj.zeroRefused)"
t_eq "an empty-string object, which reads as a miss" "true" "$(qp_get reg.obj.emptyStringRefused)"
t_eq "an array is accepted, and get() reads its length" "number" "$(qp_get reg.obj.arrayAccepted)"
t_note "a refusal is observable only as the name being absent: register() returns undefined, and undefined is also what a refused call() answers, so a caller cannot use the return value to tell a good registration from a refused one"

# --- the miss contract ------------------------------------------------------

t_section "a miss is a sentinel, never an exception"
t_eq "call() on an unknown name answers null" "null" "$(qp_get reg.miss.callUnknownName)"
t_eq "and it really is null" "true" "$(qp_get reg.miss.callUnknownName.isNull)"
t_eq "get() on an unknown name answers undefined" "undefined" "$(qp_get reg.miss.getUnknownName)"
t_eq "and it really is undefined" "true" "$(qp_get reg.miss.getUnknownName.isUndefined)"
t_eq "call() on a miss does not throw" "no-throw" "$(qp_get reg.miss.callDoesNotThrow)"
t_eq "get() on a miss does not throw" "no-throw" "$(qp_get reg.miss.getDoesNotThrow)"
t_eq "call() on an empty name" "null" "$(qp_get reg.miss.callEmptyName)"
t_eq "get() on an empty name" "undefined" "$(qp_get reg.miss.getEmptyName)"
t_eq "call() after unregister" "null" "$(qp_get reg.miss.callAfterUnregister)"

t_section "a non-function at the method name is the same null"
t_eq "a string member" "null" "$(qp_get reg.call.nonFunctionMember)"
t_eq "a number member" "null" "$(qp_get reg.call.nonFunctionNumber)"
t_eq "a null method name" "null" "$(qp_get reg.call.nullMethodName)"
t_eq "an undefined method name" "null" "$(qp_get reg.call.undefinedMethodName)"
# The typeof guard cannot refuse a name that is not a member at all, because
# every object has it. These are Object.prototype members being called.
t_eq "toString is found and called" "[object Object]" "$(qp_get reg.call.inheritedToStringCalled)"
t_eq "hasOwnProperty is found and called" "false" "$(qp_get reg.call.inheritedHasOwnProperty)"

t_section "a callee's throw is NOT contained by the hub"
qp_assert_contains "the exception propagates to the caller" "reg.call.throws" "threw:explode"
t_eq "and the rest of the run continued" "5" "$(qp_get reg.call.throws.reachedTheCall)"
# Only `!target` and `typeof fn !== "function"` guard the call, so a service
# that throws takes out whatever invoked it. Every caller in the tree is a bare
# `Registry.call(...)` with no try around it.
t_note "Registry.call propagates a callee's exception; the call sites (Menu.qml:1740, Timer.qml:114, Caffeine.qml:114) wrap none of them in a try, so a throwing service propagates into whatever clicked"

# --- re-registration and unregistration -------------------------------------

t_section "re-registering over a live name replaces it wholesale"
t_eq "the replacement object is the one in the store" "reg.svc-v2" "$(qp_get reg.reregister.replaced)"
t_eq "its method is the one that runs" "v2" "$(qp_get reg.reregister.newMethod)"
t_eq "the previous writer's method is gone" "null" "$(qp_get reg.reregister.oldMethodGone)"
t_eq "and so are its properties" "undefined" "$(qp_get reg.reregister.oldPropertyGone)"

t_section "unregister() drops the name and nothing else"
t_eq "the name no longer dispatches" "null" "$(qp_get reg.unregister.gone)"
t_eq "the name no longer reads" "undefined" "$(qp_get reg.unregister.getGone)"
t_eq "and is no longer a key" "-1" "$(qp_get reg.unregister.keyGone)"
t_eq "the other names are untouched" "true" "$(qp_get reg.unregister.othersIntact)"
t_eq "exactly one key went" "true" "$(qp_get reg.unregister.countDroppedByOne)"
# A second unregister, one for a name that was never there and one with a null
# name are all no-ops, and all three are indistinguishable from the hit above:
# unregister() answers undefined either way.
t_eq "unregistering twice" "undefined" "$(qp_get reg.unregister.twice)"
t_eq "unregistering a name that was never registered" "undefined" "$(qp_get reg.unregister.neverRegistered)"
t_eq "unregistering a null name" "undefined" "$(qp_get reg.unregister.badName)"
t_eq "none of them touched the store" "true" "$(qp_get reg.unregister.countUnchanged)"
t_eq "and the name is still gone" "true" "$(qp_get reg.unregister.callAfter)"

# --- prototype names --------------------------------------------------------

t_section "prototype names are ordinary keys and unknown names remain misses"
t_eq "get() on the unregistered name constructor" "undefined" "$(qp_get reg.proto.getConstructor)"
t_eq "call() on it returns the miss sentinel" "null" "$(qp_get reg.proto.callConstructorToString)"
t_eq "no truthy call leaks through" "null" "$(qp_get reg.proto.callReturnsTruthyForUnregistered)"
t_eq "get() on hasOwnProperty is also a miss" "undefined" "$(qp_get reg.proto.getHasOwnProperty)"
t_eq "__proto__ is not an implicit target" "undefined" "$(qp_get reg.proto.getUnderscoreProto)"
t_eq "a missing property is undefined" "undefined" "$(qp_get reg.proto.beforePollution)"
t_eq "call() on a missing name is null" "null" "$(qp_get reg.proto.callBeforePollution)"
t_eq "an unrelated name stays a miss" "undefined" "$(qp_get reg.proto.ordinaryMissStillUndefined)"
t_eq "registering __proto__ creates an enumerable own key" "true" "$(qp_get reg.proto.registerIsKey)"
t_eq "the registered value is readable" "reg.proto" "$(qp_get reg.proto.registerIsReadable)"
t_eq "and dispatchable" "reg.proto" "$(qp_get reg.proto.callOnProtoName)"
t_eq "an unregistered name still returns null" "null" "$(qp_get reg.proto.callOnUnregisteredName)"
t_eq "and its property remains undefined" "undefined" "$(qp_get reg.proto.getUnregisteredName)"
t_eq "registeredIds includes the literal key" "true" "$(qp_get reg.proto.registeredIdsHasProto)"
t_eq "unregister removes the prototype-named service" "null" "$(qp_get reg.proto.callAfterUnregister)"
t_eq "and does not leak properties" "undefined" "$(qp_get reg.proto.getLeakCleared)"
t_eq "the offer store also records __proto__ as an own key" "true" "$(qp_get reg.proto.offerIsKey)"
t_eq "without disturbing existing offers" "0" "$(qp_get reg.proto.ownOffersUnaffected)"

# --- offer / offers ---------------------------------------------------------

t_section "offer() records the metadata the IPC surface describes itself with"
t_eq "offers() is an array" "true" "$(qp_get offer.offers.isArray)"
t_eq "of strings" "true" "$(qp_get offer.offers.ofStrings)"
t_eq "and nothing under this probe's prefix yet" "true" "$(qp_get offer.offers.initiallyEmpty)"
t_eq "the offered id is listed" "true" "$(qp_get offer.present)"
t_eq "the meta keeps exactly the three declared fields" "title,description,verbNames" "$(qp_get offer.meta.keys)"
t_eq "the title" "Timer" "$(qp_get offer.meta.title)"
t_eq "the description" "countdown timer" "$(qp_get offer.meta.description)"
t_eq "the verb names, in order" \
  '["start","startMinutes","stop","status","help","ping"]' "$(qp_get offer.meta.verbNames)"
t_eq "the verb count" "6" "$(qp_get offer.meta.verbCount)"
# Boot.qml:944 warns for a meta with no verbs, so the empty array is the one
# shape the shell itself complains about.
t_eq "an empty verb list is accepted" "0" "$(qp_get offer.meta.emptyVerbs)"
t_eq "and is what the audit looks for" "true" "$(qp_get offer.meta.emptyVerbs.audited)"

t_section "a duplicate offer overwrites in place"
t_eq "the new title replaces the old" "true" "$(qp_get offer.duplicate.overwrote)"
t_eq "the old title is gone" "true" "$(qp_get offer.duplicate.oldTitleGone)"
t_eq "and the id is not listed twice" "true" "$(qp_get offer.duplicate.countUnchanged)"
t_eq "the new verb list replaces the old" '["stop"]' "$(qp_get offer.duplicate.verbNames)"
t_eq "a third id appends, and the list stays in insertion order" \
  "probe.timer,probe.verbless,probe.inhibitor" "$(qp_get offer.keys.inInsertionOrder)"
# offers() returns an array snapshot, not a live view of the backing store.
t_eq "a list taken earlier stays isolated from later offers" "true" "$(qp_get offer.offers.snapshotIsStable)"

t_section "offer() refuses a name it cannot key, and stores any meta"
t_eq "an empty, blank, numeric and null id are all refused" "true" "$(qp_get offer.bad.onlyTheThreeGoodOnes)"
# offer() tests `typeof id !== "string" || id === ""` and never trims, exactly
# like register(), so a whitespace-only id is a legal key.
t_eq "a blank id is NOT refused" "Blank" "$(qp_get offer.bad.blankAccepted)"
t_eq "a numeric id is refused" "undefined" "$(qp_get offer.bad.numbersRefused)"
# offer() does not look at meta at all, so Boot._audit() goes on to read
# meta.verbNames off whatever it finds.
t_eq "a null meta is accepted" "true" "$(qp_get offer.meta.nullAccepted)"
t_eq "a string meta is accepted verbatim" "not a meta object" "$(qp_get offer.meta.stringAccepted)"
t_eq "and the audit reads undefined off it" "undefined" "$(qp_get offer.meta.stringAudited)"
t_eq "a meta with no verbNames is accepted" "undefined" "$(qp_get offer.meta.partialAccepted)"
t_eq "all five well-named ids are listed" "true" "$(qp_get offer.offers.countAfterBadMetas)"
t_note "offer() validates the id but never the meta, so a non-object meta reaches Boot._audit() (Boot.qml:944) which reads meta.verbNames off it. Every offer in the tree is a literal with all three fields, so nothing is wrong today"

# --- Bus: the miss and the round trip ---------------------------------------

t_section "Bus.latest on a topic nobody published"
t_eq "answers null" "null" "$(qp_get bus.latest.unpublished)"
t_eq "and it really is null" "true" "$(qp_get bus.latest.unpublished.isNull)"
t_eq "and it does not throw" "no-throw" "$(qp_get bus.latest.unpublished.doesNotThrow)"

t_section "a published payload reads back whole"
t_eq "the object round-trips field for field" '{"active":true,"remaining":300}' "$(qp_get bus.roundTrip.object)"
t_eq "a field reads back with its value" "300" "$(qp_get bus.latest.field.roundTrips)"
t_eq "and it is the same object every read" "true" "$(qp_get bus.latest.isTheSameObject)"
# Replay is what makes a bar module that loads after a publish correct on frame
# one, so a reader created after the write has to see current state.
t_eq "a late reader gets the same object" "true" "$(qp_get bus.replay.lateReaderGetsTheObject)"
t_eq "and the same value" "300" "$(qp_get bus.replay.lateReaderGetsTheValue)"

t_section "the ordering guarantee: the last publish of a topic wins"
t_eq "after three publishes the last payload is the answer" '{"active":true,"remaining":60}' "$(qp_get bus.repeat.latest)"
t_eq "the superseded payload is gone" "true" "$(qp_get bus.repeat.firstPayloadGone)"
t_eq "and nothing is retained as history" "true" "$(qp_get bus.repeat.noHistory)"
# Each publish in a burst is visible through latest() the moment it lands, and
# the value a reader holds after the burst is the last one, not a queue.
t_eq "every publish in a burst is visible in turn" "0,1,2,3,4" "$(qp_get bus.order.everyPublishVisible)"
t_eq "and the burst settles on the last" "4" "$(qp_get bus.order.lastWins)"
t_note "Bus is state, not a log: a topic has exactly one payload, so a reader that is not created before a publish cannot tell what it missed. That is the shape the shell wants - the bar modules re-source discrete state - and it is why the README keeps continuous values (volume, workspaces) off the bus"

# --- Bus: payload shapes ----------------------------------------------------

t_section "every JSON-ish payload shape survives the round trip"
t_eq "an object" '{"a":1,"b":"two","c":true}' "$(qp_get bus.shape.object)"
t_eq "an array" "[1,2,3]" "$(qp_get bus.shape.array)"
t_eq "a string" "hello" "$(qp_get bus.shape.string)"
t_eq "an integer" "42" "$(qp_get bus.shape.number)"
t_eq "a float" "0.5" "$(qp_get bus.shape.float)"
t_eq "true" "true" "$(qp_get bus.shape.boolTrue)"
t_eq "false" "false" "$(qp_get bus.shape.boolFalse)"
# There is no has-topic check, so a reader cannot tell "published undefined"
# from "never published": one answers undefined and the other null.
t_eq "an undefined payload" "undefined" "$(qp_get bus.shape.undefined)"

t_section "a payload with a newline survives, and stays one record"
t_eq "it still has its two lines" "2" "$(qp_get bus.newline.count)"
t_eq "and compares equal to what was published" "true" "$(qp_get bus.newline.roundTrips)"

t_section "a large payload is stored whole"
t_eq "every entry is kept" "2000" "$(qp_get bus.large.entryCount)"
t_eq "the last entry is intact" "item-1999" "$(qp_get bus.large.lastEntry)"
t_eq "and the structure is walkable" "2000" "$(qp_get bus.large.jsonRoundTrips)"
t_eq "and it is the published object, not a copy" "true" "$(qp_get bus.large.isTheSameObject)"

t_section "the payload is a live reference, not a copy"
t_eq "it reads as published" "1" "$(qp_get bus.live.initial)"
# The store at Bus.qml:27-29 writes `entry.payload = payload` and keeps the
# caller's object, so a publisher that keeps and later mutates it changes what
# every reader sees - with no publish, and so with no re-evaluation of any
# binding on Bus.latest(). Every publisher in the tree builds a fresh literal
# inside _publish(), so this never bites today; it is a property of the store.
t_eq "a later mutation of the published object is visible" "2" "$(qp_get bus.live.mutationIsVisible)"
t_eq "on every field" "after" "$(qp_get bus.live.mutationSource)"
t_eq "and it is still the very same object" "true" "$(qp_get bus.live.stillTheSameObject)"
t_eq "a reader that stored latest()'s answer drifts too" "3" "$(qp_get bus.live.heldReaderDrifts)"
t_eq "the registry holds its object the same way" "1" "$(qp_get both.live.registryHoldsTheSameObject)"

# --- Bus: topic names -------------------------------------------------------

t_section "a topic nobody has read yet, and dotted names"
t_eq "an unseen topic reads back" '{"first":true}' "$(qp_get bus.topic.unseen)"
t_eq "and its field is readable" "true" "$(qp_get bus.topic.unseenThenRead)"
t_eq "dots are just characters in a key" "true" "$(qp_get bus.topic.dotsAreJustCharacters)"

t_section "Bus does no topic validation, so a key is whatever coerces to one"
# "" is a legal property key, so unlike Registry.register("") this really does
# store - and every empty-string topic collides with every other.
t_eq "an empty topic is accepted" "true" "$(qp_get bus.topic.emptyAccepted)"
t_eq "and a second publish lands in the same slot" "true" "$(qp_get bus.topic.emptyCollides)"
t_eq "there is exactly one such entry" "1" "$(qp_get bus.topic.emptyIsOneEntry)"
# A number coerces to a string key, so publish(7, ...) and publish("7", ...) are
# the same topic.
t_eq "a numeric topic is keyed by its string form" "true" "$(qp_get bus.topic.numberKey)"
t_eq "and a numeric and a string topic collide" "true" "$(qp_get bus.topic.numberAndStringCollide)"
t_eq "a boolean topic coerces to \"true\"" "null" "$(qp_get bus.topic.boolKey)"
t_eq "null coerces to \"null\"" "true" "$(qp_get bus.topic.nullKey)"
t_eq "undefined coerces to \"undefined\"" "true" "$(qp_get bus.topic.undefinedKey)"
t_note "Bus.publish has no id guard where Registry.register has one, so a non-string topic is silently coerced to a string key and a numeric and a string topic are the same topic. Every topic in the tree is a source literal, so nothing collides today"

# --- the two stores together ------------------------------------------------

t_section "the same name used as a registry name and a bus topic"
t_eq "the bus topic is unaffected by the registration" "60" "$(qp_get both.noCollision.busUnaffected)"
t_eq "the registry name is unaffected by the publish" "bus.timer-as-a-service" "$(qp_get both.noCollision.registryUnaffected)"
t_eq "and call() still reaches the registry" "bus.timer-as-a-service" "$(qp_get both.noCollision.callGoesToRegistry)"
# offering advertises, it does not register: a peer calling an offered id finds
# nothing, and a registered name is invisible to Boot._audit(), which walks
# offers() - so a unit that registers without offering gets neither the
# 'shell help' listing nor the "offered but never drained" warning.
t_eq "an offered id is not a registered name" "undefined" "$(qp_get both.noCollision.offerIdIsNotRegistered)"
t_eq "a registered name is not an offered id" "-1" "$(qp_get both.noCollision.registeredNameIsNotOffered)"

t_section "unregister does not withdraw the offer"
t_eq "the id is offered while the unit is alive" "true" "$(qp_get both.retire.offeredWhileAlive)"
t_eq "unregistering the name takes the call with it" "true" "$(qp_get both.retire.nameGone)"
t_eq "and the offer outlives it" "true" "$(qp_get both.retire.offerSurvives)"
t_eq "which the audit then reads as an orphan" "[]" "$(qp_get both.retire.auditReadsTheOrphan)"
t_note "the offer store has no removal path at all, so an offered id stays in 'qs ipc call shell help' and in Boot._audit()'s offered-but-never-drained check for the life of the process, even after its unit is unregistered"

t_section "one instance each, after every write above"
t_eq "the first Registry read is still this Registry" "true" "$(qp_get both.identity.registryStillTheSame)"
t_eq "and it serves the replacement, not the original" "both.svc-v2" "$(qp_get both.identity.registrySurvived)"
t_eq "so its call reaches the replacement too" "both.svc-v2" "$(qp_get both.identity.registrySeesReplacement)"
t_eq "the first Bus read is still this Bus" "true" "$(qp_get both.identity.busStillTheSame)"
t_eq "and it still holds the topic published first" "60" "$(qp_get both.identity.busSurvived)"
t_eq "and the topics published after it" "1" "$(qp_get both.identity.busSeesLaterWrites)"

t_summary
