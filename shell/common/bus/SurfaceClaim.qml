pragma Singleton
pragma ComponentBehavior: Bound
import QtQml
import Quickshell
import Quickshell.Hyprland
import "../runtime/ErrorText.js" as ErrorText
import "../text/StringUtils.js" as SU

// Exclusive surface claim: which of the participating services owns the
// screen, and how the previous owner is put away when a new one arrives.
//
// Not every overlay in the shell takes part. Twelve services claim - the menu,
// the app launcher, the power menu, the pass panel, the clipboard panel, the
// theme picker, the wallpaper picker, the Wi-Fi QR card, the screenshot flow,
// the color pick, and the two context menus (the tray's and the desktop's) -
// and they dismiss each other whichever id the newcomer claims: `claim` fires
// the current holder's closer regardless of the id it held, so one visit at a
// time is a property of the registry rather than a list each surface keeps.
//
// The two context menus are the newest members and the reason the set is not
// just "the fullscreen ones": a popup left mapped under a visit's dim is
// invisible but still there, and it reappears the moment the visit closes. The
// claim is what makes "open a menu over an open tray menu" a replacement rather
// than a stack.
//
// A visit is also the context of the WORKSPACE it was summoned on. A layer
// surface is bound to the output, not the workspace, so the compositor keeps
// it mapped across a switch: a menu opened on one desktop stayed on screen over
// the next one, still holding its Escape scope. The registry dismisses its
// holder when the focused workspace changes. The screenshot flow opts out with
// `keepOnWorkspace` - an annotation in progress is a document rather than a
// menu - and every other claimant is a visit that belongs to its desktop.
//
// The polkit prompt shares the modal class but does not claim, in either
// direction: it is summoned by the system rather than by the user, so standing
// it down for a menu would deny an authentication nobody asked the shell to
// cancel. The cost is the inverse case - a visit opened during a prompt covers
// the card and takes the keyboard from it - which is why the prompt is the one
// surface whose precedence a claim cannot express. The remaining independent
// windows (MenuPanel and the island) are sub-surfaces with no mutual dismissal
// needs.
//
// The color pick claims for the same reason the screenshot flow does: both
// photograph the screen, and a photograph taken with a menu still open is a
// photograph of the menu. The pick additionally holds the pointer, so a
// menu left under it would keep the cursor away from the lens.
//
// SurfaceClaim is Vibranium's local owner/closer registry. It is NOT
// Quickshell Retainable and does not extend an object's destruction
// lifetime: a claim an owner never releases is a leaked entry, not a
// keep-alive, and `owner` is the object identity a release is checked
// against rather than a reason to hold anything.
//
// A claim id names a role ("menu"), never an owner: two claims can share an
// id, and the newer one wins. Ownership is the token `claim` returns, an
// opaque object resolved by reference identity, so a late release from a
// displaced owner cannot take down the claim that replaced it.
Singleton {
  id: root

  // Id of the current holder, "" when free. Read-only: the registry is the
  // only writer, and a caller that could assign this could also invent a
  // holder the map knows nothing about.
  readonly property string activeClaim: root._entry === null ? "" : root._entry.id

  // The focused workspace, watched rather than listened for: it is read off the
  // same monitor property the bar's Workspaces module and the island use, and a
  // binding cannot miss a switch that happened before a listener connected.
  readonly property int focusedWorkspaceId: Hyprland.focusedMonitor
    && Hyprland.focusedMonitor.activeWorkspace
    ? Hyprland.focusedMonitor.activeWorkspace.id : -1
  onFocusedWorkspaceIdChanged: {
    const entry = root._entry
    if (entry === null || entry.keepOnWorkspace) return
    root._fire(entry)
  }

  // Closers held for a claim that is still displaceable, and the entry the
  // activeClaim binding reads. Bounded at one by construction: a claim
  // installs its entry and immediately fires the one it displaced, so a
  // fired entry is no longer tracked and holds no closer.
  property var _entries: []
  property var _entry: null

  // Closers waiting for the closer in flight to unwind, and the flag that
  // makes one closer run at a time. Re-entrancy is queued instead of
  // recursed, so a claim taken from inside a closer cannot grow the stack.
  // Two bounds keep that from trading the stack for a spin: the queue depth
  // caps what one closer body can leave behind, and the cascade budget caps
  // how many closers a single claim may end up running. A displacement past
  // either bound is retired without running and counted, so two closers that
  // claim against each other forever stop instead of spinning.
  readonly property int maxDeferredCloses: 8
  readonly property int maxCascadeCloses: 8
  property var _deferred: []
  property bool _closing: false
  property bool _draining: false
  property int _cascadeRuns: 0

  property int _claims: 0
  property int _closes: 0
  property int _deferralOverflows: 0
  property string _lastError: ""

  // Take the screen for `id`, running the closer of whoever holds it now.
  // `closer` must put the surface away unconditionally: a claim taken
  // before the surface is visible stores a closer that refuses to run
  // (Pass and Clipboard claim after `visible = true` for exactly this
  // reason), and an inert closer is a claim nobody can retire.
  // `owner` is an opaque object the claim is released against.
  // Returns the token for this claim, or null when the arguments do not
  // answer the contract.
  // `options.keepOnWorkspace` marks a claim that a workspace switch must not
  // dismiss: the capture flow's, whose editor is a document in progress.
  function claim(id, closer, owner, options) {
    if (!root._validId(id)) {
      return null
    }
    if (typeof closer !== "function") {
      return null
    }
    if (!root._validOwner(owner)) {
      return null
    }
    const ownerKey = owner
    const keep = options !== undefined && options !== null
      && options.keepOnWorkspace === true

    const prev = root._entry
    if (prev !== null && prev.id === id && prev.owner === ownerKey) {
      // The same holder claiming the same id is one continuous claim: the
      // newer closer replaces the stored one, which is what keeps a
      // re-entrant claim from leaving the old closer stored and never
      // called, and the token the owner already holds stays valid.
      prev.closer = closer
      prev.keepOnWorkspace = keep
      return prev.token
    }

    const entry = {
      token: {},
      id: id,
      owner: ownerKey,
      closer: closer,
      fired: false,
      keepOnWorkspace: keep
    }
    root._entries.push(entry)
    root._entry = entry
    root._claims++
    // A grant is the ordinary case and belongs at DEBUG, below. The line
    // fires on the new-entry path only, so one grant is one claim: the
    // same-holder re-entry above returns the same token for a claim already
    // taken, and counting it twice would put this out of step with
    // diagnostics().claims.
    // The new claim is installed before the old one is fired, so a closer
    // that claims from inside itself displaces the newer entry rather than
    // the older one: the newest claim survives, never the inverted one.
    if (prev !== null) root._fire(prev)
    return entry.token
  }

  // Give up a claim. Takes the token claim returned, so a displaced owner's
  // late release finds nothing and leaves the current holder alone.
  // Returns whether a stored claim was actually dropped.
  function release(handle) {
    const entry = root._entryFor(handle)
    if (entry === null) return false
    root._drop(entry)
    return true
  }

  // Drop every claim held by `owner`, for an owner that is going away. The
  // closers are dropped rather than run: the owner is being destroyed, so
  // a closer closing over it is the last thing that should be called.
  // Returns how many claims were dropped.
  function releaseOwner(owner) {
    if (!root._validOwner(owner)) return 0
    let dropped = 0
    for (let i = root._entries.length - 1; i >= 0; i--) {
      const entry = root._entries[i]
      if (entry.owner !== owner) continue
      root._drop(entry)
      dropped++
    }
    return dropped
  }

  function active() {
    return root.activeClaim
  }

  function diagnostics() {
    return {
      active: root.activeClaim,
      tracked: root._entries.length,
      claims: root._claims,
      closes: root._closes,
      closing: root._closing,
      draining: root._draining,
      deferred: root._deferred.length,
      deferralOverflows: root._deferralOverflows,
      maxDeferredCloses: root.maxDeferredCloses,
      maxCascadeCloses: root.maxCascadeCloses,
      lastError: root._lastError
    }
  }

  // --- internals ---

  // The published owner is a live QML object, and an object is not a value
  // this log publishes. `tag` is the shell's own name for a singleton, and
  // is what a reader joins against the unit scope and the registry entry -
  // the same derivation DesktopLayoutState._ownerName uses, so the two
  // cannot print one owner under two names.

  // Fire a displaced entry's closer exactly once and stop tracking it. The
  // fired latch is what makes "closes the previous holder exactly once" an
  // invariant rather than a description: re-entrancy, a second claim on the
  // same id, and a release that races the fire all land on an entry that
  // has already run, and a closer that ran is never run again.
  function _fire(entry) {
    if (entry.fired) return
    root._untrack(entry)
    if (root._deferred.length >= root.maxDeferredCloses) {
      root._deferralOverflows++
      entry.closer = null
      return
    }
    root._deferred.push(entry)
    root._drain()
  }

  // Run queued closers one at a time. A claim taken from inside a closer
  // queues the entry it displaces instead of recursing, so this loop rather
  // than the JS stack is what a re-entrant claim grows, and _cascadeRuns
  // caps how much of it one claim may pay for.
  function _drain() {
    if (root._closing) return
    if (!root._draining) {
      root._draining = true
      root._cascadeRuns = 0
    }
    while (root._deferred.length > 0 && root._cascadeRuns < root.maxCascadeCloses) {
      const entry = root._deferred.shift()
      const closer = entry.closer
      entry.closer = null
      root._cascadeRuns++
      root._closes++
      root._closing = true
      try {
        // A closer is consumer code: it must not be able to break the
        // caller that displaced it, or the registry's own state with it.
        if (typeof closer === "function") closer()
      } catch (error) {
        root._lastError = root._errorMessage(error)
      }
      root._closing = false
    }
    if (root._deferred.length > 0 && root._cascadeRuns >= root.maxCascadeCloses) {
      // The budget is spent, so the rest of the chain is retired without
      // running. Those surfaces are left open; the count in diagnostics is
      // the price of stopping.
      root._deferralOverflows += root._deferred.length
      for (let i = 0; i < root._deferred.length; i++) root._deferred[i].closer = null
      root._deferred = []
    }
    root._draining = false
  }

  // Stop tracking an entry: it holds no claim any more, so nothing may fire
  // it. The closer reference is left alone for the fire path to pick up and
  // for _drain to drop once it has run.
  function _untrack(entry) {
    const index = root._entries.indexOf(entry)
    if (index >= 0) root._entries.splice(index, 1)
    if (root._entry === entry) root._entry = null
    entry.fired = true
  }

  // Retire an entry without running it: the claim was given up, not
  // displaced, so the closer is dropped and the owner's closure goes with
  // it instead of being retained past the claim.
  function _drop(entry) {
    root._untrack(entry)
    entry.closer = null
  }

  function _entryFor(token) {
    if (token === null || typeof token !== "object") return null
    for (let i = 0; i < root._entries.length; i++) {
      if (root._entries[i].token === token) return root._entries[i]
    }
    return null
  }

  function _validId(id) {
    return SU.isNonEmptyId(id)
  }

  // An owner is an opaque object handle, never a string: a string is only as
  // good as the caller's discipline, and a replacement claim would inherit
  // it.
  function _validOwner(owner) {
    return owner !== null && owner !== undefined && typeof owner === "object"
  }

  function _errorMessage(error) {
    return ErrorText.message(error, "Unknown surface claim error")
  }
}
