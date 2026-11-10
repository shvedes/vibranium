pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import "NowPlaying.js" as NP

// Synced lyrics over a slot: the fullscreen Now Playing surface and the
// lockscreen card both render this pane. MPRIS carries no lyrics, so the text
// comes from LRCLIB (no key, LRC bodies), with `xesam:asText` as the fallback
// for a client that publishes its own. The ask starts with the track rather
// than with the pane, so the answer is ready before a surface shows it; the
// lines are centred and the cue under the playhead is the one held in the
// middle of the slot, driven by the caller's position feed, so this pane needs
// no clock of its own.
Item {
  id: root

  // The transcript travels inside the cover slot, so it is clipped to it
  // rather than sliding out over the meta column.
  clip: true

  required property var player
  property real position: 0
  property bool active: false
  // Held playback keeps the cue's accent but holds it down to a tint: the
  // transcript is still live, it just reads as paused rather than as a line
  // the clock is moving under.
  property bool playing: true

  signal dismissed
  // A clicked line names a time; the caller owns the position write, because
  // only it knows whether the transport takes one.
  signal seekRequested(real seconds)
  // False while the player cannot take an absolute write, so a click on a
  // line is inert and the transcript stays a document.
  property bool seekable: false
  // False on a presentation surface: a right-click should not dismiss and a
  // drag should not take the transcript away from the current cue.
  property bool dismissable: true
  property bool scrollable: true

  readonly property string title: root.player ? String(root.player.trackTitle ?? "") : ""
  readonly property string artist: root.player ? String(root.player.trackArtist ?? "") : ""
  readonly property string album: root.player ? String(root.player.trackAlbum ?? "") : ""
  readonly property real lengthSec: NP.playerLength(root.player)
  // One identity per recording, normalized in the shared library, so the same
  // track on another client is the same sheet and a regroup inside a track
  // does not re-ask the provider.
  readonly property string trackKey: root.player === null || root.player === undefined ? ""
    : NP.lyricsCacheKey(root.title, root.artist, root.album, root.lengthSec)

  property bool synced: false
  property var lines: []
  property int activeIndex: -1
  // The line the pane treats as the current one: the cue under the playhead,
  // or the first cue while the track is still before it, so the opening line
  // is already the big one as it approaches instead of jumping at its stamp.
  readonly property int currentIndex: root.activeIndex >= 0
    ? root.activeIndex
    : (root.synced && root.lines.length > 0 ? 0 : -1)
  // Not `state`: Item already has one, and this is a load state rather than a
  // QML state machine.
  property string status: "idle" // idle | loading | ready | none | error
  // For the pad that opens this pane: a track neither the provider nor the
  // metadata has words for dims the pad and refuses the click. An unfinished
  // or failed ask is not absence, so those stay openable.
  readonly property bool unavailable: root.status === "none"
  readonly property bool ready: root.status === "ready"
  property string _requestedKey: ""
  property var _request: null
  readonly property bool animOn: MotionPolicy.enabled
  // Whether a cue change glides the transcript to its new centre. The island
  // has room for the travel; a caller can turn it off to place cues directly.
  property bool glide: true
  // Type multiplier for the cue column. The island's cover slot sets the
  // baseline; a wider surface without artwork can spend that space on larger
  // words.
  property real textScale: 1
  // Quiet cue size as a scale of the laid-out size. Every row is shaped at
  // `fontL`, so the geometry never changes and a quiet line is the same words
  // drawn smaller.
  readonly property real quietScale: Ui.fontXs / Ui.fontL
  // How many cues on each side of the current one stay on screen. -1 is the
  // island's full transcript; a caller can narrow it to a three-line window.
  property int contextLines: -1
  // Auto-scroll yields to the reader. Once the transcript has been scrolled
  // so the current line is no longer under the middle of the slot, the cue
  // changes keep moving the accent but stop moving the view, so a line can be
  // read and then clicked to jump to. Scrolling back onto the current line
  // hands the view to the clock again - see the contentY handler on the view.
  // The clock never takes the view back on its own: a transcript that pulls
  // itself to the cue after a pause cannot be read ahead in.
  property bool _pinnedByUser: false
  // True for the synchronous moment a placement changes contentY, so that
  // change is not mistaken for the reader scrolling.
  property bool _placing: false
  // A freshly applied sheet is a cut: its first placement must not glide in
  // from the scroll offset the previous track left behind.
  property bool _freshSheet: false

  // Asking starts with the track, not with the pane: the lyrics pad reads
  // `unavailable` so the answer has to be known before anyone opens the
  // transcript. Opening asks again, which is a cache hit once the track has
  // been answered.
  Component.onCompleted: root._load()
  Component.onDestruction: root._abort()
  onActiveChanged: {
    if (!root.active) return
    // A surface opens showing the clock, not whatever the previous showing
    // left the view scrolled to.
    root._pinnedByUser = false
    root._load()
  }
  onTrackKeyChanged: root._load()
  onPositionChanged: root._track()
  onActiveIndexChanged: Qt.callLater(root._follow)
  // The slot can resize under the transcript while the card grows or shrinks;
  // keep the cue in the middle without waiting for the next position tick.
  onHeightChanged: Qt.callLater(root._follow)

  function _load() {
    const key = root.trackKey
    if (key === "") {
      root._abort()
      root._requestedKey = ""
      root.lines = []
      root.synced = false
      root.activeIndex = -1
      root._pinnedByUser = false
      root.status = "idle"
      return
    }
    // An answered track, lyrics or not, is kept: the island is destroyed when
    // it closes, so the answer lives in the shared library rather than on this
    // pane, and a second surface (or a reopen) on the same track must not cost
    // a round trip to say "No lyrics".
    const cached = NP.lyricsCacheGet(key)
    if (cached !== null) {
      root._abort()
      root._apply(key, cached.result)
      return
    }
    if (root._requestedKey === key && root.status === "loading") return
    const url = root._searchUrl()
    root._requestedKey = key
    root.lines = []
    root.synced = false
    root.activeIndex = -1
    if (url === "") {
      root.status = "none"
      return
    }
    root.status = "loading"
    root._abort()
    root._request = root._get(url, 6000, (text, code) => {
      root._request = null
      root._receive(key, text, code)
    })
  }

  function _searchUrl() {
    if (root.title === "") return ""
    let url = "https://lrclib.net/api/search?track_name=" + encodeURIComponent(root.title)
    if (root.artist !== "") url += "&artist_name=" + encodeURIComponent(root.artist)
    if (root.album !== "") url += "&album_name=" + encodeURIComponent(root.album)
    return url
  }

  function _receive(key, text, code) {
    if (key !== root._requestedKey || key !== root.trackKey) return
    let parsed = null
    try {
      parsed = text !== "" ? JSON.parse(text) : null
    } catch (e) {
      parsed = null
    }
    const found = NP.lyricsFromSearch(parsed, root.lengthSec)
    if (found !== null) {
      root._apply(key, found)
      return
    }
    // No provider result: a client that ships its own text still has words,
    // they are just untimed.
    const embedded = NP.parsePlainLyrics(root._embeddedText())
    if (embedded.length > 0) {
      root._apply(key, { synced: false, lines: embedded.map(x => ({ t: 0, x })) })
      return
    }
    // A failed or unreadable answer is not an answer: the pane reports it and
    // leaves the track uncached, so reopening the pane asks again.
    const unreadable = text !== "" && parsed === null
    if (unreadable || (code !== "" && code !== "http_404")) {
      root.lines = []
      root.synced = false
      root.activeIndex = -1
      root.status = "error"
      return
    }
    root._apply(key, null)
  }

  function _apply(key, result) {
    if (key !== root.trackKey) return
    root._requestedKey = key
    NP.lyricsCachePut(key, result)
    const lines = result !== null && Array.isArray(result.lines) ? result.lines : []
    root.synced = lines.length > 0 && result.synced === true
    root.lines = lines
    root.status = lines.length > 0 ? "ready" : "none"
    root.activeIndex = -1
    // A freshly answered track is read from the top of its first cue, not
    // from wherever the last transcript was left.
    root._pinnedByUser = false
    root._freshSheet = true
    root._track()
    Qt.callLater(root._follow)
  }

  function _track() {
    root.activeIndex = root.synced ? NP.lyricIndexAt(root.lines, root.position) : -1
  }

  // The cue that holds the middle of the slot. Untimed text has no cue to hold,
  // so it starts at the top and stays where the user scrolls it.
  function _follow() {
    // A closed pane has nothing to place; opening runs _load -> _apply, which
    // follows again with the view up.
    if (!root.active) return
    if (root.synced && root.currentIndex >= 0) {
      // A scrolled transcript yields to its reader; a presentation surface
      // disables scrolling, so its pin never sets.
      if (root._pinnedByUser && root.glide) {
        scrollTo.stop()
        return
      }
      root._centre(root.currentIndex)
      return
    }
    scrollTo.stop()
    if (!root.synced && root.lines.length > 0) root._placeBeginning()
  }

  function _placeBeginning() {
    root._freshSheet = false
    root._placing = true
    view.positionViewAtBeginning()
    root._placing = false
  }

  // Glide to a cue instead of dropping onto it. The row is read off the view
  // because the next cue is always the row just below the centred one, which
  // is laid out for real; a row the view has not created yet (a seek landing
  // several lines away) has only a guessed y, so that move is the view's own
  // placement and happens at once.
  function _centre(index) {
    const row = view.itemAtIndex(index)
    scrollTo.stop()
    // A fresh sheet is a cut rather than a cue change: it is placed on its
    // line instead of gliding there from the offset the previous track left.
    // A row the view has not created yet is the same case - it has only a
    // guessed y, so the move is the view's own placement.
    if (root._freshSheet || row === null || !root.animOn || !root.glide) {
      root._freshSheet = false
      root._placing = true
      view.positionViewAtIndex(index, ListView.Center)
      root._placing = false
      return
    }
    // `row.y` is already in content coordinates, so the resting offset is the
    // row's centre pulled to the middle of the viewport. Adding the live
    // contentY here would count the current scroll twice and overshoot.
    scrollTo.to = row.y + row.height / 2 - view.height / 2
    scrollTo.start()
  }

  NumberAnimation {
    id: scrollTo

    target: view
    property: "contentY"
    duration: Ui.normalMs
    easing.type: Easing.OutCubic
  }

  // A layout settle - the first delegates, a track's sheet, a weight change on
  // a wrapped line - moves contentY without the reader touching it. Those
  // moves are not a scroll and must not claim the view, or a freshly opened
  // pane would sit off centre until the idle timer handed it back. The timer
  // restarts on every height change and recentres once the layout is still.
  Timer {
    id: settleGuard

    interval: 150
    repeat: false
    onTriggered: if (root.synced) root._follow()
  }

  function _embeddedText() {
    const md = root.player ? root.player.metadata : null
    if (!md || typeof md !== "object") return ""
    const v = md["xesam:asText"]
    return typeof v === "string" ? v : ""
  }

  function _abort() {
    if (root._request === null) return
    root._request.abort()
    root._request = null
  }

  // GET with the response as text, or "" and a short reason. Mirrors the
  // weather transport: a superseded handle never calls back, and a request is
  // never torn down mid-handshake.
  function _get(url, timeoutMs, onDone) {
    let xhr = null
    try {
      xhr = new XMLHttpRequest()
    } catch (e) {
      Qt.callLater(() => onDone("", "no_transport"))
      return { abort() {} }
    }
    const handle = { dead: false, abort() { handle.dead = true } }
    const finish = (text, code) => {
      if (handle.dead) return
      handle.dead = true
      onDone(text, code)
    }
    xhr.onreadystatechange = () => {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status === 200) {
        finish(String(xhr.responseText || ""), "")
        return
      }
      finish("", "http_" + xhr.status)
    }
    try {
      xhr.timeout = timeoutMs
      xhr.open("GET", url)
      // LRCLIB rejects a request without an agent.
      try {
        xhr.setRequestHeader("User-Agent", "vibranium-shell/1.0")
      } catch (e) {}
      xhr.send()
    } catch (e) {
      finish("", "send_failed")
    }
    return handle
  }

  // No fill of its own: the slot's own surface (the cover or the plain box)
  // is what the words sit on, so the card does not gain a second background
  // when it swaps to lyrics.
  Item {
    id: slot

    width: parent.width
    height: parent.height
    // The swap is a slide, not a frame: the transcript rises from the bottom
    // edge of the slot on open and sinks back into it on dismiss, revealing
    // the cover behind it. The visible test reads the animated y, so the slot
    // stays alive for the length of the travel and is dropped at the end.
    y: root.active ? 0 : height
    visible: root.active || y < height - 0.5
    Behavior on y {
      enabled: root.animOn
      NumberAnimation {
        duration: Ui.normalMs
        easing.type: Easing.OutCubic
      }
    }

    ListView {
      id: view

      anchors.fill: parent
      anchors.margins: 10
      // The column is the full card width now and the words take it: only a
      // hair of padding is left on the left and right edges.
      anchors.leftMargin: 4
      anchors.rightMargin: 4
      clip: true
      interactive: root.scrollable
      spacing: 6
      model: root.lines
      boundsBehavior: Flickable.StopAtBounds
      // Both ends pad by half the slot, so the first and last cues can reach
      // the middle instead of stopping at an edge.
      header: Item {
        width: view.width
        height: Math.max(0, Math.round(view.height / 2) - 13)
      }
      footer: Item {
        width: view.width
        height: Math.max(0, Math.round(view.height / 2) - 13)
      }
      onCountChanged: Qt.callLater(root._follow)
      onContentHeightChanged: settleGuard.restart()
      // A drag owns the view until the reader comes back to the current line:
      // the transcript must not yank itself away from the line about to be
      // clicked.
      onMovementStarted: {
        scrollTo.stop()
        root._pinnedByUser = true
      }
      // Every contentY change that is not ours is the reader's - a drag, a
      // flick, or the wheel. Pinned means "the current line is not under the
      // middle of the slot", measured in line heights rather than in screen
      // fractions: moving the transcript by even one row is deliberate, while
      // a fraction of a tall viewport leaves small scrolls unpinned and the
      // next cue change free to pull them back. Scrolling the cue under the
      // middle again - or clicking a line, or a new sheet - releases it.
      onContentYChanged: {
        if (root._placing || scrollTo.running || settleGuard.running) return
        if (view.contentHeight <= view.height) return
        const row = root.currentIndex >= 0 ? view.itemAtIndex(root.currentIndex) : null
        if (row === null) {
          root._pinnedByUser = true
          return
        }
        const off = Math.abs(view.contentY + view.height / 2 - (row.y + row.height / 2))
        root._pinnedByUser = off > Math.max(24, row.height)
      }

      delegate: Text {
        id: line

        required property var modelData
        required property int index

        readonly property bool inWindow: root.contextLines < 0
          || root.currentIndex < 0
          || Math.abs(index - root.currentIndex) <= root.contextLines
        // Pointer over a neighbour: a whisper brighter, so the transcript
        // reads as clickable without a hover competing with the accent.
        property bool lineHovered: false
        visible: inWindow
        width: view.width
        text: modelData.x
        // The cue under the playhead is the one the eye is on: full size and
        // in the accent, its neighbours drawn down and held faint so the
        // column reads as one line with context rather than as a list.
        color: index === root.currentIndex
          ? Ui.solid("accent")
          : Ui.tint("foreground_1", lineHovered ? 0.65 : 0.4)

        // The cue changing is a colour handover as well as a scroll, so the
        // old line dims as the new one takes the accent instead of both
        // swapping in one frame.
        Behavior on color {
          // The opening cue is born in the accent: there is no line above it
          // to have come from, so it must not animate as if there were.
          enabled: root.animOn && line.index !== 0
          ColorAnimation {
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
          }
        }
        // Held playback is its own transition, separate from the cue handover:
        // the accent fades toward the surface on pause and back on resume,
        // whether or not this row animates its colour. Fading alpha over the
        // same accent is the muted tint, just carried by a property that the
        // opening row is allowed to animate.
        opacity: index === root.currentIndex && !root.playing ? 0.55 : 1
        Behavior on opacity {
          enabled: root.animOn
          NumberAnimation {
            duration: Ui.normalMs
            easing.type: Easing.OutCubic
          }
        }
        // Every row is shaped at the large size and the quiet ones are drawn
        // down, so a cue change never re-wraps or re-measures text: the rows
        // keep their geometry and the growth runs on the scene graph. That
        // fixed layout is what keeps the transition smooth and the cue still.
        font.pixelSize: Math.round(Ui.fontL * root.textScale)
        scale: index === root.currentIndex ? 1 : root.quietScale
        Behavior on scale {
          enabled: root.animOn && line.index !== 0
          NumberAnimation {
            duration: 320
            easing.type: Easing.InOutCubic
          }
        }
        font.family: Ui.fontFamily
        // The weight swap is one re-measure at the switch, not a per-frame
        // re-shape: the size travel above is a transform, so only the layout
        // pass at the moment the cue moves actually costs anything.
        font.bold: index === root.currentIndex
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        textFormat: Text.PlainText

        // A tap names a line; a drag belongs to the transcript. Handlers
        // rather than a MouseArea: an area takes the press, so a drag the
        // flickable has not claimed yet lands as a click on the row under the
        // pointer - a seek and a recentre instead of a scroll.
        TapHandler {
          acceptedButtons: Qt.LeftButton
          cursorShape: root.seekable && root.synced ? Qt.PointingHandCursor : Qt.ArrowCursor
          onTapped: {
            if (!root.seekable || !root.synced) return
            // Acting on a line asks for the clock to take the view back: the
            // seek moves the cue, and following centres it again.
            root._pinnedByUser = false
            root.seekRequested(line.modelData.t)
          }
        }

        HoverHandler {
          onHoveredChanged: line.lineHovered = hovered
        }
      }
    }

    Text {
      anchors.centerIn: parent
      width: parent.width - 16
      visible: root.status !== "ready"
      text: root.status === "loading" ? "Loading lyrics..."
        : root.status === "none" ? "No lyrics"
        : root.status === "error" ? "Lyrics unavailable" : ""
      color: Ui.tint("foreground_1", 0.55)
      font.pixelSize: Ui.fontM
      font.family: Ui.fontFamily
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.Wrap
      textFormat: Text.PlainText
    }

    // Back to the cover. Only the right button, so a left drag still scrolls
    // the transcript and a left click does nothing.
    MouseArea {
      anchors.fill: parent
      enabled: root.dismissable
      acceptedButtons: Qt.RightButton
      cursorShape: root.dismissable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.dismissed()
    }
  }
}
