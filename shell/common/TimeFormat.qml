pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import qs.common

// The shell-wide 12/24-hour verdict. One boolean every clock in the shell
// binds instead of each reading the setting itself: the clock module owns
// the `shell.statusbar.clockFormat` option and its settings UI, and this
// is the read half - the bar clock, the notification pile, the weather
// hours and any future clock all follow one switch, so a format change
// can never leave half the shell behind.
Singleton {
  id: root

  readonly property string tag: "timeFormat"

  // True for the 12-hour dial. False covers both "24" and an unset key,
  // so a store that never wrote the option reads as 24-hour rather than
  // as a third state every consumer would have to decide on its own.
  readonly property bool use12h: Settings.value("shell.statusbar.clockFormat") === "12"
}
