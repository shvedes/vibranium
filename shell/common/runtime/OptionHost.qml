pragma Singleton

import Quickshell

Singleton {
  id: root

  property var _host: null

  function register(host) {
    if (!host || typeof host !== "object") return false
    if (root._host !== null && root._host !== host) return false
    root._host = host
    return true
  }

  function unregister(host) {
    if (root._host !== host) return false
    root._host = null
    return true
  }

  function replaceBoundOptions(key, choices) {
    if (!root._host || typeof root._host.replaceBoundOptions !== "function") return false
    return root._host.replaceBoundOptions(key, choices) === true
  }
}
