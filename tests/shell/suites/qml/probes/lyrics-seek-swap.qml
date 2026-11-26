// Probe: lyrics overlay seek commit and track-swap opacity (APP-4 / APP-5).
//
// LyricsFullscreenOverlay cannot be constructed offscreen: it owns a Window and
// four MultiEffect passes, and offscreen has no compositor, no screens and no
// synthesised pointer input. So the probe reads the REAL source file with XHR
// and evaluates its OWN function and handler bodies in a headless QtObject with
// the backend-facing names stubbed (player, NP/Range math, the swap animation).
// Every machine below is the file's bytes, brace-balanced out of the source;
// a rewrite the probe no longer understands is reported by the `missing` keys
// rather than silently passing.
//
// APP-4: the four commit routes (seekAt, seekTo, drag release, wheel) must all
// funnel through ONE commitSeek that clamps, writes the player's position once,
// clears _seeking and notifies once. The shown lane is a binding on the live
// position; scrubTo is the only writer of the preview, and only while seeking.
//
// APP-5: the swap animation must own one scalar; lyricsSide.opacity is derived
// from it, and closing mid-swap resets it so reopening the SAME track (no new
// trackKey edge) cannot restore a dim transcript.
//
// Two source-side rewrites are applied to the lifted bytes, both named where
// they happen: QML identifiers cannot start upper case, so `Range.clamp(` ->
// `clamp(` and `NP.scrubPosition(` -> `scrubPosition(` against local stubs, and
// the one explicit `player.positionChanged()` in commitSeek -> `explicitNotify()`
// so the probe counts only the code's own notify, not Qt's property signal.

import QtQuick

Item {
  id: root

  width: 1
  height: 1

  property string error: ""
  property string source: ""
  property string seekMissing: ""
  property string swapMissing: ""
  property bool seekMachineBuilt: false
  property bool swapMachineBuilt: false

  function kv(key, value) {
    console.log("##KV## " + key + "=" + String(value).replace(/\n/g, "\\n"))
  }

  function safe(key, fn) {
    try {
      kv(key, fn())
    } catch (e) {
      kv(key + ".threw", "" + (e && e.message ? e.message : e))
    }
  }

  function read(path) {
    const xhr = new XMLHttpRequest()
    xhr.open("GET", path, false)
    xhr.send()
    return xhr.status === 200 ? (xhr.responseText || "") : ""
  }

  // extract() returns one whole `function name(...) { ... }` from the source.
  // Braces in strings and comments are skipped so a comment cannot close the
  // block early.
  function extract(src, name) {
    const re = new RegExp("^[ \\t]*function " + name + "\\s*\\(", "m")
    const m = re.exec(src)
    if (!m) return ""
    const open = src.indexOf("{", m.index + m[0].length - 1)
    if (open < 0) return ""
    let depth = 0
    let quote = ""
    let lineComment = false
    let blockComment = false
    for (let j = open; j < src.length; j++) {
      const ch = src[j]
      if (lineComment) { if (ch === "\n") lineComment = false; continue }
      if (blockComment) {
        if (ch === "*" && src[j + 1] === "/") { blockComment = false; j++ }
        continue
      }
      if (quote) { if (ch === "\\") { j++; continue } if (ch === quote) quote = ""; continue }
      if (ch === "/" && src[j + 1] === "/") { lineComment = true; j++; continue }
      if (ch === "/" && src[j + 1] === "*") { blockComment = true; j++; continue }
      if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
      if (ch === "{") depth++
      else if (ch === "}") {
        depth--
        if (depth === 0) return src.slice(m.index, j + 1)
      }
    }
    return ""
  }

  // handlerAfter() returns the body of `name:` found after `anchor`. It
  // handles both a brace block and a single expression.
  function handlerAfter(src, anchor, name) {
    const a = anchor === "" ? 0 : src.indexOf(anchor)
    if (a < 0) return ""
    const re = new RegExp("\\b" + name + "\\s*:", "g")
    re.lastIndex = a
    const m = re.exec(src)
    if (!m) return ""
    let i = m.index + m[0].length
    while (i < src.length && /\s/.test(src[i])) i++
    // An arrow handler (`onReleased: mouse => { ... }`) has its brace after
    // the parameter list, not right after the colon. Find that brace on the
    // same line before falling back to a single-expression handler.
    if (src[i] !== "{") {
      let j = i
      while (j < src.length && src[j] !== "\n" && src[j] !== "\r") {
        if (src[j] === "{") { i = j; break }
        j++
      }
    }
    if (src[i] === "{") {
      let depth = 0
      let quote = ""
      let lineComment = false
      let blockComment = false
      for (let j = i; j < src.length; j++) {
        const ch = src[j]
        if (lineComment) { if (ch === "\n") lineComment = false; continue }
        if (blockComment) {
          if (ch === "*" && src[j + 1] === "/") { blockComment = false; j++ }
          continue
        }
        if (quote) { if (ch === "\\") { j++; continue } if (ch === quote) quote = ""; continue }
        if (ch === "/" && src[j + 1] === "/") { lineComment = true; j++; continue }
        if (ch === "/" && src[j + 1] === "*") { blockComment = true; j++; continue }
        if (ch === "'" || ch === '"' || ch === "`") { quote = ch; continue }
        if (ch === "{") depth++
        else if (ch === "}") {
          depth--
          if (depth === 0) return src.slice(i, j + 1)
        }
      }
      return ""
    }
    let j = i
    while (j < src.length && src[j] !== "\n" && src[j] !== "\r") j++
    return src.slice(i, j).trim()
  }

  function count(haystack, needle) {
    if (haystack.indexOf(needle) < 0) return 0
    return haystack.split(needle).length - 1
  }

  // ---- APP-4 machine: the real commit functions and the two lane handlers --
  function buildSeekMachine() {
    const src = root.source
    const names = ["commitSeek", "seekAt", "seekTo", "scrubTo"]
    const missing = []
    let commit = ""
    let bodies = ""
    for (let i = 0; i < names.length; i++) {
      let fn = extract(src, names[i])
      if (fn === "") { missing.push(names[i]); continue }
      // QML identifiers cannot start upper case: map the library namespaces
      // onto local stubs (see the header).
      fn = fn.replace(/\bNP\.scrubPosition\(/g, "scrubPosition(")
        .replace(/\bRange\.clamp\(/g, "clamp(")
      if (names[i] === "commitSeek") commit = fn
      else bodies += "\n" + fn + "\n"
    }
    const release = handlerAfter(src, "onPositionChanged: mouse =>", "onReleased")
    const wheel = handlerAfter(src, "WheelHandler", "onWheel")
    if (release === "") missing.push("onReleased")
    if (wheel === "") missing.push("onWheel")
    root.seekMissing = missing.join(",")
    if (missing.length > 0) return null

    // The one commit body is instrumented: a call counter at its head, and the
    // code's own notify redirected to a counter (see the header).
    const head = /function commitSeek\s*\([^)]*\)\s*\{/
    if (!head.test(commit)) { root.seekMissing = "commitSeek.head"; return null }
    commit = commit.replace(head, function(m) { return m + " root.commitCalls++;" })
    commit = commit.replace(/root\.player\.positionChanged\(\)/g, "root.explicitNotify()")

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: root',
      '  property bool canSeekPosition: true',
      '  property real lengthSec: 100',
      '  property real previewPosition: 0',
      '  readonly property real shownPosition: root._seeking ? root.previewPosition : root.player.position',
      '  property bool _seeking: false',
      '  property real width: 200',
      '  property int commitCalls: 0',
      '  property int notifyCalls: 0',
      '  property QtObject player: QtObject { property real position: 0 }',
      '  function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)) }',
      '  function scrubPosition(x, w, len) { return (w > 0 ? Math.min(1, Math.max(0, x / w)) : 0) * len }',
      '  function explicitNotify() { root.notifyCalls++ }',
      '  function fireRelease(mouse) { ' + release + ' }',
      '  function fireWheel(event) { ' + wheel + ' }',
      commit,
      bodies,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "lyrics_seek_slice.qml")
  }

  // ---- APP-5 machine: the real swap script and opened/trackKey handlers ----
  function buildSwapMachine() {
    const src = root.source
    const script = handlerAfter(src, "id: trackSwap", "script")
    const opened = handlerAfter(src, "", "onOpenedChanged")
    const trackKey = extract(src, "onTrackKeyChanged")
    const missing = []
    if (script === "") missing.push("script")
    if (opened === "") missing.push("onOpenedChanged")
    if (trackKey === "") missing.push("onTrackKeyChanged")
    root.swapMissing = missing.join(",")
    if (missing.length > 0) return null

    // The opacity binding is lifted when the source has one. On the unfixed
    // tree there is none (the script writes lyricsSide.opacity directly), so
    // the stub keeps a plain property - which is exactly the leak being pinned.
    const om = /(?:^|\n)[ \t]*opacity:[ \t]*(root\.opened[^\n,}]*(?:swapK|swapping)[^\n,}]*)/.exec(src)
    const opacityExpr = om ? om[1].trim() : "1"

    const lines = [
      'import QtQml',
      'QtObject {',
      '  id: root',
      '  property bool opened: false',
      '  property bool animOn: true',
      '  property bool _seeking: false',
      '  property real swapK: 1',
      '  property int swapStops: 0',
      '  property int swapRestarts: 0',
      '  property int holdStops: 0',
      '  property QtObject lyricsSide: QtObject { property real opacity: ' + opacityExpr + ' }',
      '  property QtObject trackSwap: QtObject {',
      '    function restart() { root.swapRestarts++ }',
      '    function stop() { root.swapStops++ }',
      '    function fireScript() { ' + script + ' }',
      '  }',
      '  function _holdStart() {}',
      '  function _holdStop() { root.holdStops++ }',
      '  function _readBackdrop() {}',
      '  function onOpened() { ' + opened + ' }',
      trackKey,
      '}'
    ]
    return Qt.createQmlObject(lines.join("\n"), root, "lyrics_swap_slice.qml")
  }

  function drive() {
    root.error = ""
    try {
      root.source = read("features/bar/modules/NowPlaying/LyricsFullscreenOverlay.qml")
      kv("slice.source", root.source.length > 0)

      const src = root.source

      // ---------------- APP-4: one commit path ----------------
      const commit = extract(src, "commitSeek")
      const seekAt = extract(src, "seekAt")
      const seekTo = extract(src, "seekTo")
      const scrubTo = extract(src, "scrubTo")
      const release = handlerAfter(src, "onPositionChanged: mouse =>", "onReleased")
      const wheel = handlerAfter(src, "WheelHandler", "onWheel")
      kv("p4.commitFound", commit !== "")
      kv("p4.seekAtFound", seekAt !== "")
      kv("p4.seekToFound", seekTo !== "")
      kv("p4.scrubFound", scrubTo !== "")
      kv("p4.releaseFound", release !== "")
      kv("p4.wheelFound", wheel !== "")

      const routes = [seekAt, seekTo, release, wheel]
      let allRoute = true
      let noDirect = true
      for (let i = 0; i < routes.length; i++) {
        if (routes[i].indexOf("commitSeek(") < 0) allRoute = false
        if (routes[i].indexOf("player.position =") >= 0) noDirect = false
      }
      kv("p4.allRoutesThroughCommit", allRoute)
      kv("p4.noDirectPositionWrite", noDirect)
      kv("p4.commitClamps", commit.indexOf("Range.clamp(") >= 0)
      kv("p4.commitClearsSeeking", commit.indexOf("_seeking = false") >= 0)
      kv("p4.commitSingleNotify", count(commit, "positionChanged()") === 1)
      kv("p4.commitNoShownWrite", count(commit, "shownPosition =") === 0)
      kv("p4.scrubOnlyPreview", scrubTo.indexOf("previewPosition =") >= 0
        && scrubTo.indexOf("shownPosition =") < 0
        && scrubTo.indexOf("positionChanged") < 0 && scrubTo.indexOf("commitSeek") < 0)

      const sm = buildSeekMachine()
      root.seekMachineBuilt = sm !== null
      kv("p4.missing", root.seekMissing)
      if (sm !== null) {
        const routes2 = [
          { tag: "seekAt", fire: function() { sm.seekAt(50, 200) } },
          { tag: "seekTo", fire: function() { sm.seekTo(42) } },
          { tag: "release", fire: function() { sm.fireRelease({ x: 50 }) } },
          { tag: "wheel", fire: function() { sm.fireWheel({ angleDelta: { y: 120 }, accepted: false }) } }
        ]
        for (let i = 0; i < routes2.length; i++) {
          const r = routes2[i]
          sm.commitCalls = 0; sm.notifyCalls = 0
          sm.player.position = 0; sm.previewPosition = 0; sm._seeking = false
          // A drag has a preview on the lane when the finger lifts.
          if (r.tag === "release") { sm._seeking = true; sm.previewPosition = 33 }
          r.fire()
          kv("p4." + r.tag + ".calls", sm.commitCalls)
          kv("p4." + r.tag + ".notify", sm.notifyCalls)
          kv("p4." + r.tag + ".seeking", sm._seeking)
          kv("p4." + r.tag + ".position", Math.round(sm.player.position * 100) / 100)
          kv("p4." + r.tag + ".shown", Math.round(sm.shownPosition * 100) / 100)
        }
        // Scrub is preview only: it writes the preview and nothing else. The
        // lane follows it only while the finger owns it.
        sm.commitCalls = 0; sm.notifyCalls = 0
        sm.player.position = 0; sm.previewPosition = 0; sm._seeking = true
        sm.scrubTo(100, 200)
        kv("p4.scrub.calls", sm.commitCalls)
        kv("p4.scrub.notify", sm.notifyCalls)
        kv("p4.scrub.position", sm.player.position)
        kv("p4.scrub.shown", Math.round(sm.shownPosition * 100) / 100)
        // Outside a scrub the lane is a derivation of the live player, not a
        // snapshot left behind by the preview.
        sm._seeking = false
        sm.player.position = 70; sm.previewPosition = 10
        kv("p4.derived.idle", Math.round(sm.shownPosition * 100) / 100)
      }

      // ---------------- APP-5: opacity survives same-track reopen ----------
      const script = handlerAfter(src, "id: trackSwap", "script")
      const opened = handlerAfter(src, "", "onOpenedChanged")
      const trackKey = extract(src, "onTrackKeyChanged")
      const om = /(?:^|\n)[ \t]*opacity:[ \t]*(root\.opened[^\n,}]*(?:swapK|swapping)[^\n,}]*)/.exec(src)
      kv("swap.scriptFound", script !== "")
      kv("swap.openedFound", opened !== "")
      kv("swap.trackKeyFound", trackKey !== "")
      kv("swap.opacityBound", om !== null)
      kv("swap.kScalar", src.indexOf("property real swapK") >= 0
        || src.indexOf("property bool swapping") >= 0)
      kv("swap.scriptDerived", script.indexOf("lyricsSide.opacity =") < 0
        && (script.indexOf("swapK = 0") >= 0 || script.indexOf("swapping = true") >= 0))
      kv("swap.stopOnClose", opened.indexOf("trackSwap.stop()") >= 0)
      kv("swap.effectsFollowLyrics", count(src, "opacity: lyricsSide.opacity") === 4)

      const wm = buildSwapMachine()
      root.swapMachineBuilt = wm !== null
      kv("swap.missing", root.swapMissing)
      if (wm !== null) {
        wm.opened = true; wm.swapK = 1
        kv("swap.open.opacity", wm.lyricsSide.opacity)
        // A new trackKey arms the swap; the ScriptAction clears the transcript.
        wm.onTrackKeyChanged()
        wm.trackSwap.fireScript()
        kv("swap.mid.opacity", wm.lyricsSide.opacity)
        kv("swap.mid.restarts", wm.swapRestarts)
        // Close mid-swap, before the final NumberAnimation can finish.
        wm.opened = false
        wm.onOpened()
        kv("swap.close.stops", wm.swapStops)
        kv("swap.close.swapK", wm.swapK)
        // Reopen the SAME track: no trackKey edge, so no new swap is armed.
        wm.opened = true
        wm.onOpened()
        kv("swap.reopen.opacity", wm.lyricsSide.opacity)
        kv("swap.reopen.restarts", wm.swapRestarts)
      }

      kv("probe.error", root.error)
    } catch (e) {
      root.error = "" + (e && e.message ? e.message : e)
      kv("probe.error", root.error)
    }
    console.log("##DONE##")
  }

  Component.onCompleted: drive()
}
