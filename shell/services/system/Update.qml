pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import Quickshell
import Quickshell.Io
import qs.common

// Vibranium update indicator. Watches `$VIBRANIUM_STATE/update.available`,
// written by the vibranium-update timer (vb-update-fetch) when a newer
// version exists, and publishes the `update.available` bus topic for the
// bar module that mirrors it. The file stays the bash bridge (fetch
// writes it, vb-update deletes it, vb-version reads it); the shell
// mirrors its content into the shared shell.jsonc "update" section so
// shell-owned state lives in one file. No IPC surface and no settings
// toggle.
Singleton {
  id: root

  readonly property string tag: "update"

  // Content of update.available. "41" (branch behind) or "v1.2.3" (new
  // tag); "" means no update pending.
  property string info: ""

  readonly property bool available: root.info !== ""

  // The bar module's three tooltip lines, as plain text.
  readonly property string tooltipText: {
    if (root.info === "") return ""
    const detail = /^[0-9]+$/.test(root.info)
      ? "Commits behind: " + root.info
      : "New version: " + root.info
    return "Vibranium update available!\n" + detail + "\nClick here to update"
  }

  // Bar-module mirror surface: the features/bar/modules/Update module
  // re-sources its state from this topic (Bus.latest replays it on
  // creation, so a late-loading module is correct on frame one).
  function _publish() {
    Bus.publish("update.available", {
      info: root.info,
      available: root.available,
      tooltipText: root.tooltipText
    })
  }
  // Deferred past the notification cascade: the payload reads the
  // `available`/`tooltipText` bindings over `info`, which re-evaluate
  // only after change handlers run. Publishing synchronously would send
  // the previous step's values, so a deleted marker would keep
  // available:true on the bus and the bar icon stuck on screen.
  onInfoChanged: Qt.callLater(() => root._publish())

  property var _watchUnsub: null

  Component.onCompleted: {
    Registry.register(root.tag, root)
    // Mirror target in shell.jsonc; the bridge file remains canonical
    // for the bash tools, the section is the shell-side copy.
    ShellState.section("update")
    // Initial probe, then the watcher keeps it live.
    root._refresh()
    root._publish()
    Qt.callLater(() => {
      root._watchUnsub = Watch.subscribe(Paths.vibraniumState + "/update.available", (text) => {
        root._refresh()
      })
    })
  }
  Component.onDestruction: {
    if (root._watchUnsub) root._watchUnsub()
    Registry.unregister(root.tag)
  }

  // Parked prober: waitForJob() fails when the file is absent (the
  // Recording / CursorPicker pattern), so a missing file reads as idle.
  FileView {
    id: probeFile
    printErrors: false
  }

  function _readInfo(): string {
    probeFile.path = ""
    probeFile.path = Paths.vibraniumState + "/update.available"
    if (!probeFile.waitForJob()) return ""
    return probeFile.text().trim()
  }

  function _refresh() {
    const info = root._readInfo()
    if (info !== root.info) {
      root.info = info
      ShellState.setSection("update", { info: info })
    } else {
      // Keep the mirror present even when the file was already idle at
      // boot (section owned from the first run).
      const sec = ShellState.section("update")
      if (!sec || sec.info === undefined) ShellState.setSection("update", { info: info })
    }
  }
}
