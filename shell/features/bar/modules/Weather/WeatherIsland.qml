pragma ComponentBehavior: Bound

import QtQuick
import qs.common
import qs.services as Core

// Weather island: the detail popup behind the bar module. Same information
// architecture as Omarchy's weather Panel (hero icon + temperature,
// editable location, feels/wind/humidity stats, forecast) but built on
// Vibranium's Island primitive with Title/BodyText typography, shared
// ZebraRow list rows and SVG icons instead of nerd-font glyphs.
//
// All state and fetching live in the Weather service (`weather`);
// this island only renders and forwards edits. Content is lazy (the
// host incubates it per show), so a closed island holds no tree.
Item {
  id: root

  // Weather service singleton (qs.services.weather); set by the module.
  property var weather: null

  // Search field text, mirrored here (island level) because the field
  // itself lives in the lazy content tree and is null while closed.
  // The module's geocode debounce reads this, never the field directly.
  property string queryText: ""

  // Fixed width of the city label / location editor swap slot (the input
  // alone). Both fill the same box, so opening the editor never reflows
  // the hero, overlaps the stats or resizes the window. The number is
  // what keeps the hero inside islandContentWidth: icon + this slot + the
  // six-metric cluster is the widest thing in the island.
  readonly property real swapSlotW: 152

  property int islandContentWidth: 380
  property int islandContentHeight: Math.ceil(body.bodyHeight) + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null

  // Real internet for the forecast areas: the watcher's optimistic
  // answer, so a first open reads online until the first poll proves
  // otherwise - the same verdict the pile and the converter read.
  readonly property bool hasInternet: Core.Connectivity.online

  // Escape in the editor: clear the query first, then leave the editor
  // back to the city label. Closing the island is the router's job, not
  // this function's: with the field unfocused the router closes first.
  function escapePressed() {
    if (root.queryText !== "") {
      root.queryText = ""
      if (root.weather) root.weather.requestGeocode("")
    } else if (root.weather && root.weather.editingLocation) {
      root.weather.cancelEditingLocation()
    }
  }

  // Focus the search field; no-op while there is no field to grab.
  function focusSearch() {
    const field = body.searchInput ? body.searchInput : null
    if (field) field.grabFocus()
  }

  function openEditor() {
    if (!root.weather) return
    root.weather.startEditingLocation()
    root.queryText = root.weather.configuredLocation
    Qt.callLater(root.focusSearch)
  }

  // Step the suggestion cursor, keeping it inside the scrolled viewport.
  // The shared reveal policy owns cursor placement: this list has no
  // smoothScroll, so the seat lands instantly. reveal() runs the
  // center-lock follow, the only shared policy that keeps the cursor
  // visible in BOTH directions - revealEnd() only ever moves down, which
  // would strand the cursor above the viewport when arrowing back up.
  // With five or fewer suggestions the content fits and both are no-ops.
  function moveSuggestion(dir) {
    const w = root.weather
    if (!w || !w.editingLocation) return
    const n = w.locationSuggestions.length
    if (n === 0) return
    w.suggestionIndex = Math.max(0, Math.min(w.suggestionIndex + dir, n - 1))
    const v = body.suggestionView ? body.suggestionView : null
    if (v) v.reveal(w.suggestionIndex, false)
  }

  // Fresh results start at the top (stableModel would otherwise preserve
  // the previous scroll position across the wholesale swap). A seat to 0
  // is the shared spelling of "park at the top" and, unlike a reveal,
  // leaves no pursuit claim behind.
  function resetSuggestionView() {
    const v = body.suggestionView ? body.suggestionView : null
    if (!v) return
    v.seatTo(0, false, "weather-suggestions")
  }

  // Content lent to the shared host: incubated on show, destroyed
  // after the close fade.
  Item {
    id: body

    anchors.fill: parent
    // Island sizes from this while the host shows it.
    readonly property real bodyHeight: column.implicitHeight
    // Alias so the island root can reach the field (ids below are
    // otherwise invisible outside this subtree).
    property alias searchInput: searchField
    // Same for the suggestion list (cursor reveal + scroll reset).
    property alias suggestionView: suggList

    // Arrow-key fallback for the suggestion list while editing; Escape
    // clears or leaves the editor. Lives on the content root so it sits
    // above the focused field in the content tree and sees exactly the
    // keys the field does not consume.
    Keys.onPressed: event => {
      if (event.key === Qt.Key_Escape) {
        root.escapePressed()
        event.accepted = true
        return
      }
      if (!(root.weather && root.weather.editingLocation)) return
      if (event.key === Qt.Key_Down) {
        root.moveSuggestion(1)
        event.accepted = true
      } else if (event.key === Qt.Key_Up) {
        root.moveSuggestion(-1)
        event.accepted = true
      }
    }

    // Pressing empty island space while the editor is open hides it
    // completely (back to the city label - the same exit as Escape,
    // without closing the island). Declared before the Column so child
    // controls receive their own presses first.
    MouseArea {
      anchors.fill: parent
      enabled: root.weather && root.weather.editingLocation
      onPressed: root.weather.cancelEditingLocation()
    }

    Column {
      id: column
      width: parent.width
      spacing: Ui.s

      // NOTE: invisible children still occupy space in a Column, so
      // every conditional block below collapses its height when hidden.

      // NOTE: invisible children still occupy space in a Column, so
      // every conditional block below collapses its height when hidden.
      // Icon/Text paint at implicit* sizes (see Weather.qml), so size
      // math reads implicit* properties throughout. heroLeft never reaches
      // the stats: its width is capped at the stats' left edge, and the
      // label/editor share one fixed swap slot inside it.
      Item {
        // Offline the hero yields to the notice below: no city, no
        // number, no stale stats - and the explicit height collapses
        // with the flag, since a set height never follows visibility.
        visible: root.hasInternet
        width: parent.width
        height: visible ? Math.max(heroLeft.height, heroStats.height) : 0

        Item {
          id: heroLeft
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(heroIcon.implicitWidth + Ui.s + root.swapSlotW,
            parent.width - heroStats.width - Ui.s)
          height: Math.max(heroIcon.implicitHeight, tempBlock.implicitHeight)

          Icon {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: root.weather && root.weather.conditionIcon !== "" ? root.weather.conditionIcon : (root.weather && root.weather.current ? "weather-overcast" : "cloud-off")
            colorKey: "foreground_0"
            // cloud-off carries its crossing slash as class="indicator", so it
            // paints red while the cloud body keeps the island foreground tone.
            accentKey: root.weather && root.weather.current ? "" : "red"
            size: 48
          }

          Column {
            id: tempBlock
            anchors.left: heroIcon.right
            anchors.leftMargin: Ui.s
            anchors.verticalCenter: parent.verticalCenter
            width: heroLeft.width - heroIcon.implicitWidth - Ui.s
            spacing: 2

            // Click to switch units. The service owns the value and the
            // write, so the whole island (readouts, hourly, 7-day) and the
            // bar label follow one toggle.
            //
            // The glyph and this number are the hero's tallest pair, and
            // the hero is what sets the island's height: trimming them
            // trims every state of the card - hourly strip, day strip or
            // verbose list - at once.
            Title {
              level: 1
              font.pixelSize: 36
              font.bold: true
              text: root.weather && root.weather.reportTempNum !== ""
                ? root.weather.reportTempNum + (root.weather.current ? root.weather.tempUnit : "") : "—"

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.weather.toggleUnits()
              }
            }

            // Swap slot: the city label and the location editor are the
            // same box (same width, same height, same position), so the
            // swap is a pure content replace with zero reflow.
            Item {
              width: parent.width
              height: 24

              // Location label: click to edit (geocoded search).
              Title {
                anchors.fill: parent
                visible: !(root.weather && root.weather.editingLocation)
                  && root.weather && root.weather.reportLocation !== ""
                level: 4
                verticalAlignment: Text.AlignVCenter
                text: root.weather ? String(root.weather.reportLocation).toUpperCase() : ""

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.openEditor()
                }
              }

              // Editor: the search field alone. InputField carries its own
              // clear affordance (clearable), so a second control parked
              // outside the box would duplicate it; committing an empty
              // query is what resets the location to auto-detect.
              Item {
                anchors.fill: parent
                visible: root.weather && root.weather.editingLocation

                InputField {
                  id: searchField
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  height: 24
                  // The write is in flight while the field greys out, so
                  // the placeholder carries the only "working" cue.
                  placeholder: root.weather && root.weather.savingLocation ? "Saving..." : "Search city"
                  enabled: !(root.weather && root.weather.savingLocation)
                  // Plain search field: native bindings win (Ctrl-A
                  // selects all) instead of the library's readline keys.
                  emacsKeys: false
                  text: root.queryText
                  onEdited: text => {
                    root.queryText = text
                    root.weather.requestGeocode(text)
                  }
                  onAccepted: text => root.weather.commitLocation(text, root.weather.locationSuggestions, root.weather.suggestionIndex)
                  onEscaped: root.escapePressed()

                  // Suggestion navigation while the field owns focus
                  // (the island-level Keys handler only sees keys the
                  // field does not consume).
                  Keys.onPressed: event => {
                    if (event.key === Qt.Key_Down) {
                      root.moveSuggestion(1)
                      event.accepted = true
                    } else if (event.key === Qt.Key_Up) {
                      root.moveSuggestion(-1)
                      event.accepted = true
                    }
                  }
                }
              }
            }
          }
        }

        // Stats cluster, parked right: two rows of cap/value pairs. The hero
        // left is nearly twice the height of one row, so the metrics fill
        // the space under the first three instead of leaving the right
        // side of the hero half empty.
        //
        // A Grid, not two Rows: a positioner sizes each column to the
        // widest cell in it, so FEELS/PRESS, WIND/CLOUD and HUMID/RAIN
        // share one left edge down the card. Two Rows would each size
        // themselves, the second row would hang off the same right anchor
        // a few pixels further left, and the caps would read as six loose
        // words instead of three aligned columns. A metric the source did
        // not report collapses to zero width, so a partial payload never
        // leaves a bare cap (or a cap over an empty value) behind.
        Grid {
          id: heroStats
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          columns: 3
          // Tighter than the card rhythm: a grid column already carries
          // the slack of its widest cell, so the gap between columns only
          // has to read as a gap, not as a second one.
          columnSpacing: Ui.m
          rowSpacing: Ui.m

          Column {
            width: visible ? implicitWidth : 0
            visible: (root.weather ? root.weather.reportFeels : "") !== ""
            spacing: 2
            Title { level: 2; text: "FEELS" }
            Title {
              level: 3
              text: root.weather ? root.weather.reportFeels : ""
            }
          }

          Column {
            width: visible ? implicitWidth : 0
            visible: (root.weather ? root.weather.reportWind : "") !== ""
            spacing: 2
            Title { level: 2; text: "WIND" }
            Title {
              level: 3
              text: root.weather ? root.weather.reportWind : ""
            }
          }

          Column {
            width: visible ? implicitWidth : 0
            visible: (root.weather ? root.weather.reportHumidity : "") !== ""
            spacing: 2
            Title { level: 2; text: "HUMID" }
            Title {
              level: 3
              text: root.weather ? root.weather.reportHumidity : ""
            }
          }

          Column {
            width: visible ? implicitWidth : 0
            visible: (root.weather ? root.weather.reportPressure : "") !== ""
            spacing: 2
            Title { level: 2; text: "PRESS" }
            Title {
              level: 3
              text: root.weather ? root.weather.reportPressure : ""
            }
          }

          Column {
            width: visible ? implicitWidth : 0
            visible: (root.weather ? root.weather.reportCloud : "") !== ""
            spacing: 2
            Title { level: 2; text: "CLOUD" }
            Title {
              level: 3
              text: root.weather ? root.weather.reportCloud : ""
            }
          }

          Column {
            width: visible ? implicitWidth : 0
            visible: (root.weather ? root.weather.reportPrecip : "") !== ""
            spacing: 2
            Title { level: 2; text: "RAIN" }
            Title {
              level: 3
              text: root.weather ? root.weather.reportPrecip : ""
            }
          }
        }
      }

      // ---- geocoding suggestions: the shared library list ----
      // stableModel swaps the rows wholesale without teleporting the
      // view (exactly what a live search list needs); delegates are the
      // shared ZebraRow (square, hoverable, keyboard cursor highlight).
      // All matches show: ~5 rows visible, the rest under the wheel.
      // The scrollbar rides a reserved 6px lane so it never covers text
      // (the ArchUpdates lesson).
      Item {
        width: parent.width
        height: visible ? suggList.height : 0
        visible: root.weather && root.weather.editingLocation
          && !root.weather.savingLocation && root.weather.locationSuggestions.length > 0

        List {
          id: suggList
          // The cursor lives in suggestionIndex (painted by ZebraRow),
          // not in currentIndex: the shared highlight bar would sit on
          // the first suggestion forever.
          selectionHighlight: false
          width: parent.width - 6
          height: Math.min(contentHeight, 5 * 34)
          stableModel: root.weather ? root.weather.locationSuggestions : []
          spacing: 0
          interactive: contentHeight > height
          delegate: Item {
            id: sug
            required property var modelData
            required property int index
            width: ListView.view ? ListView.view.width : 300
            height: 34

            ZebraRow {
              anchors.fill: parent
              rowIndex: sug.index
              selected: root.weather && sug.index === root.weather.suggestionIndex
              hoverCursor: true
              hoverable: true
              onClicked: root.weather.pickSuggestion(sug.modelData)
            }

            Title {
              id: sugName
              anchors.left: parent.left
              anchors.leftMargin: Ui.s
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, 220)
              level: 3
              text: sug.modelData.name
            }

            Title {
              anchors.left: sugName.right
              anchors.leftMargin: 4
              anchors.right: parent.right
              anchors.rightMargin: Ui.s
              anchors.verticalCenter: parent.verticalCenter
              level: 4
              visible: text !== ""
              text: sug.modelData.description
            }
          }
        }

        ScrollBar {
          flickable: suggList
          anchors.top: suggList.top
          anchors.bottom: suggList.bottom
          anchors.right: parent.right
          anchors.rightMargin: 1
          thickness: 3
        }
      }

      BodyText {
        width: parent.width
        // No height collapse binding: the parent Column already excludes
        // invisible children, and height<->implicitHeight edges trip the
        // engine's loop detector (see the details Title below).
        visible: !(root.weather && root.weather.current) && root.hasInternet
        text: "Fetching forecast..."
      }

      // Offline placeholder: the crossed wifi glyph plus the message in
      // place of every forecast area while the link is dark. A fetch
      // behind a dead link can only fail, so the lists yield rather than
      // showing stale days or spinning forever on "Fetching".
      Column {
        width: parent.width
        spacing: Ui.s
        visible: !root.hasInternet

        Item {
          width: parent.width
          height: Math.max(offIcon.height, offText.implicitHeight)

          Icon {
            id: offIcon

            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            name: "wifi-off"
            colorKey: "foreground_1"
            // Red crossing line, dimmed body: the bar module's own
            // wifi-off treatment for the same dead link.
            accentKey: "red"
            size: 28
          }

          Column {
            id: offText

            anchors.left: offIcon.right
            anchors.leftMargin: Ui.s
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Title {
              width: parent.width
              level: 3
              text: "No internet connection"
            }

            Title {
              width: parent.width
              level: 4
              color: Ui.tint("foreground_1", 0.45)
              text: "Forecast will load when you're back online."
            }
          }
        }
      }

      // ---- hourly forecast: one mini cell per sampled hour - icon,
      // hour, temp. The service hands over a two-hour cadence, not every
      // hour. The cells are sized to what they print and the row is
      // centred: stretching them across the card turns every entry into a
      // column of empty card, and the gaps between entries grow with
      // every entry dropped, which is the opposite of what a shorter list
      // should look like. Open-meteo only (no timezone-safe wttr series),
      // so the row collapses on the fallback and the 7-day strip alone
      // renders under the divider.
      //
      // The box carries the row's top margin: the cells sit at its bottom,
      // so the strip starts clear of the hero above instead of hanging off
      // it. The margin is inside the box, so the fallback that hides the row
      // takes the space with it.
      Item {
        width: parent.width
        height: visible ? Ui.s + hourRow.height : 0
        visible: root.hasInternet && root.weather && root.weather.hourlyForecast.length > 0

        Row {
          id: hourRow
          anchors.horizontalCenter: parent.horizontalCenter
          anchors.bottom: parent.bottom
          spacing: Ui.s

          Repeater {
            id: hourRepeater
            model: root.weather ? root.weather.hourlyForecast : []

            Item {
              id: hourCell
              required property var modelData
              // As wide as the widest thing in the cell, with a floor so a
              // short label ("6:00") still gets a cell that reads as a
              // column rather than a word.
              width: Math.max(hourCol.implicitWidth, 44)
              height: hourCol.implicitHeight

              Column {
                id: hourCol
                width: parent.width
                spacing: 2

                Icon {
                  anchors.horizontalCenter: parent.horizontalCenter
                  name: root.weather.hourIcon(hourCell.modelData)
                  colorKey: "foreground_0"
                  size: 20
                }

                Title {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  level: 4
                  text: root.weather.hourLabel(hourCell.modelData)
                }

                Title {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  level: 3
                  text: root.weather.hourTemp(hourCell.modelData)
                }
              }
            }
          }
        }
      }

      Divider {
        width: parent.width
        height: visible ? 1 : 0
        visible: root.hasInternet && root.weather && root.weather.forecastDays.length > 0 && root.weather.verbose
      }

      // ---- 7-day forecast: full-width zebra rows with a per-day
      // details line (feels/wind/humidity/rain), verbose only.
      // Non-verbose shows the hero and the hourly strip only; the
      // divider above goes with the list.
      Column {
        width: parent.width
        // Same: no collapse binding, the outer Column excludes this while
        // invisible (see above).
        visible: root.hasInternet && root.weather && root.weather.forecastDays.length > 0 && root.weather.verbose
        spacing: 0

        Repeater {
          model: (root.weather && root.weather.verbose) ? root.weather.forecastDays : []

            Item {
              id: cell
              required property var modelData
              required property int index
              width: parent.width
              // Sized to what the row paints - the glyph or the two-line text
              // stack, whichever is taller - plus the standard row padding.
              // A literal height leaves the content floating in a slab of
              // void, and a day with no details line still pays for two lines.
              height: dayBody.height + 2 * Ui.rowPadV

            readonly property string details: root.weather ? root.weather.dayDetailsLine(cell.modelData) : ""

            ZebraRow {
              anchors.fill: parent
              rowIndex: cell.index
              interactive: false
            }

            Item {
              id: dayBody
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 2 * Ui.s
              height: Math.max(dayIcon.height, dayText.implicitHeight)

              Icon {
                id: dayIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                name: root.weather.dayIcon(cell.modelData)
                colorKey: "foreground_0"
                size: 24
              }

              Column {
                id: dayText
                anchors.left: dayIcon.right
                anchors.leftMargin: Ui.s
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                // Single-pixel leading: the range now rides the name line, so
                // this gap is the only thing separating the day's headline
                // from its muted detail, and the row's height follows it.
                spacing: 1

                // Day, then the day's range on the same line: the name is
                // what identifies the row and the range belongs to it, so
                // they read together and the eye is not asked to jump to
                // the far edge for the one number that qualifies the day.
                //
                // Day and night temperatures sharing one muted tone with
                // the detail line below, dot-separated in its language.
                Row {
                  width: parent.width
                  spacing: Ui.s

                  Title {
                    id: dayName
                    level: 4
                    text: root.weather.dayName(cell.modelData.date).toUpperCase()
                  }

                  Row {
                    spacing: 2

                    Title {
                      level: 4
                      color: Ui.tint("foreground_1", 0.45)
                      text: root.weather.bareTempForDay(cell.modelData, "max")
                    }

                    Title {
                      level: 4
                      color: Ui.tint("foreground_1", 0.45)
                      text: "·"
                    }

                    Title {
                      level: 4
                      color: Ui.tint("foreground_1", 0.45)
                      text: root.weather.bareTempForDay(cell.modelData, "min")
                    }
                  }
                }

                Title {
                  width: parent.width
                  // No `height: visible ? implicitHeight : 0` here: that
                  // edge trips the loop detector. The Column already skips
                  // invisible children, so the collapse is not this row's
                  // to do.
                  visible: cell.details !== ""
                  level: 4
                  color: Ui.tint("foreground_1", 0.45)
                  text: cell.details
                }
              }
            }
          }
        }
      }
    }
  }

  Connections {
    target: root.weather
    enabled: root.weather !== null
    function onLocationSuggestionsChanged() { root.resetSuggestionView() }
  }

  // Refresh on every show: the content is incubated fresh, so
  // creation is open. Focus target for the suggestion-navigation Keys
  // handlers above (the Clock island focuses its content the same way).
  // Teardown exits an open location editor, back to the city label.
  //
  // A show is a user open, not a boot construction: IslandHost keeps the
  // content Loader inactive while the island is closed, so the cycle started
  // here is one the user asked for and reports as one.
  Component.onCompleted: {
    if (root.weather) {
      root.weather.refresh("user")
      Qt.callLater(() => body.forceActiveFocus())
    }
  }
  Component.onDestruction: {
    if (root.weather && root.weather.editingLocation) root.weather.cancelEditingLocation()
  }
}
