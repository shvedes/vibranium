pragma Singleton

import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../text/UnitIpc.js" as UnitIpc

// System GTK font provider for the entire shell.
// Reads the GTK font from gsettings (GNOME) or from gtk-3.0/gtk-4.0 settings.ini,
// falling back to "Sans 11" if nothing is found. The ini files are watched live
// via FileView; gsettings itself is probed once at boot (a mid-session gsettings
// change needs a shell restart). The old 5s re-poll was pure process churn -
// ~17k forked gsettings processes per day for a setting that almost never changes.
Singleton {
  id: root

  readonly property string tag: "systemFont"

  // Raw GTK font string, e.g. "Cantarell 11" or "Noto Sans 10"
  property string raw: "Sans 11"
  property string family: "Sans"
  property int pointSize: 11

  function parseRaw(v) {
    const s = String(v || "").trim().replace(/^'|'$/g, "").replace(/^"|"$/g, "")
    if (s === "") return
    // GTK font is "<family> <size>" where family may contain spaces.
    const m = s.match(/^(.+)\s+(\d+(?:\.\d+)?)$/)
    if (m) {
      root.family = m[1].trim()
      const sz = parseFloat(m[2])
      if (!isNaN(sz) && sz > 0) root.pointSize = Math.round(sz)
      root.raw = s
    } else if (s !== "") {
      root.family = s
      root.raw = s
    }
  }

  // Try gsettings first (GNOME), then ini files. Direct argv: the old
  // `tr -d "\n"` pipe lives in JS below (newline strip plus trim).
  Process {
    id: gsettingsProc
    command: ["gsettings", "get", "org.gnome.desktop.interface", "font-name"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        const out = String(text || "").replace(/\n/g, "").trim()
        if (out !== "" && out.indexOf("No such") < 0) {
          root.parseRaw(out)
        } else {
          // Fallback to ini files
          gtk3File.reload()
          gtk4File.reload()
        }
      }
    }
  }

  // FileView hands out its body through the text() accessor. The bare `text`
  // identifier resolves to that function object, so String(text) yields the
  // wrapper source and never matches the ini key.
  function applyIni(text) {
    const m = String(text || "").match(/gtk-font-name\s*=\s*([^\n\r]+)/)
    if (m) root.parseRaw(m[1])
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
    onLoaded: root.applyIni(gtk3File.text())
  }

  FileView {
    id: gtk4File
    path: Paths.configHome + "/gtk-4.0/settings.ini"
    watchChanges: true
    printErrors: false
    onFileChanged: gtk4File.reload()
    onLoaded: root.applyIni(gtk4File.text())
  }

  Component.onCompleted: {
    Registry.offer("systemFont", {
      title: "System font",
      description: "system font config",
      verbNames: [
        "dump",
        "status",
        "help",
        "ping",
      ]
    })
    gsettingsProc.running = true
    gtk3File.reload()
    gtk4File.reload()
  }

  // For debugging: allow `qs ipc call systemFont dump`
  IpcHandler {
    target: "systemFont"
    function help(command: string): string {
      return UnitIpc.help("systemFont", "System font", "system font config", [
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
