import QtQml

// The `ready` inside the resolver body is nested and must not be counted.
QtObject {
  property var handlers: ({
    "nestedOnly": {
      resolve: function() {
        var row = { ready: function() { return true } }
        void row
      },
      ready: null,
      teardown: null
    }
  })
}
