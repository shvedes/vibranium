pragma ComponentBehavior: Bound

import Quickshell
import qs.boot

ShellRoot {
  // Hot-reload watchers for QML files. Off unless a developer asks for them:
  // they cost one inotify registration per QML file (~230) on every boot, for
  // a feature nothing in a shipped session uses. VIBRANIUM_SHELL_WATCH=1
  // turns them on; the systemd unit pins it off.
  settings.watchFiles: Quickshell.env("VIBRANIUM_SHELL_WATCH") === "1"
  Boot {
    // Stamped by the systemd unit (see vibranium-shell.service) so the boot
    // figures include Qt initialisation and this module's compilation. 0 when
    // the shell was started by hand; Boot then falls back to its own
    // construction, which is the old, under-reporting anchor.
    processStartedAtMs: Number(Quickshell.env("VIBRANIUM_SHELL_START_MS")) || 0
  }
}
