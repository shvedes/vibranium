import QtQml

QtObject {
  property var handlers: ({
    "malformed": {
      resolve: function() { void Malformed.tag },
      ready: 42,
      teardown: null
    }
  })
}
