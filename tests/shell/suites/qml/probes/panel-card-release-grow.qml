import QtQuick
import qs.common

// A slot release that shares its turn with a row-set change. The launcher
// reaches this when a filter is cleared while a delete confirmation is open:
// the slot claim goes away as the one-row fit is replaced by the full list,
// so the resting region the slot releases into is LARGER than the one it grew
// against. The card is sampled per turn - a one-frame jump is the bug
// whatever the end state says.

Item {
  id: root
  width: 1
  height: 1

  property int step: 0
  property real startH: -1
  property real targetH: -1
  property var heights: []

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  Item { id: host; width: 640; height: 30 }

  PanelCard {
    id: card
    parent: host
    anchors.centerIn: parent
    maxHeight: 600
    hardMaxHeight: 1200
    hasFilter: false
    bottomReserve: 10
    count: 6
    rows: [{ label: "a" }, { label: "b" }, { label: "c" },
           { label: "d" }, { label: "e" }, { label: "f" }]
    exactListH: 292
    contentHeight: 292
  }

  Timer {
    id: pump
    interval: 16
    repeat: true
    running: true
    onTriggered: {
      root.step++
      const s = root.step
      if (s === 1) {
        kv("source.grounded", Math.abs(card.restingListH - 292) < 0.5)
        card.slotOpen = true
        card.slotRegionH = 300
        kv("source.grew", Math.abs(card.listRegionH - 300) < 0.5)
        return
      }
      if (s === 2) {
        root.startH = card.height
        // The clear edge: the slot claim goes away in the same turn the
        // resting fit jumps from the filtered rows to the full list.
        card.slotOpen = false
        card.exactListH = 470
        card.contentHeight = 470
        card.slotRegionH = 470
        // cardHeight still reads the release latch here, so the destination
        // is the resting region the latch is animating towards.
        root.targetH = card.regionChromeH + card.restingListH + card.bottomReserve
        kv("source.newResting", Math.abs(card.restingListH - 470) < 0.5)
        kv("source.targetAboveStart", root.targetH > root.startH + 0.5)
        return
      }
      if (s >= 3 && s <= 12) {
        root.heights.push(card.height)
        return
      }
      if (s === 14) {
        kv("probe.error", "none")
        kv("trace.h", root.heights.join(","))
        kv("frame.firstMoved", root.heights.length > 0
          && root.heights[0] > root.startH + 0.5
          && root.heights[0] < root.targetH - 0.5)
        kv("frame.intermediate", root.heights.some((h) => h > root.startH + 0.5
          && h < root.targetH - 0.5))
        kv("frame.neverOvershot", root.heights.every((h) => h <= root.targetH + 0.5))
        kv("frame.landed", Math.abs(card.height - root.targetH) < 0.5)
        console.log("##DONE##")
        pump.stop()
      }
    }
  }
}
