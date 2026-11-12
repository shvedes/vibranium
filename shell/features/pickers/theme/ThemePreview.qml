pragma ComponentBehavior: Bound

import QtQuick
import "./ThemeScan.js" as ThemeScan

// One imaginary screenshot of a desktop, drawn as a skeleton in a theme's
// own palette. There are no screenshots to show in the picker, so this is
// what a theme looks like before it is applied: a statusbar with modules,
// one master window on the left, and a system monitor over a terminal on
// the right. Nothing here is live data or real text - every line is a bar
// and every value is a rectangle - because the point is the palette, not
// the content.
//
// The windows carry no titlebars. This is a Wayland compositor's desktop,
// not a picture of three decorations: each rectangle is the application's
// own surface, so the content starts at the top edge.
//
// Everything is sized off `u`, one design unit derived from the card's
// width, so the same component reads at the big selected card and at a
// small family child without a second layout. Colors arrive as the theme's
// raw colors.list map; ThemeScan.preview() derives the surfaces from its
// background and foreground exactly the way the generated palette does.
Item {
  id: root

  // Raw colors.list map (background, foreground, accent, ...).
  property var colors: ({})
  // LIGHT from theme.info.
  property bool light: false

  readonly property var p: ThemeScan.preview(root.colors, root.light)
  readonly property real u: Math.max(0.35, root.width / 480)

  // A line height that never rounds away to nothing in a small child card.
  function line(w) {
    return Math.max(1, Math.round(w * root.u))
  }

  // Deterministic skeleton text: widths as shares of the line's own width.
  readonly property var _paragraph: [0.96, 0.90, 0.74, 0.93, 0.61, 0.84, 0.48]
  readonly property var _terminal: [
    [0.28, 0.16, 0.34],
    [0.42, 0.20],
    [0.20, 0.36, 0.14],
    [0.52, 0.18, 0.10],
    [0.34, 0.26],
    [0.24, 0.42, 0.12],
    [0.48, 0.22]
  ]
  readonly property var _graph: [0.34, 0.52, 0.41, 0.66, 0.48, 0.72, 0.58, 0.84, 0.63, 0.77, 0.55, 0.69, 0.47, 0.62, 0.74, 0.59]
  readonly property var _processes: [0.34, 0.52, 0.28, 0.43, 0.61, 0.37]
  // Bar modules are dots, not little cards: only the clock gets a text line.
  readonly property var _moduleTones: ["green", "yellow", "cyan", "muted"]

  Rectangle {
    id: surface

    anchors.fill: parent
    radius: Math.max(1, Math.round(2 * root.u))
    color: root.p.bg
    clip: true

    // ---- statusbar ---------------------------------------------------------
    // A bar, not a panel: low, unpadded, and made of workspace dots and
    // module dots. The clock is the one module that reads as text.
    Item {
      id: bar

      width: parent.width
      height: Math.max(4, Math.round(7 * root.u))

      Rectangle {
        anchors.fill: parent
        color: root.p.raised
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(1, root.line(0.35))
        color: root.p.edge
      }

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Math.round(6 * root.u)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.max(1, Math.round(2.5 * root.u))

        Repeater {
          model: 5

          delegate: Rectangle {
            id: wsDot
            required property int index

            width: Math.max(1, Math.round(2 * root.u))
            height: width
            radius: width / 2
            color: wsDot.index === 1 ? root.p.accent : root.p.faint
          }
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Math.round(6 * root.u)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Math.max(2, Math.round(4 * root.u))

        Repeater {
          model: root._moduleTones

          delegate: Rectangle {
            id: moduleDot
            required property var modelData

            width: Math.max(1, Math.round(2 * root.u))
            height: width
            radius: width / 2
            color: root.p[moduleDot.modelData]
          }
        }

        // Same outer height as the module dots, with the thin text line
        // centred inside it. A Row top-aligns its children, so a shorter
        // clock rectangle would otherwise ride above the dots' centreline.
        Item {
          width: Math.max(6, Math.round(11 * root.u))
          height: Math.max(1, Math.round(2 * root.u))

          Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: Math.max(1, root.line(1))
            radius: height / 2
            color: root.p.fg
          }
        }
      }
    }

    // ---- desktop ----------------------------------------------------------
    Item {
      id: desktop

      x: Math.round(5 * root.u)
      y: bar.height + Math.round(5 * root.u)
      width: parent.width - 2 * x
      height: parent.height - y - Math.round(5 * root.u)

      readonly property real gap: Math.max(2, Math.round(4 * root.u))
      readonly property real masterW: Math.round((width - gap) * 0.60)
      readonly property real slaveX: masterW + gap
      readonly property real slaveW: width - slaveX
      readonly property real topSlaveH: Math.round((height - gap) * 0.55)
      readonly property real bottomSlaveY: topSlaveH + gap
      readonly property real bottomSlaveH: height - bottomSlaveY

      // ---- master: a regular GUI application ------------------------------
      Rectangle {
        id: master

        width: desktop.masterW
        height: desktop.height
        color: root.p.panel
        radius: Math.max(1, Math.round(2 * root.u))
        border.width: 1
        border.color: root.p.windowEdge
        clip: true

        // Sidebar
        Rectangle {
          width: Math.round(parent.width * 0.27)
          height: parent.height
          color: root.p.bg

          Column {
            x: Math.max(3, Math.round(5 * root.u))
            y: Math.max(4, Math.round(7 * root.u))
            width: parent.width - 2 * x
            spacing: Math.max(3, Math.round(6 * root.u))

            Repeater {
              model: 6

              delegate: Item {
                id: navRow
                required property int index

                width: parent.width
                height: Math.max(2, Math.round(3 * root.u))

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(3, Math.round(3 * root.u))
                  height: width
                  radius: navRow.index === 2 ? width / 2 : 1
                  color: navRow.index === 2 ? root.p.accent : root.p.faint
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: Math.max(4, Math.round(7 * root.u))
                  anchors.right: navRow.index === 2 ? parent.right : undefined
                  anchors.verticalCenter: parent.verticalCenter
                  width: navRow.index === 2 ? parent.width - Math.round(7 * root.u) : parent.width * (0.58 + (navRow.index % 3) * 0.10)
                  height: Math.max(1, root.line(1.4))
                  radius: height / 2
                  color: navRow.index === 2 ? root.p.accent : root.p.muted
                  opacity: navRow.index === 2 ? 0.55 : 1
                }
              }
            }
          }
        }

        // Content
        Item {
          x: Math.round(parent.width * 0.27)
          y: 0
          width: parent.width - x
          height: parent.height

          Column {
            x: Math.max(4, Math.round(8 * root.u))
            y: Math.max(4, Math.round(8 * root.u))
            width: parent.width - 2 * x
            spacing: Math.max(2, Math.round(4 * root.u))

            Rectangle {
              width: Math.round(parent.width * 0.48)
              height: Math.max(2, root.line(2.2))
              radius: height / 2
              color: root.p.fg
            }

            Rectangle {
              width: Math.round(parent.width * 0.32)
              height: Math.max(1, root.line(1.3))
              radius: height / 2
              color: root.p.muted
            }

            Item { width: 1; height: Math.max(1, Math.round(2 * root.u)) }

            Row {
              spacing: Math.max(2, Math.round(4 * root.u))

              Rectangle {
                width: Math.round(parent.parent.width * 0.30)
                height: Math.max(4, Math.round(9 * root.u))
                radius: Math.max(1, Math.round(2 * root.u))
                color: root.p.accent
              }

              Rectangle {
                width: Math.round(parent.parent.width * 0.22)
                height: Math.max(4, Math.round(9 * root.u))
                radius: Math.max(1, Math.round(2 * root.u))
                color: "transparent"
                border.width: 1
                border.color: root.p.edge
              }
            }

            Item { width: 1; height: Math.max(1, Math.round(2 * root.u)) }

            Column {
              width: parent.width
              spacing: Math.max(1, Math.round(2.6 * root.u))

              Repeater {
                model: root._paragraph

                delegate: Rectangle {
                  required property var modelData

                  width: Math.round(parent.width * modelData)
                  height: Math.max(1, root.line(1.3))
                  radius: height / 2
                  color: root.p.faint
                }
              }
            }

            Item { width: 1; height: Math.max(1, Math.round(1 * root.u)) }

            Row {
              width: parent.width
              spacing: Math.max(2, Math.round(5 * root.u))

              Repeater {
                model: 2

                delegate: Rectangle {
                  id: appCard
                  required property int index

                  width: Math.round((parent.parent.width - Math.round(5 * root.u)) / 2)
                  height: Math.max(8, Math.round(26 * root.u))
                  radius: Math.max(1, Math.round(2 * root.u))
                  color: root.p.raised
                  border.width: 1
                  border.color: root.p.edge

                  Rectangle {
                    x: Math.max(2, Math.round(4 * root.u))
                    y: Math.max(2, Math.round(4 * root.u))
                    width: Math.max(3, Math.round(3 * root.u))
                    height: width
                    radius: appCard.index === 0 ? width / 2 : 1
                    color: appCard.index === 0 ? root.p.green : root.p.blue
                  }

                  Rectangle {
                    x: Math.max(2, Math.round(4 * root.u))
                    y: parent.height - Math.max(4, Math.round(9 * root.u))
                    width: Math.round(parent.width * (appCard.index === 0 ? 0.62 : 0.48))
                    height: Math.max(1, root.line(1.4))
                    radius: height / 2
                    color: root.p.muted
                  }
                }
              }
            }
          }
        }

        // The sidebar and the app content are flush with this window's own
        // edges, so they paint over the Rectangle's border. This hairline
        // rides above the children: the frame stays visible where a child
        // meets the desktop, which is what keeps the window from blending
        // into the wallpaper behind it.
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          radius: master.radius
          border.width: master.border.width
          border.color: master.border.color
          z: 10
        }
      }

      // ---- top right: a system monitor ------------------------------------
      Rectangle {
        id: monitor

        x: desktop.slaveX
        y: 0
        width: desktop.slaveW
        height: desktop.topSlaveH
        color: root.p.panel
        radius: Math.max(1, Math.round(2 * root.u))
        border.width: 1
        border.color: root.p.windowEdge
        clip: true

        // Tabs are the application's own chrome.
        Row {
          x: Math.max(3, Math.round(5 * root.u))
          y: Math.max(2, Math.round(4 * root.u))
          spacing: Math.max(2, Math.round(3 * root.u))

          Repeater {
            model: 3

            delegate: Rectangle {
              id: tab
              required property int index

              width: Math.max(8, Math.round(24 * root.u))
              height: Math.max(3, Math.round(7 * root.u))
              radius: Math.max(1, Math.round(2 * root.u))
              color: tab.index === 0 ? root.p.bg : "transparent"
              border.width: 1
              border.color: tab.index === 0 ? root.p.accent : root.p.faint

              Rectangle {
                x: Math.round((parent.width - width) / 2)
                y: Math.round((parent.height - height) / 2)
                width: Math.round(parent.width * 0.52)
                height: Math.max(1, root.line(0.9))
                radius: height / 2
                color: tab.index === 0 ? root.p.accent : root.p.faint
              }
            }
          }
        }

        Rectangle {
          x: Math.max(3, Math.round(5 * root.u))
          anchors.right: parent.right
          anchors.rightMargin: Math.max(3, Math.round(5 * root.u))
          y: Math.max(12, Math.round(15 * root.u))
          height: Math.max(1, root.line(0.8))
          color: root.p.edge
        }

        // Table rows
        Item {
          id: table

          x: Math.max(3, Math.round(5 * root.u))
          y: Math.max(16, Math.round(20 * root.u))
          width: parent.width - 2 * x
          height: parent.height - y - Math.max(10, Math.round(32 * root.u))

          Column {
            width: parent.width
            spacing: Math.max(2, Math.round(4 * root.u))

            Repeater {
              model: root._processes.length

              delegate: Item {
                id: proc
                required property int index

                width: parent.width
                height: Math.max(2, Math.round(3 * root.u))

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(1, Math.round(2 * root.u))
                  height: width
                  radius: width / 2
                  color: [root.p.accent, root.p.green, root.p.yellow, root.p.cyan, root.p.blue, root.p.red][proc.index % 6]
                }

                Rectangle {
                  anchors.left: parent.left
                  anchors.leftMargin: Math.max(3, Math.round(4 * root.u))
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.round(parent.width * root._processes[proc.index] * 0.62)
                  height: Math.max(1, root.line(1.2))
                  radius: height / 2
                  color: root.p.muted
                }

                Rectangle {
                  anchors.right: parent.right
                  anchors.rightMargin: Math.round(parent.width * 0.16)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.round(parent.width * 0.10)
                  height: Math.max(1, root.line(1))
                  radius: height / 2
                  color: root.p.faint
                }

                Rectangle {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.round(parent.width * 0.09)
                  height: Math.max(1, root.line(1))
                  radius: height / 2
                  color: root.p.green
                  opacity: 0.65
                }
              }
            }
          }
        }

        // CPU graph along the bottom.
        Item {
          id: graph

          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.margins: Math.max(3, Math.round(5 * root.u))
          height: Math.max(6, Math.round(26 * root.u))

          Repeater {
            model: root._graph.length

            delegate: Rectangle {
              required property int index

              x: Math.round(index * graph.width / root._graph.length)
              width: Math.max(1, Math.round(graph.width / root._graph.length * 0.62))
              height: Math.max(1, Math.round(graph.height * root._graph[index]))
              y: graph.height - height
              radius: 1
              color: index === root._graph.length - 1 ? root.p.accent : root.p.green
              opacity: index === root._graph.length - 1 ? 1 : 0.55
            }
          }
        }
      }

      // ---- bottom right: a terminal ---------------------------------------
      Rectangle {
        id: terminal

        x: desktop.slaveX
        y: desktop.bottomSlaveY
        width: desktop.slaveW
        height: desktop.bottomSlaveH
        color: root.p.bg
        radius: Math.max(1, Math.round(2 * root.u))
        border.width: 1
        border.color: root.p.windowEdge
        clip: true

        Column {
          x: Math.max(3, Math.round(5 * root.u))
          y: Math.max(3, Math.round(5 * root.u))
          width: parent.width - 2 * x
          spacing: Math.max(2, Math.round(3.4 * root.u))

          Repeater {
            model: root._terminal.length

            delegate: Row {
              id: termLine
              required property int index

              width: parent.width
              height: Math.max(1, root.line(1.6))
              spacing: Math.max(1, Math.round(2.5 * root.u))

              Rectangle {
                width: Math.max(2, Math.round(3 * root.u))
                height: parent.height
                radius: 1
                color: [root.p.green, root.p.accent, root.p.cyan, root.p.yellow][termLine.index % 4]
                opacity: 0.85
              }

              Repeater {
                model: root._terminal[termLine.index]

                delegate: Rectangle {
                  required property var modelData

                  width: Math.round(termLine.width * modelData * 0.72)
                  height: Math.max(1, root.line(1.2))
                  anchors.verticalCenter: parent.verticalCenter
                  radius: height / 2
                  color: modelData > 0.4 ? root.p.fg : root.p.muted
                }
              }
            }
          }

          Row {
            spacing: Math.max(1, Math.round(2.5 * root.u))

            Rectangle {
              width: Math.max(2, Math.round(3 * root.u))
              height: Math.max(1, root.line(1.6))
              radius: 1
              color: root.p.accent
            }

            Rectangle {
              width: Math.max(2, Math.round(5 * root.u))
              height: Math.max(2, root.line(1.8))
              radius: 1
              color: root.p.accent
              opacity: 0.85
            }
          }
        }
      }
    }
  }
}
