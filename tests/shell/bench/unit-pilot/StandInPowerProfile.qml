// Test-only instrumented stand-in for qs.services.PowerProfile.
// Mirrors the one surface the generated ServicesHandlers row touches: `tag`.
// It is installed into an isolated throwaway mirror, never into production.
pragma Singleton

import QtQml
import "../CounterLib.js" as CounterLib

QtObject {
  id: root
  readonly property string tag: "powerProfile"

  Component.onCompleted: CounterLib.bump("powerProfile")
}
