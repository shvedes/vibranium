// Probe: modules/Downloader/DownloaderIsland.qml - the idle Recent pane.
// The island has no window dependency, so it can be built under offscreen and
// its state read directly. The history rows are synthetic; no CLI runs.

import QtQuick
import qs.features.bar.modules.Downloader

Item {
  id: probe

  width: 380
  height: 600

  property var island: null

  function kv(key, value) {
    console.log("##KV## " + key + "=" + value)
  }

  function findNamed(node, name) {
    if (!node) return null
    if (node.objectName === name) return node
    const kids = node.children || []
    for (let i = 0; i < kids.length; i++) {
      const hit = findNamed(kids[i], name)
      if (hit) return hit
    }
    return null
  }

  Component {
    id: islandComp

    DownloaderIsland {}
  }

  Component.onCompleted: {
    // Start with a remembered URL so construction does not auto-paste the
    // host clipboard, then clear it to reach the real idle state.
    const isl = islandComp.createObject(probe, {
      initialUrl: "https://example.com/",
      initialKind: "unknown",
      initialTool: "auto"
    })
    if (!isl) {
      console.log("##DONE##")
      return
    }
    probe.island = isl
    isl.clearAll()

    isl.history = []
    isl.formats = []
    isl.loadingInfo = false
    isl.playlist = []
    isl.kind = "unknown"
    isl.tool = "auto"
    kv("empty.showHistory", isl._showHistory)
    kv("empty.historyEmpty", isl._historyEmpty)
    kv("empty.icon", isl._historyEmptyIcon)
    kv("empty.text", isl._historyEmptyText)

    // A media row and a direct-file row are both ordinary Recent entries.
    isl.history = [{
      title: "Clip",
      size: "1",
      path: "/tmp/clip.mp4",
      url: "https://youtu.be/a",
      format: "137"
    }]
    kv("media.showHistory", isl._showHistory)
    kv("media.historyEmpty", isl._historyEmpty)
    kv("media.engine", isl.history.length > 0 ? "yt-dlp" : "")

    isl.history = [{
      title: "Report",
      size: "2",
      path: "/tmp/report.pdf",
      url: "https://example.com/report.pdf",
      format: "wget"
    }]
    kv("file.showHistory", isl._showHistory)
    kv("file.historyEmpty", isl._historyEmpty)
    kv("file.engine", isl.history.length > 0 ? isl.history[0].format : "")

    isl.history = []
    isl.loadingInfo = true
    kv("loading.showHistory", isl._showHistory)
    isl.loadingInfo = false

    isl.playlist = [{ url: "https://youtu.be/b", title: "B" }]
    kv("playlist.showHistory", isl._showHistory)
    isl.playlist = []

    isl.formats = [{ id: "137" }]
    kv("formats.showHistory", isl._showHistory)
    isl.formats = []

    // A typed URL with no history is not the idle pane: the format area owns
    // that state, and an error above explains a failed fetch.
    isl.initialUrl = "https://example.com/page"
    isl.initialKind = "unknown"
    isl.initialTool = "auto"
    isl.restore()
    kv("typed.showHistory", isl._showHistory)

    // The unknown-link warning is a fixed sentence, with no classifier reason
    // in parentheses, and choosing a chip answers it immediately.
    isl.classify = (url, done) => done({
      kind: "unknown",
      engine: "",
      reason: "needs content-type probe"
    })
    isl.fetchAll()
    kv("classify.warning", isl._noticeText)
    kv("classify.hasParen", isl._noticeText.indexOf("(") >= 0)
    isl.chooseTool("wget")
    kv("classify.afterChip", isl._noticeText)
    kv("classify.kind", isl.kind)

    isl.clearAll()
    kv("cleared.showHistory", isl._showHistory)

    measureTimer.start()
  }

  Timer {
    id: measureTimer
    interval: 80
    repeat: false
    onTriggered: {
      const isl = probe.island
      const list = probe.findNamed(isl, "historyList")
      const empty = probe.findNamed(isl, "historyEmpty")
      if (list && empty) {
        const listMid = list.mapToItem(isl, 0, list.height / 2)
        const emptyMid = empty.mapToItem(isl, 0, empty.height / 2)
        probe.kv("empty.listHeight", list.height)
        probe.kv("empty.centerDelta",
          Math.round(Math.abs(listMid.y - emptyMid.y)))
      } else {
        probe.kv("empty.listHeight", "missing")
        probe.kv("empty.centerDelta", "missing")
      }
      console.log("##DONE##")
    }
  }
}
