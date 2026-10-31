pragma ComponentBehavior: Bound

import QtQuick
import qs.common

// Card: the canonical popup-surface chrome shared by qs.common consumers
// (Island, future module popups, notices). A themed rectangle with the
// standard outer padding, so every popup reads identically.
//
// Needs a host that sizes it, e.g. an Island parks it next to a bar
// module. Content intended to wear the standard inset should be placed in
// the padded content box - hosts forward their declared content into it,
// e.g. an Island does
//   default property alias content: card.contentArea.data
//
// (The card itself declares no `default property`, so sibling chrome like
// the capture net is not funnelled into the content body - see
// ScrimWindow for the same sibling-interception pattern.)

// A click-capture net sits beneath the host so pointers over the card
// frame and padding don't fall through to whatever surface hides behind
// the card; content still receives its own clicks. No `default property`
// on the card itself, or that net would be funnelled into the content
// body (see ScrimWindow for the sibling-interception pattern).
Rectangle {
  id: root

  color: Ui.solid("background_0")
  radius: RoundingPolicy.radius
  border.width: Ui.cardBorder
  border.color: Ui.solid("background_3")
  clip: true

  // Padded content host. Consumers forward their declared content into it.
  property alias contentArea: body

  // Capture clicks on the card frame and padding so they don't fall
  // through to a surface behind this card (e.g. an island's dismiss net).
  // Sits beneath the padded host so card content still gets its own clicks.
  property bool captureInput: true

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.AllButtons
    enabled: root.captureInput
  }

  Item {
    id: body

    anchors.fill: parent
    anchors.margins: Ui.outerPad
  }
}
