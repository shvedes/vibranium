// Native IpcHandler stand-in for Boot.qml's `time()` verb. It is installed in
// a throwaway offscreen config and called through `qs ipc call boot time`.
// The body is the same constant projection Boot's handler uses; a static
// assertion in the suite ties this stand-in to the real handler source.
import QtQuick
import Quickshell
import Quickshell.Io

Item {
  Component.onCompleted: console.log("##NATIVE-READY##")

  IpcHandler {
    target: "boot"
    function time(): string { return Quickshell.env("BOOT_TRACE_FROZEN_REPORT") }
  }
}
