import QtQml

// Authored hooks for the "annotations" unit. Inert at construction: Boot owns
// the annotation Loader and the component handoff stays in BootLate.qml's
// annotationComponent(); this module only calls Boot's bridge and predicates.
// Sources: shell/boot/Boot.qml:1427-1429 (_annotationsReady), 1431-1439
// (_teardownAnnotations).
QtObject {
  id: root

  property var boot: null

  function resolve() { root.boot._activateAnnotations() }
  function ready() { return root.boot._annotationsReady() }
  function teardown() { root.boot._teardownAnnotations() }
}
