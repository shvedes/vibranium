pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower
import qs.common
import "../../../../common/power/BatteryModel.js" as Model

// The battery island: a header with the device count, then the device
// list - every UPower device with a battery, lowest charge first. Each
// row pairs the device's representative glyph (mouse, keyboard, gamepad,
// headset...) with a level battery icon in the dynamic colors, plus the
// percentage, the (dis)charging state and the charge rate while
// charging.
// Clicking a row unfolds its details dropdown with every other UPower
// field the device reports (times, rate, energy, health and the device
// facts); fields a device does not report are skipped, and a device
// with nothing extra reads "No additional information".
//
// Read-only: UPower exposes no control verbs for these devices, so rows
// carry no actions. All values bind straight onto the UPower objects -
// the daemon pushes changes over D-Bus, no polling involved.
Item {
  id: root

  property int islandContentWidth: 380
  // The card's padded body holds the content: add the outer padding to
  // the content's implicit height so nothing clips.
  property int islandContentHeight: Math.ceil(body.implicitHeight) + 2 * Ui.outerPad
  // Detail dropdowns ease their own heights; the host steps its
  // window-height Behavior aside so the window tracks them frame by
  // frame (one easing only).
  property bool islandSelfAnimating: true
  property var islandHost: null

  // Horizontal inset for each device row's content, mirroring the menu
  // entry insets so rows read like menu entries. Doubles as the
  // scrollbar gutter: the bar overlays the viewport edge (ArchUpdates
  // pattern), so rows end at this inset instead of underneath it.
  readonly property real rowPad: 6

  // --- UPower state (same filter as the bar module) ---

  readonly property var allDevices: UPower.devices ? UPower.devices.values : []

  function typeString(type): string {
    try {
      return String(UPowerDeviceType.toString(type))
    } catch (e) {
      return ""
    }
  }

  function stateString(state): string {
    try {
      return String(UPowerDeviceState.toString(state))
    } catch (e) {
      return "Unknown"
    }
  }

  // The row whose details dropdown is open (a native path when the
  // device reports one, otherwise a positional fallback). At most one
  // open at a time; clicking its row closes it again.
  property string dropdownId: ""

  function toggleRow(id) {
    root.dropdownId = root.dropdownId === id ? "" : id
  }

  // Plain per-device snapshots, lowest charge first, and the only walk of
  // the device set. The bar module's type filter is applied inline (the
  // same two rules: not the AC adapter or Unknown, and not explicitly
  // absent), so the device array is read once per change and the
  // intermediate filtered copy of it is never built. The binding reads
  // every live UPower property it projects (percentage, state, model,
  // times, energy, health), so D-Bus pushes re-evaluate it with no poll
  // timer - and the list never holds raw QObjects across device churn.
  // UPowerDevice.percentage arrives as a 0..1 fraction (probed live) -
  // Model.normalizePct turns it into real percent.
  //
  // No rowIdentity on the device list below, and this is why. The only
  // id-shaped field on a row is `dropId`, and it is a drag-and-drop id, not
  // an identity: it is the device's native path when it has one and
  // "row-" + its own position in this list when it does not, so two
  // devices without a native path collide outright and a device that gains
  // one changes key. A contested key is worse than an index key - List
  // refuses it for learning AND prunes it - so the index default stands
  // until a UPower device id is surfaced on the row.
  readonly property var rows: {
    var out = []
    for (var i = 0; i < root.allDevices.length; i++) {
      var d = root.allDevices[i]
      if (!d) continue
      if (!Model.isTrackedType(d.type, UPowerDeviceType.LinePower, UPowerDeviceType.Unknown)) continue
      if (d.isPresent === false) continue
      // The row's own position, which is what dropId's index fallback is
      // keyed on: a skipped device (the AC adapter, an absent battery)
      // must not shift the rows below it.
      var order = out.length
      var typeStr = root.typeString(d.type)
      var nativePath = String(d.nativePath || "")
      var pct = Model.normalizePct(d.percentage)
      var charging = d.state === UPowerDeviceState.Charging
      var stateLabel = Model.prettyState(root.stateString(d.state))
      var typeIcon = Model.deviceIconName(typeStr)
      out.push({
        dropId: nativePath !== "" ? nativePath : ("row-" + order),
        label: Model.deviceLabel(d.model, typeStr, nativePath),
        typeIcon: typeIcon !== "" ? typeIcon : "bluetooth",
        percentage: pct,
        charging: charging,
        stateLabel: stateLabel,
        batteryIcon: Model.batteryIconFor(pct, charging),
        batteryColor: Model.batteryColorFor(pct, charging),
        batteryAccent: Model.batteryAccentFor(pct, charging),
        subtext: Model.rowSubtext({
          percentage: pct,
          stateLabel: stateLabel,
          charging: charging,
          changeRate: Number(d.changeRate),
          timeToEmpty: Number(d.timeToEmpty),
          timeToFull: Number(d.timeToFull),
          energy: Number(d.energy),
          energyCapacity: Number(d.energyCapacity),
          healthSupported: d.healthSupported === true,
          healthPercentage: Number(d.healthPercentage)
        }),
        details: Model.detailRows({
          stateLabel: stateLabel,
          percentage: pct,
          timeToEmpty: Number(d.timeToEmpty),
          timeToFull: Number(d.timeToFull),
          changeRate: Number(d.changeRate),
          energy: Number(d.energy),
          energyCapacity: Number(d.energyCapacity),
          healthSupported: d.healthSupported === true,
          healthPercentage: Number(d.healthPercentage),
          typeLabel: typeStr,
          present: d.isPresent,
          powerSupply: d.powerSupply,
          laptopBattery: d.isLaptopBattery,
          nativePath: nativePath,
          iconName: String(d.iconName || "")
        })
      })
    }
    return Model.sortRows(out)
  }

  readonly property string headerSubtext: {
    if (root.rows.length === 0) return "No battery devices"
    if (root.rows.length === 1) {
      var s = root.rows[0]
      return String(s.label) + " - " + Math.round(Number(s.percentage)) + "%"
    }
    var low = Math.round(Number(root.rows[0].percentage))
    return root.rows.length + " devices - Lowest " + low + "%"
  }

  // --- content lent to the shared host ---
  // Incubated on show, destroyed after the close fade. The card sizes
  // from body.implicitHeight through islandContentHeight above.
      Column {
        id: body

        width: parent.width
        spacing: Ui.m

        // Header: "Battery" with the device count (or the single
        // device's charge) as subtext.
        Column {
          width: parent.width
          spacing: 2

          Title {
            level: 1
            width: parent.width
            text: "Battery"
            elide: Text.ElideRight
          }

          Title {
            level: 4
            width: parent.width
            text: root.headerSubtext
            elide: Text.ElideRight
          }
        }

        // Empty state - reachable when the last device vanishes while
        // the island is open (the bar slot collapses underneath it).
        Title {
          level: 5
          visible: root.rows.length === 0
          width: parent.width
          text: "No battery devices connected"
          wrapMode: Text.WordWrap
        }

        // --- DEVICES - one List + ScrollBar for the whole section ---
        Item {
          visible: root.rows.length > 0
          width: parent.width
          height: devicesColumn.implicitHeight

          Column {
            id: devicesColumn

            width: parent.width
            spacing: 0

            Item {
              width: parent.width
              height: 26

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Ui.s

                Icon {
                  anchors.verticalCenter: parent.verticalCenter
                  name: "battery-3"
                  colorKey: "foreground_1"
                  size: 14
                  opacity: 0.7
                }

                Title {
                  level: 2
                  anchors.verticalCenter: parent.verticalCenter
                  text: "DEVICES"
                }
              }
            }

            Item {
              width: parent.width
              height: devicesList.height

              List {
                id: devicesList

                selectionHighlight: false
                // An open dropdown is revealed through the shared
                // reveal/pursuit contract (see deviceDelegate): the claim
                // is the row index, the pursuit holds it as the slot
                // grows, so every height step eases the view instead of
                // waiting the tween out.
                pursuitAnimated: true
                width: parent.width
                height: Math.min(devicesList.contentHeight, 260)
                stableModel: root.rows
                spacing: 0
                interactive: devicesList.contentHeight > devicesList.height
                delegate: deviceDelegate

              }

              // Overlaid inside the viewport edge (ArchUpdates pattern):
              // rows already end at rowPad, so nothing runs underneath.
              ScrollBar {
                flickable: devicesList
                anchors.right: parent.right
                anchors.rightMargin: 1
                anchors.top: devicesList.top
                anchors.topMargin: 8
                anchors.bottom: devicesList.bottom
                anchors.bottomMargin: 8
                thickness: 3
                radius: RoundingPolicy.radius
              }
            }
          }
        }
      }

      // Device row delegate: representative glyph, name with the
      // battery status below, and the level battery icon in dynamic
      // colors. Clicking a row unfolds its
      // details dropdown (every UPower field the device reports); at most
      // one dropdown stays open.
      Component {
        id: deviceDelegate

        Item {
          id: row

          required property var modelData
          required property int index

          width: ListView.view ? ListView.view.width : 240
          // Base line plus the open dropdown; closed slots animate to
          // zero height, so the row tracks the motion 1:1 (see
          // DropdownSlot).
          height: baseRow.height + detailSlot.height + (row.isOpen ? Ui.m : 0)

          readonly property bool isOpen: String(row.modelData.dropId || "") !== ""
            && root.dropdownId === String(row.modelData.dropId)

          // The owning shared List, reached through the view attached
          // property. Held as var so the reveal contract is written
          // against the library, not the builtin ListView.
          readonly property var listView: row.ListView.view

          // Hand an opening dropdown to the shared reveal/pursuit
          // contract: revealEnd claims the row and seats it fully into
          // view, and the library pursuit re-aims the shared ease on every
          // height step, so the scroll tracks the dropdown 1:1 instead of
          // waiting it out. Downward only, nothing persists - a later
          // manual scroll or close is never fought, and the pursuit skips
          // while the user is dragging.
          //
          // The claim is established on open only. Height steps are the
          // library's job (it watches the claimed delegate directly), so
          // calling this per step would re-seat instantly and drop the
          // easing. Release on close so a recycled delegate never keeps a
          // claim on a row it no longer shows.
          function revealOpen() {
            const v = row.listView
            if (!v) return
            if (!row.isOpen) {
              if (v.autoRevealIndex === row.index) v.autoRevealIndex = -1
              return
            }
            v.revealEnd(row.index)
          }
          onIsOpenChanged: revealOpen()
          Component.onCompleted: Qt.callLater(revealOpen)

          // Selected (dropdown open) reads like Settings/menus: the whole
          // row - base line plus its dropdown - tints with background_2
          // instantly, not a hover wash.
          Rectangle {
            anchors.fill: parent
            color: row.isOpen ? Ui.solid("background_2")
              : (hoverArea.containsMouse ? Ui.tint("foreground_1", 0.06) : "transparent")
            radius: RoundingPolicy.radius
          }

          Item {
            id: baseRow

            width: parent.width
            height: 46

            Icon {
              id: devIcon

              anchors.left: parent.left
              anchors.leftMargin: root.rowPad
              anchors.verticalCenter: parent.verticalCenter
              name: String(row.modelData.typeIcon || "bluetooth")
              colorKey: "foreground_1"
              size: 20
            }

            Column {
              anchors.left: devIcon.right
              anchors.leftMargin: Ui.m
              anchors.right: battIcon.left
              anchors.rightMargin: Ui.m
              anchors.verticalCenter: parent.verticalCenter
              spacing: 1

              Title {
                level: 3
                width: parent.width
                text: String(row.modelData.label || "Unknown device")
                color: Ui.solid("foreground_0")
                elide: Text.ElideRight
              }

              Title {
                level: 4
                width: parent.width
                text: String(row.modelData.subtext || "")
                elide: Text.ElideRight
              }
            }

            Icon {
              id: battIcon

              anchors.right: parent.right
              anchors.rightMargin: root.rowPad
              anchors.verticalCenter: parent.verticalCenter
              name: String(row.modelData.batteryIcon || "battery-3")
              colorKey: String(row.modelData.batteryColor || "foreground_0")
              accentKey: String(row.modelData.batteryAccent || "")
              size: 26
            }
          }

          DropdownSlot {
            id: detailSlot

            anchors.top: baseRow.bottom
            topGap: Ui.m
            anchors.left: parent.left
            anchors.right: parent.right
            open: row.isOpen

            Column {
              x: Ui.m
              width: parent.width - 2 * Ui.m
              spacing: Ui.s

              Divider {
                width: parent.width
                color: Ui.tint("background_3", 0.8)
              }

              Repeater {
                model: Array.isArray(row.modelData.details) ? row.modelData.details : []

                Item {
                  required property var modelData

                  width: parent.width
                  height: Math.max(detailLabel.implicitHeight, detailValue.implicitHeight)

                  Title {
                    id: detailLabel

                    level: 4
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 130
                    text: String(modelData.label || "")
                    elide: Text.ElideRight
                  }

                  Title {
                    id: detailValue

                    level: 3
                    anchors.left: detailLabel.right
                    anchors.leftMargin: Ui.m
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(modelData.value || "")
                    horizontalAlignment: Text.AlignRight
                    elide: Text.ElideRight
                  }
                }
              }

              Title {
                level: 5
                visible: !Array.isArray(row.modelData.details) || row.modelData.details.length === 0
                width: parent.width
                text: "No additional information"
                wrapMode: Text.WordWrap
              }
            }
          }

          MouseArea {
            id: hoverArea

            anchors.fill: baseRow
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleRow(String(row.modelData.dropId || ""))
          }
        }
      }
}
