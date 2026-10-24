pragma Singleton

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "WindowMatch.js" as WindowMatch

// Neutral contract: "the user just acted on this app's notification, so
// put the app in front". One call, no process, no dispatcher string.
//
// Why the shell does this at all instead of leaving it to the sender: an
// activated notification only round-trips as the org.freedesktop
// Notifications ActionInvoked signal, and the sender's answer is an
// activation request the compositor is free to refuse. Hyprland refuses
// it by default: CWindow::activate marks the window urgent and then
// returns unless focus_on_activate was configured for it, which is why
// activating a notification blinks the sender's window instead of
// switching to it. That refusal is the compositor's policy, not a bug,
// and a rule that forced it through would let any background app yank
// focus the same way.
//
// The native way past it is zwlr-foreign-toplevel-management: a client
// asking the compositor to activate a window it names. Hyprland answers
// that path with a forced activate - it documents it as the
// window-switcher path, which bypasses the configured policy - and needs
// no configuration to do so.
//
// No process is spawned and no Hyprland dispatcher is written: toplevels
// come from the protocol binding and activate() is a request on an object
// this shell already holds.
//
// What the protocol cannot supply is which window the notification
// belongs to. The notification spec carries no pid and no window handle,
// so recognition is a policy, and it lives in WindowMatch.js next to the
// code that consumes it.
Singleton {
  id: root

  // Focus order, read off the compositor's raw event stream, because
  // nothing else exposes it: a toplevel says whether it is focused now,
  // never how recently it was focused before that. A sender with several
  // windows open - a browser, a chat client - means its most recently
  // used one, and this is where that answer comes from.
  //
  // Bounded because the list is per focus, not per window, so a session
  // that focuses ten thousand windows would grow it without limit.
  // Overflow drops the oldest entries, which only costs the ordering of
  // windows not focused lately - the ones a notification is least likely
  // to name.
  readonly property int focusHistoryLimit: 32
  property var _focused: []

  // Ordering key for one window, 0 when the shell never saw it focused.
  // Keyed by Hyprland's window address because that is the only stable
  // identifier a toplevel carries: appId repeats across an app's windows
  // and title changes under it. A toplevel whose address is unresolved
  // (the mapping protocol is what supplies it) scores 0 and falls back to
  // the ordering below, which is why a missing protocol degrades the
  // choice rather than breaking the call.
  function recencyOf(address) {
    if (address === "") return 0
    const at = root._focused.lastIndexOf(address)
    return at === -1 ? 0 : root._focused.length - at
  }

  // Snapshot of every window, ordered so that index 0 is the one a
  // sender naming this app most likely means. Rows carry the toplevel
  // itself, so a match is a direct activate() rather than a second
  // lookup that could resolve to a different window than the one matched.
  function _ranked() {
    const live = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
    const rows = []
    for (let i = 0; i < live.length; i++) {
      const toplevel = live[i]
      if (!toplevel) continue
      rows.push({
        toplevel: toplevel,
        appId: toplevel.appId,
        // An address the shell has never seen is 0, which loses every
        // tie against a window it has - see recencyOf.
        recency: root.recencyOf(toplevel.HyprlandToplevel.address),
        activated: toplevel.activated === true
      })
    }
    // Already focused first (activating it again is a no-op the
    // compositor absorbs), then most recently focused. Array.prototype.sort
    // is stable, so the protocol's own order settles the rest.
    rows.sort((a, b) => (b.activated - a.activated) || (b.recency - a.recency))
    return rows
  }

  // Focus the window the sender of `notif` owns. True when a window took
  // the request, false when that sender has no open window - a script, a
  // timer, anything headless - which is an ordinary outcome, not an error.
  //
  // Call this before dispatching the action rather than after: a sender
  // that answers by mapping a new window takes focus itself, and a
  // request that landed afterwards would pull focus back off it.
  function activateSender(notif): bool {
    if (!notif) return false
    const rows = root._ranked()
    const at = WindowMatch.matchIndex(notif, rows)
    if (at === -1) return false
    rows[at].toplevel.activate()
    return true
  }

  Component.onCompleted: Hyprland.rawEvent.connect(root.onRawEvent)
  Component.onDestruction: Hyprland.rawEvent.disconnect(root.onRawEvent)

  function onRawEvent(event) {
    if (event.name !== "activewindowv2") return
    const address = event.parse(1)[0]
    if (address === "") return
    const next = root._focused.filter(entry => entry !== address)
    next.push(address)
    while (next.length > root.focusHistoryLimit) next.shift()
    root._focused = next
  }
}
