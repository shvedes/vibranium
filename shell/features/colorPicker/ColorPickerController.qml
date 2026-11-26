pragma Singleton

import QtQml
import QtQuick
import Quickshell
import qs.common
import "../bar/BarIpc.js" as BarIpc

// Resident owner of the standalone color-picker gateway and its one active
// seat. The bar module is only a caller: it hands in its screen and island
// format, and the sampler session stays with the module that owns its scene
// graph. No visual bar type is imported here.
Singleton {
  id: root

  readonly property string tag: "colorPicker"

  property var owner: null
  property var fallback: null
  property var activePicker: null
  property var session: null
  property int generation: 0
  property var _pendingSession: false

  function registerPicker(picker) {
    if (!picker) return false
    root.owner = picker
    return true
  }

  function unregisterPicker(picker) {
    if (root.owner !== picker) return false
    root.owner = null
    return true
  }

  function registerFallbackPicker(picker) {
    if (!picker) return false
    root.fallback = picker
    return true
  }

  function unregisterFallbackPicker(picker) {
    if (root.fallback !== picker) return false
    root.fallback = null
    return true
  }

  function claimActivePicker(picker) {
    if (!picker) return false
    if (root.activePicker && root.activePicker !== picker
      && typeof root.activePicker.cancelPick === "function") {
      root.activePicker.cancelPick()
    }
    root.activePicker = picker
    return true
  }

  function clearActivePicker(picker) {
    if (root.activePicker !== picker) return false
    root.activePicker = null
    return true
  }

  function _invalidateSession() {
    root.generation++
    root._pendingSession = false
  }

  // With no bar-mounted module or fallback, the picker still works: the
  // module's own overlay window carries the ScreencopyView and the 1px
  // Canvas, so a URL-loaded instance is a real scene graph without a BarView.
  function _startSession() {
    root._invalidateSession()
    const gen = root.generation
    root._pendingSession = true
    sessionLoader.active = true
    sessionLoader.setSource(Qt.resolvedUrl("../bar/modules/ColorPicker/ColorPicker.qml"), {})
    return gen
  }

  function _beginSession(surface) {
    if (!surface || typeof surface.beginPick !== "function") return false
    surface.beginPick()
    return true
  }

  function ipcPickColor() {
    if (root.activePicker) return BarIpc.silent()
    const picker = root.owner !== null ? root.owner : root.fallback
    if (!picker || typeof picker.beginPick !== "function") {
      root._startSession()
      return BarIpc.silent()
    }
    if (!picker.beginPick()) return BarIpc.fail("unavailable", "no screen to pick on")
    const gen = picker._pickGen
    if (typeof gen !== "number" || gen <= 0)
      return BarIpc.fail("unavailable", "pick did not start")
    return BarIpc.silent()
  }

  function ipcCloseColorPick() {
    const picker = root.activePicker
    if (picker && typeof picker.cancelPick === "function") picker.cancelPick()
    if (root.session !== null || root._pendingSession) {
      root._invalidateSession()
      root.session = null
      sessionLoader.active = false
      sessionLoader.source = ""
    }
    return BarIpc.silent()
  }

  function ipcColorStatus() {
    const picker = root.owner !== null ? root.owner
      : (root.fallback !== null ? root.fallback : root.session)
    let screen = ""
    if (picker) {
      if (picker.pickScreen && picker.pickScreen.name) screen = String(picker.pickScreen.name)
      else if (picker.barScreen && picker.barScreen.name) screen = String(picker.barScreen.name)
      else if (Ui.primaryScreen && Ui.primaryScreen.name) screen = String(Ui.primaryScreen.name)
    }
    return BarIpc.ok({
      available: picker !== null,
      picking: root.activePicker !== null,
      screen: screen
    })
  }

  Loader {
    id: sessionLoader
    active: false
    asynchronous: true
    onLoaded: {
      // A superseding close invalidates the load identity: retire this
      // instance without starting a pick on it.
      if (item === null || !root._pendingSession) {
        if (item) item.destroy()
        return
      }
      root._pendingSession = false
      root.session = item
      root._beginSession(item)
    }
    onStatusChanged: {
      if (status !== Loader.Error) return
      Log.warn("colorPicker: standalone session failed to load")
      root._invalidateSession()
    }
  }

  Component.onCompleted: {
    IpcRouter.register("colorPicker", root, {
      "colorPicker.pick": () => root.ipcPickColor(),
      "colorPicker.close": () => root.ipcCloseColorPick(),
      "colorPicker.status": () => root.ipcColorStatus(),
      "colorPicker.ping": () => "pong"
    })
  }

  Component.onDestruction: {
    IpcRouter.unregister("colorPicker", root)
  }
}
