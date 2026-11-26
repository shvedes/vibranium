// Probe: an emoji picker singleton finishes Component.onCompleted in a real
// offscreen Quickshell, with its registration verdict published. Bar and
// Clipboard reach a PanelWindow transitively and cannot be constructed on
// this platform; their declaration assertions live in the JS owner suites.
//
// A Bound component throws on an assignment to an undeclared property; the
// error aborts the remainder of onCompleted, which is exactly how the bar
// once rendered empty.
import QtQuick
import Quickshell
import qs.common
import qs.features.pickers.emoji

Item {
  id: probe
  width: 1
  height: 1

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  Component.onCompleted: {
    kv("emoji.verdict", EmojiPicker._ipcRegistered)
    kv("router.emoji", IpcRouter.registered("emojiPicker"))
    console.log("##DONE##")
  }
}
