pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// Authoritative Hyprland keyboard state: the caps lock flag and the active
// layout, queried from the compositor request socket whenever a consumer
// needs ground truth (dialog opening, session locking, boot). Between syncs
// the values drift only by keys pressed on our own surfaces; the next sync
// re-anchors to reality either way.
//
// One writer per published value. capsOn/layout/layoutCount are derived views:
// the socket snapshot is one fact, local presses are a delta folded into the
// next snapshot, and a layout fact is stamped so a reply captured before an
// activelayout event cannot overwrite the newer event.
//
// Keyboard state comes from the hyprland request socket (j/devices);
// SplitParser hands back lines, so the reply is buffered until it parses.
Singleton {
  id: root

  readonly property string tag: "keyboard"

  // Writer-owned facts: feedDevices writes the caps fact and (through
  // _publishLayout) the layout fact; toggleCaps writes only the delta.
  property int pendingCapsDelta: 0
  property var _capsFact: ({ caps: false, folded: 0 })
  property var _layoutFact: ({ value: "", count: 0, gen: -1 })
  property int _layoutGen: -1
  property int _syncLayoutGen: -1

  // Published views. CapsLock is the snapshot flag with the local presses
  // not yet folded into it applied; layout and its count share one fact.
  readonly property bool capsOn: root._capsFact.caps !== ((root.pendingCapsDelta - root._capsFact.folded) % 2 !== 0)
  readonly property string layout: root._layoutFact.value
  readonly property int layoutCount: root._layoutFact.count

  // Reply buffer for the in-flight j/devices request.
  property string deviceBuf: ""

  Component.onCompleted: {
    root.sync()
  }

  function sync() {
    if (Hyprland.requestSocketPath === "") return
    root.deviceBuf = ""
    // A reply belongs to the layout generation current when it was asked.
    // An activelayout event since then has already published newer truth.
    root._syncLayoutGen = root._layoutGen
    devicesSocket.connected = true
  }

  // The one writer of the layout fact. An event carries no layout count, so
  // an omitted count keeps the count read with the last snapshot.
  function _publishLayout(value, count) {
    const prev = root._layoutFact
    root._layoutFact = {
      value: String(value ?? ""),
      count: count === undefined ? prev.count : count,
      gen: ++root._layoutGen
    }
  }

  // Key-level delta reported by focused surfaces between authoritative
  // syncs; CapsLock key events carry no absolute state on Wayland, so the
  // view applies the unfolded parity to the last snapshot.
  function toggleCaps() {
    root.pendingCapsDelta = root.pendingCapsDelta + 1
  }

  function feedDevices(line) {
    root.deviceBuf += line + "\n"
    // A j/devices reply is one JSON document across many parser lines, and the
    // only completion signal is a parse that succeeds. Attempting it per line
    // re-parsed the growing prefix once per line (quadratic in the reply), so
    // the attempt is gated on the buffer's last non-space byte closing the
    // document. Inner lines end on a key, a comma or an opener, never on a
    // closer.
    const trimmed = root.deviceBuf.replace(/\s+$/, "")
    if (trimmed === "") return
    const last = trimmed.charAt(trimmed.length - 1)
    if (last !== "}" && last !== "]") return
    let data
    try {
      data = JSON.parse(trimmed)
    } catch (e) {
      return // reply still incomplete
    }
    root.deviceBuf = ""
    devicesSocket.connected = false
    const kbs = data.keyboards ?? []
    if (kbs.length === 0) return
    let caps = false
    for (const kb of kbs) caps = caps || kb.capsLock === true
    // Fold the presses since the last snapshot into this one so a reply
    // captured before a press cannot undo it; record how many were folded
    // so a later snapshot does not apply the same press twice.
    const delta = (root.pendingCapsDelta - root._capsFact.folded) % 2 !== 0
    root._capsFact = { caps: caps !== delta, folded: root.pendingCapsDelta }
    if (root._layoutGen === root._syncLayoutGen) {
      const keymap = kbs[0].active_keymap ?? ""
      const count = (kbs[0].layout ?? "").split(",").filter(part => part.trim() !== "").length
      root._publishLayout(keymap, count)
    }
  }

  Socket {
    id: devicesSocket

    path: Hyprland.requestSocketPath
    parser: SplitParser {
      onRead: message => root.feedDevices(message)
    }

    onConnectedChanged: {
      if (!connected) return
      devicesSocket.write("j/devices")
      devicesSocket.flush()
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name !== "activelayout") return
      const sep = event.data.indexOf(",")
      if (sep !== -1) root._publishLayout(event.data.slice(sep + 1))
    }
  }
}
