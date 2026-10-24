pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common

// Wrapped quiet paragraph: row descriptions, expandable bodies, helper
// copy. Width comes from the consumer (anchors or explicit binding) per
// the layout law; height follows the wrapped text.
//
// markup=true switches to StyledText for declarative copy carrying the
// whitelisted inline tags (<b>/<i>/<u>, \n breaks via MenuLib.styledMarkup);
// plain by default so runtime strings never parse as markup.
Text {
  id: root

  property bool markup: false

  color: Ui.tint("foreground_1", 0.75)
  font.family: Ui.fontFamily
  font.pixelSize: Ui.fontS
  lineHeight: 15
  lineHeightMode: Text.FixedHeight
  wrapMode: Text.WordWrap
  textFormat: root.markup ? Text.StyledText : Text.PlainText
}
