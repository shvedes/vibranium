pragma Singleton

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../text/UnitIpc.js" as UnitIpc

// System GTK font provider for the entire shell.
// One source record wins: gsettings (GNOME, rank 0), gtk-4.0 settings.ini
// (rank 1), gtk-3.0 settings.ini (rank 2), with "Sans 11" as the floor. Arrival
// order cannot demote a better source: a late ini write never clobbers a
// gsettings font, and a late gsettings answer still takes over from ini.
// The ini files are watched live via FileView; gsettings is probed once at boot
// (a mid-session gsettings change needs a shell restart). A periodic re-poll
// would be pure process churn - ~17k forks a day for a rarely changed setting.
Singleton {
  id: root

  readonly property string tag: "systemFont"

  // One writer: _offer. Lower rank wins; 99 is the "no answer yet" floor.
  property var _fontSource: ({ rank: 99, raw: "Sans 11" })

  // The three public values are derivations of that one record.
  readonly property string raw: root._fontSource.raw
  readonly property var _fontParsed: _parse(root._fontSource.raw)
  readonly property string family: root._fontParsed.family
  readonly property int pointSize: root._fontParsed.pointSize

  // Offer one font string. Rank 0 = gsettings, 1 = gtk4, 2 = gtk3. An empty
  // answer is ignored without spending the rank; only a strictly better rank
  // replaces the current winner.
  function _offer(rank, value) {
    const s = String(value || "").trim().replace(/^'|'$/g, "").replace(/^"|"$/g, "")
    if (s === "") return
    if (rank >= root._fontSource.rank) return
    root._fontSource = { rank: rank, raw: s }
  }

  // Pure "<family> <size>" split; family may contain spaces. Local to this
  // file because no other reader parses a GTK font string.
  function _parse(value) {
    const s = String(value || "").trim()
    const m = s.match(/^(.+)\s+(\d+(?:\.\d+)?)$/)
    if (m) {
      const sz = parseFloat(m[2])
      return { family: m[1].trim(), pointSize: (!isNaN(sz) && sz > 0) ? Math.round(sz) : 11 }
    }
    return { family: s, pointSize: 11 }
  }

  // gsettings is the primary probe; ini files are the fallback. Direct argv:
  // the newline strip and trim happen in the collector handler below.
  Process {
    id: gsettingsProc
    command: ["gsettings", "get", "org.gnome.desktop.interface", "font-name"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const out = String(text || "").replace(/\n/g, "").trim()
        if (out !== "" && out.indexOf("No such") < 0) {
          root._offer(0, out)
        } else {
          // gsettings has no answer: publish the ini fallback now.
          gtk3File.reload()
          gtk4File.reload()
        }
      }
    }
  }

  // FileView hands out its body through the text() accessor. The bare `text`
  // identifier resolves to that function object, so String(text) yields the
  // wrapper source and never matches the ini key.
  function applyIni(rank, text) {
    const m = String(text || "").match(/gtk-font-name\s*=\s*([^\n\r]+)/)
    if (m) root._offer(rank, m[1])
  }

  FileView {
    id: gtk3File
    path: Paths.configHome + "/gtk-3.0/settings.ini"
    watchChanges: true
    printErrors: false
    // loaded fires per load and not per change, so watching it alone leaves
    // the shell on the boot-time family. fileChanged carries every later
    // write, the temp-file rename from `sed -i` included, and text() still
    // holds the pre-change body when it arrives, so the reload is what
    // republishes the content for the loaded handler.
    onFileChanged: gtk3File.reload()
    onLoaded: root.applyIni(2, gtk3File.text())
  }

  FileView {
    id: gtk4File
    path: Paths.configHome + "/gtk-4.0/settings.ini"
    watchChanges: true
    printErrors: false
    onFileChanged: gtk4File.reload()
    onLoaded: root.applyIni(1, gtk4File.text())
  }

  Component.onCompleted: {
    // Public IPC surface: fixed closures over the resident native handler.
    // The router selects by catalog row ID, never by an argv-named member.
    IpcRouter.register("systemFont", root, {
      "systemFont.dump": function () { return ipc.dump() },
      "systemFont.status": function () { return ipc.status() },
      "systemFont.ping": function () { return ipc.ping() }
    })
    Registry.offer("systemFont", {
      title: "System font",
      description: "Read the system font configuration",
      verbNames: [
        "dump",
        "status",
        "help",
        "ping",
      ]
    })
    // FileView does not load on path assignment: it needs an explicit read, so
    // all three readers start here in one deferred turn. The rank gate - not
    // the load order - decides the winner, so a later rank-0 gsettings answer
    // replaces any ini answer that lands first. The watchers stay live for
    // mid-session ini writes. One callLater moves the fork past the first frame;
    // the default family is already a valid value.
    Qt.callLater(() => {
      gsettingsProc.running = true
      gtk3File.reload()
      gtk4File.reload()
    })
  }

  Component.onDestruction: IpcRouter.unregister("systemFont", root)

  // For debugging: allow `qs ipc call systemFont dump`
  IpcHandler {
    id: ipc
    target: "systemFont"
    function help(command: string): string {
      return UnitIpc.help("systemFont", "System font", "Read the system font configuration", [
        { name: "dump", help: "current font config" },
      ], command)
    }
    function status(): string {
      return JSON.stringify({ unit: "systemFont", healthy: true })
    }
    function ping(): string { return "pong" }
    function dump(): string {
      return JSON.stringify({ raw: root.raw, family: root.family, pointSize: root.pointSize })
    }
  }
}
