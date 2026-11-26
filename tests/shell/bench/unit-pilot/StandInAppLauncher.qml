// Test-only instrumented stand-in for qs.features.launcher.AppLauncher.
// Mirrors the three surfaces the generated FeaturesHandlers row touches:
// `tag`, `facadeReady` and `teardownController()`. `teardownCalls` is a probe
// read that proves the generated teardown closure actually reached the type.
pragma Singleton

import QtQml
import "../../CounterLib.js" as CounterLib

QtObject {
  id: root
  readonly property string tag: "appLauncher"
  readonly property bool facadeReady: true
  property int teardownCalls: 0

  function teardownController() { root.teardownCalls++ }

  Component.onCompleted: CounterLib.bump("appLauncher")
}
