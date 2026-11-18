pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import qs.common

// The shell-wide 12/24-hour verdict. One boolean every clock in the shell
// binds instead of each reading the setting itself: the `shell.time.format`
// option lives under Settings > General, and this is the read half - the bar
// clock, the statusbar islands, the notification pile, the weather hours and
// the lockscreen all follow one switch, so a format change can never leave
// half the shell behind.
Singleton {
  readonly property string tag: "timeFormat"

  // True for the 12-hour dial. False covers both "24" and an unset key,
  // so a store that never wrote the option reads as 24-hour rather than
  // as a third state every consumer would have to decide on its own.
  readonly property bool use12h: Settings.value("shell.time.format") === "12"
}
