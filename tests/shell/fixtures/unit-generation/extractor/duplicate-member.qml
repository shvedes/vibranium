import QtQml

QtObject {
  property var handlers: ({
    "duplicated": {
      resolve: function() { void Duplicated.tag },
      ready: function() { return true },
      ready: function() { return false },
      teardown: null
    }
  })
}
