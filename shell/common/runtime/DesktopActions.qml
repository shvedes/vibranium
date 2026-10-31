pragma Singleton

import Quickshell

Singleton {
  // One uri, not a list: the bar reduces the payload through DropPayload and
  // forwards the single candidate, so the service never has to re-validate an
  // array crossing the signal. Empty uri with empty error is the invalid
  // payload the service reports.
  signal wallpaperDrop(string uri, string screen, string error)
}
