pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Standard color tween: Ui.fastMs. Drop-in for `Behavior on color`-style
// blocks; override duration per use.
ColorAnimation {
  // The same single motion gate the number tween carries; see Glide.qml for
  // why it has to be the duration and what an overriding consumer owes.
  duration: MotionPolicy.duration(Ui.fastMs)

  // No per-frame tick, and that is a fact about the type. See Glide.qml for
  // the full mechanism: neither NumberAnimation nor ColorAnimation exposes
  // `currentValue`, so there is no signal to hang a per-frame reading on and
  // no value to read.
  onStopped: {
    target = null
  }
}
