pragma Singleton
pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQml
import Quickshell
import Quickshell.Io
import qs.common
import "../../../common/text/UnitIpc.js" as UnitIpc

// Emoji picker service. The picker is a single static list with all
// emojis as-is (no Recent / All sections). The bundle at emojis.jsonc
// carries the full set and is opened on demand by `menu toggleFile`,
// which parses and caches it; this unit names the bundle and answers IPC,
// so a session that never picks an emoji parses nothing. No usage
// tracking, no dynamic shadowing.
Singleton {
  id: root

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
