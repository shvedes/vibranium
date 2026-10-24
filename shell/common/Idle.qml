pragma Singleton
import QtQml
import Quickshell
import qs.common

Singleton {
  id: root

  function run(fn, ticks, priority, label) {
    return DeferredQueue.run(fn, ticks, priority, label)
  }
}
