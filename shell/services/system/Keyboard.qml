pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.common

// Authoritative Hyprland keyboard state: the caps lock flag and the active
// layout, queried from the compositor request socket whenever a consumer
// needs ground truth (dialog opening, session locking, boot). Between syncs
// the values drift only by keys pressed on our own surfaces, which report
// through toggleCaps(); the next sync re-anchors to reality either way.
//
// Keyboard state comes from the hyprland request socket (j/devices);
// SplitParser hands back lines, so the reply is buffered until it parses.
Singleton {
  id: root

  readonly property string tag: "keyboard"

  property bool capsOn: false
  property string layout: ""
  property int layoutCount: 0

  // Reply buffer for the in-flight j/devices request.
  property string deviceBuf: ""

  Component.onCompleted: {
    root.sync()
  }

  function sync() {
    if (Hyprland.requestSocketPath === "") return
    root.deviceBuf = ""
    devicesSocket.connected = true
  }

  // Key-level delta reported by focused surfaces between authoritative
  // syncs; CapsLock key events carry no absolute state on Wayland.
  function toggleCaps() {
    root.capsOn = !root.capsOn
  }

  function feedDevices(line) {
    root.deviceBuf += line + "\n"
    let data
    try {
      data = JSON.parse(root.deviceBuf)
    } catch (e) {
      return // reply still incomplete
    }
    root.deviceBuf = ""
    devicesSocket.connected = false
    const kbs = data.keyboards ?? []
    if (kbs.length === 0) return
    let caps = false
    for (const kb of kbs) caps = caps || kb.capsLock === true
    root.capsOn = caps
    root.layout = kbs[0].active_keymap ?? ""
    root.layoutCount = (kbs[0].layout ?? "").split(",").filter(part => part.trim() !== "").length
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
      if (sep !== -1) root.layout = event.data.slice(sep + 1)
    }
  }
}
