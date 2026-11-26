// Whole QtObject so the narrow extractor reads it through the same entry point
// it uses on a provider file. The function-looking text is inside a comment.
import QtQml

QtObject {
  property var handlers: ({
    "nullComment": {
      resolve: function() { void NullComment.tag },
      // ready: function() { return NullComment.facadeReady === true },
      teardown: null
    }
  })
}
