pragma ComponentBehavior: Bound

import Quickshell
import qs.boot

ShellRoot {
  settings.watchFiles: false

  Boot {
    // Stamped by the systemd unit (see vibranium-shell.service) so the boot
    // figures include Qt initialisation and this module's compilation. 0 when
    // the shell was started by hand; Boot then falls back to its own
    // construction, which is the old, under-reporting anchor.
    processStartedAtMs: Number(Quickshell.env("VIBRANIUM_SHELL_START_MS")) || 0
  }
}
