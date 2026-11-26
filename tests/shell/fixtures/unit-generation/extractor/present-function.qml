import QtQml

QtObject {
  property var handlers: ({
    "liveFacade": {
      resolve: function() { void LiveFacade.tag },
      ready: function() { return LiveFacade.facadeReady === true },
      teardown: function() { LiveFacade.teardownController() }
    }
  })
}
