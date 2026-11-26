import QtQml

// Authored hooks for the "bar" unit. Inert at construction: Boot owns the
// URL-loaded runtime and its generation guard, so this module only forwards
// to Boot's functions rather than reimplementing any bar logic.
// Sources: shell/boot/Boot.qml:671-681 (_mountBarRuntime), 683-690
// (_unmountBarRuntime), 1211 (bar readiness).
QtObject {
  id: root

  property var boot: null

  function resolve() { return root.boot._mountBarRuntime() }
  function ready() { return root.boot._barRuntimeItem !== null }
  function teardown() { root.boot._unmountBarRuntime() }
}
