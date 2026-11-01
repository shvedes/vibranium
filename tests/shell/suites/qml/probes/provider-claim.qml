// Probe: does ProviderHost own the provider-id space, as behaviour?
//
// The registry is state, not a shape: what a unit needs from it is that a claim
// either takes the id or leaves it exactly as it was, that only the owner can
// release it, and that the recovery from a predecessor's stale record is the
// host's job. Every assertion below is a call and its consequence - nothing
// greps the source to find out whether the claim works.
//
// The recovery being SYNCHRONOUS is part of the behaviour: `claim-a` is refused
// once, then succeeds on the retry the host does itself, in the same call. A
// deferred retry would answer false here and take the id two turns later, which
// is exactly the shape this suite exists to rule out.

import QtQuick
import qs.common

Item {
  id: root

  property int threw: 0

  // Two owners, so "mine" and "somebody else's" are different objects and not
  // two spellings of null.
  readonly property var ownerA: ({
    tag: "probe-a"
  })
  readonly property var ownerB: ({
    tag: "probe-b"
  })

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      root.threw++
      kv(key + ".threw", e && e.message ? e.message : e)
    }
  }

  function run() {
    const first = {
      name: "first"
    }
    const second = {
      name: "second"
    }

    // A free id is taken, and the host hands back that very surface.
    kv("claim.free", ProviderHost.claimProvider("probe-x", first, root.ownerA))
    kv("claim.free.same", ProviderHost.providerFor("probe-x") === first)
    // A foreign owner is refused, and a refusal leaves the record alone.
    kv("claim.foreign", ProviderHost.claimProvider("probe-x", second, root.ownerB))
    kv("claim.foreign.same", ProviderHost.providerFor("probe-x") === first)
    // The owner may replace its own surface - that is how a unit re-registers.
    kv("claim.own", ProviderHost.claimProvider("probe-x", second, root.ownerA))
    kv("claim.own.same", ProviderHost.providerFor("probe-x") === second)
    // An unowned claim cannot take a live one either: unowned is "nobody", not
    // "everybody".
    kv("claim.unowned", ProviderHost.claimProvider("probe-x", first, null))
    kv("claim.unowned.same", ProviderHost.providerFor("probe-x") === second)
    // A release by a foreign owner is refused and changes nothing.
    kv("release.foreign", ProviderHost.unregisterProvider("probe-x", root.ownerB))
    kv("release.foreign.same", ProviderHost.providerFor("probe-x") === second)
    // The owner's release is the one that lands, and it is synchronous.
    kv("release.own", ProviderHost.unregisterProvider("probe-x", root.ownerA))
    kv("release.own.gone", ProviderHost.providerFor("probe-x") === null)
    // With the id free, anybody may take it.
    kv("claim.after.release", ProviderHost.claimProvider("probe-x", first, root.ownerB))
    kv("claim.after.release.same", ProviderHost.providerFor("probe-x") === first)
    // THE RECOVERY: this owner's own record is dropped and the claim succeeds in
    // the same call. A deferred retry would return false here instead.
    kv("recovery.reclaim", ProviderHost.claimProvider("probe-x", second, root.ownerB))
    kv("recovery.reclaim.same", ProviderHost.providerFor("probe-x") === second)
    // Ids are independent records, not one slot.
    kv("ids.independent", ProviderHost.claimProvider("probe-y", first, root.ownerA))
    kv("ids.independent.same", ProviderHost.providerFor("probe-x") === second)
    // Bad arguments are refused, not thrown and not stored.
    kv("reject.empty.id", ProviderHost.claimProvider("", first, root.ownerA))
    kv("reject.blank.id", ProviderHost.claimProvider("   ", first, root.ownerA))
    kv("reject.null.provider", ProviderHost.claimProvider("probe-z", null, root.ownerA))
    kv("reject.array.provider", ProviderHost.claimProvider("probe-z", [], root.ownerA))
    kv("reject.stored.nothing", ProviderHost.providerFor("probe-z") === null)
    // Unknown ids read as null, so a caller never has to know the registry.
    kv("unknown.id", ProviderHost.providerFor("probe-nope") === null)

    ProviderHost.unregisterProvider("probe-x", root.ownerB)
    ProviderHost.unregisterProvider("probe-y", root.ownerA)
    kv("cleanup", ProviderHost.providerFor("probe-x") === null
      && ProviderHost.providerFor("probe-y") === null)
  }

  Timer {
    interval: 100
    running: true
    repeat: false

    onTriggered: {
      root.safe("run", root.run)
      root.kv("threw", root.threw)
      console.log("##DONE##")
    }
  }
}
