pragma Singleton
import QtQml
import Quickshell

Singleton {
  id: root

  signal failed(string label, string message)

  property var _pending: []
  property var _errors: []
  property bool _scheduledNextTick: false
  property bool _scheduledLaterTick: false

  function run(fn, ticks, priority, label) {
    if (typeof fn !== "function") return false
    const due = Number(ticks) >= 2 ? 2 : 1
    root._pending.push({
      fn: fn,
      ticks: due,
      label: typeof label === "string" ? label : ""
    })
    if (due >= 2) {
      if (root._scheduledLaterTick) return true
      root._scheduledLaterTick = true
      Qt.callLater(() => Qt.callLater(() => root._flush(2)))
      return true
    }
    if (root._scheduledNextTick) return true
    root._scheduledNextTick = true
    Qt.callLater(() => root._flush(1))
    return true
  }

  function _flush(due) {
    if (due >= 2) root._scheduledLaterTick = false
    else root._scheduledNextTick = false
    const entries = root._pending
    root._pending = []
    const batch = []
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].ticks === due) batch.push(entries[i])
      else root._pending.push(entries[i])
    }
    for (let i = 0; i < batch.length; i++) {
      const callback = batch[i]
      try {
        callback.fn()
      } catch (error) {
        const entry = {
          label: callback.label,
          message: root._errorMessage(error)
        }
        const errors = root._errors.concat([entry])
        root._errors = errors.length > 32 ? errors.slice(errors.length - 32) : errors
        root.failed(entry.label, entry.message)
      }
    }
  }

  function _errorMessage(error) {
    try {
      if (typeof error === "string") return error
      if (error && typeof error.message === "string") return error.message
      return String(error)
    } catch (ignored) {
      return "Unknown callback error"
    }
  }
}
