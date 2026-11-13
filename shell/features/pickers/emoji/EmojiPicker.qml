pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../../common/text/UnitIpc.js" as UnitIpc

// Emoji picker service. The entry page lists the face emojis only; the
// rest of the set sits on a second page that no row links to, so it is
// reachable through search alone. The bundle at emojis.jsonc carries both
// pages and is opened on demand by `menu toggleFile`, which parses and
// caches it; this unit names the bundle and answers IPC, so a session that
// never picks an emoji parses nothing. No usage tracking, no dynamic
// shadowing.
Singleton {
  readonly property string tag: "emojiPicker"

  Component.onCompleted: {
    Registry.offer("emojiPicker", {
      title: "Emoji picker",
      description: "emoji picker",
      verbNames: [
        "status",
        "help",
        "ping",
      ]
    })
  }

  IpcHandler {
    target: "emojiPicker"

    function help(command: string): string {
      return UnitIpc.help("emojiPicker", "Emoji picker", "emoji picker", [
      ], command)
    }
    function status(): string {
      return JSON.stringify({ unit: "emojiPicker", healthy: true })
    }
    function ping(): string { return "pong" }
  }
}
