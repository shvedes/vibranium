pragma ComponentBehavior: Bound

import Quickshell
import qs.boot

ShellRoot {
  // Hot-reload watchers for QML files. VIBRANIUM_SHELL_WATCH=0 disables
  // them (production: one inotify registration per file otherwise).
  settings.watchFiles: Quickshell.env("VIBRANIUM_SHELL_WATCH") !== "0"
  Boot {}
}
