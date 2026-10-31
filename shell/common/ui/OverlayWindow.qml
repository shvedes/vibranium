pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.common

// Standardized scrim window with Overlay layer and exclusive keyboard on
// primary. Keeps WlrLayershell boilerplate out of every *View.qml.
//
// Overlay is the topmost level wlr-layer-shell has, and it is where the
// modal overlays belong: a menu, a launcher, a picker, a password panel.
// The surfaces that are not modal live below it - the notification pile on
// the Top layer, the bar on Bottom, the wallpaper on Background - so an
// open overlay covers the pile instead of the pile drawing over the
// overlay's dim.
//
// It is also the only level that outlives a fullscreen window: Hyprland
// fades the whole Top layer when a window goes fullscreen, so an overlay
// on Top would fade out under a fullscreen app, which is a surface the
// user cannot reach.
//
// The animation policy is wired here at library level: every OverlayWindow
// consumer is a MenuLib overlay (menu, launcher, power, clipboard,
// wallpaper picker, pass), so they all inherit the global switch without each
// view binding it themselves. ScrimWindow stays policy-agnostic above -
// only this wrapper binds the policy.
ScrimWindow {
  id: root

  property string wlrNamespace: ""
  property bool primary: false

  animationsEnabled: MotionPolicy.enabled

  isPrimary: root.primary
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.namespace: root.wlrNamespace
  WlrLayershell.keyboardFocus: root.primary && root.overlayOpen
    ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
}
