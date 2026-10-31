pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type
import QtQuick
import Quickshell
import qs.common
import qs.features.bar

// Module group container. A group occupies one slot in the bar layout (its
// key id) but renders several member modules side by side, in fixed order,
// as a single draggable unit. It carries no chrome of its own - members sit
// flush together; the slot wrapper draws the drag boundary around the whole
// group (never between members).
//
// Dragging is handled one level up on the whole slot and this container
// exposes no per-member drag surface, so a member can never be pulled out
// of its group. Members are wired to the bar for popup anchoring.
Item {
  id: root

  // Module contract: set by the slot wrapper right after instantiation and
  // forwarded to every member so islands/tooltips anchor to the bar.
  property ShellScreen barScreen: null
  property var barWindow: null

  // Which group this is; set by the slot wrapper once it knows the slot id.
  // Derives the member ids so the container never hard-codes composition.
  property string groupKey: ""
  readonly property var memberIds: root.groupKey !== "" ? Bar.groupMembers(root.groupKey) : []

  implicitWidth: membersRow.implicitWidth
  implicitHeight: Bar.height
  width: implicitWidth
  height: implicitHeight

  Row {
    id: membersRow

    anchors.centerIn: parent
    // No gap between grouped member modules, matching the zone row gaps.
    spacing: 0

    Repeater {
      model: root.memberIds

      delegate: Loader {
        required property string modelData

        // Asynchronous so one heavy member cannot stall its sibling: the
        // row adopts each member's implicit size as it arrives.
        asynchronous: true
        // No explicit size: the Loader adopts the member's own implicit
        // size (an explicit width/height would collapse the member instead).
        //
        // The construction clock lives here rather than in Zone, and that is
        // the whole reason a group is recorded as its members and never as
        // one entry of its own: the user sees `tray` and `logout` sitting
        // there. The container this file is (a Row of Loaders) is not a
        // module and is never timed.
        //
        // Open and close bracket the construction exactly as in Zone's slot
        // loader: the stamp goes into the expression that hands the
        // Component over, the close is the Loader reaching Ready.
        sourceComponent: {
          // componentFor, not the narrower static resolver: a member id is a
          // static registry id by construction (ownModule rejects any id the
          // static map or _groups already holds), so the two agree here and
          // the group container stays the single place a slot resolves.
          const comp = Bar.componentFor(modelData)
          Bar.markBuildStart(modelData, comp)
          return comp
        }
        onLoaded: {
          if (item) root.forwardMember(item, modelData)
          Bar.reportModuleReady(modelData)
        }
      }
    }
  }

  // Pass the window/screen contract down to each member (their islands and
  // popups anchor to the bar window, per monitor), plus the member's own
  // slot id for its settings-key namespace.
  function forwardMember(item, id) {
    // Duck-type check: only BarModule-typed members carry the contract (and
    // the settings-key namespace); a non-module member stays unharmed.
    if (item.barScreen !== undefined) {
      item.barScreen = root.barScreen
      item.barWindow = root.barWindow
    }
    if (item.moduleId !== undefined) item.moduleId = id
  }

  // Members can finish loading before the window/screen contract lands;
  // retarget any that were too early.
  function retargetMembers() {
    for (let i = 0; i < membersRow.children.length; i++) {
      const l = membersRow.children[i]
      if (l && l.item) root.forwardMember(l.item, l.modelData)
    }
  }
  onBarScreenChanged: root.retargetMembers()
  onBarWindowChanged: root.retargetMembers()
  onGroupKeyChanged: root.retargetMembers()
}
