pragma ComponentBehavior: Bound

// qmllint disable uncreatable-type signal-handler-parameters
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.common
import "Model.js" as Model

// Fullscreen Wi-Fi share overlay: a saved network as a scannable QR code
// on a heavy scrim. Esc or the scrim dismisses it.
//
// Owned by the network bar module (sibling to the island, like the color
// picker's overlay): a row's QR button calls open(ssid), which regenerates
// the code via vb-network-qr --ssid. The generator emits the security type
// and SSID it shared ahead of the module matrix; a bare open() shares the
// active connection instead.
//
// Both helpers run as registry-owned ProcessJobs rather than as raw Process
// children, so a request generation, a spawn bound, a deadline, and a retry
// policy travel with every run. Quickshell 0.3.1 reports neither `started`
// nor `exited` for an executable it cannot find, which a raw child turns
// into a card stuck on "Generating QR code..." for the rest of the session;
// here the same condition is a terminal result that clears the card.
Item {
  id: root

  property ShellScreen targetScreen: null
  property bool opened: false
  property string requestedSsid: ""
  property string ssid: ""
  property bool secured: false

  property var qrRows: []
  property int qrSize: 0
  property string error: ""
  property bool loading: false
  property bool pendingShow: false
  property string password: ""
  property bool passwordVisible: false
  property string passwordError: ""

  readonly property string _gateInstance: String(root)
  readonly property string _qrScope: "network-qr/" + root._gateInstance
  readonly property string _pwScope: "network-password/" + root._gateInstance
  property var _qrRequest: null
  property var _qrRun: null
  property var _pwRequest: null
  // The password child is the one run whose liveness the UI asks about: the
  // reveal button is one-time, so a second press must see the lookup in
  // flight. The QR run answers that question with its generation instead,
  // because generate() also has to queue behind one and hand over on its
  // terminal transition.
  property var _pwJob: null

  // One bound serves both helpers, which are local one-shots that answer in
  // milliseconds. A child the runtime never confirms fails after
  // _spawnWatchdogMs rather than waiting for the exit that a missing
  // executable never produces; _timeoutMs caps a child that did start and
  // never finished; _maxAttempts with a doubling backoff caps the sequence.
  // A missing vb-network-qr or vb-network-password therefore settles in
  // about a second instead of leaving the card in its loading state.
  readonly property int _spawnPollMs: 50
  readonly property int _spawnWatchdogMs: 1500
  readonly property int _timeoutMs: 5000
  readonly property int _maxAttempts: 2
  readonly property int _backoffMs: 250
  readonly property int _maxBackoffMs: 1000

  // A helper the shell cannot start at all is a different failure from one
  // that started and returned no code, so it says so rather than implying
  // the network was the problem. The child's own stderr still wins over
  // both: it names the cause the helper did report.
  readonly property string _qrUnavailable: "The Wi-Fi QR helper is unavailable"
  readonly property string _pwUnavailable: "The Wi-Fi password helper is unavailable"
  readonly property string _qrFailed: "Could not generate the Wi-Fi QR code"
  readonly property string _pwFailed: "Could not read the Wi-Fi password"

  readonly property bool showingQr: root.qrSize > 0 && !root.loading && root.error === ""

  // The scrim below is a fixed near-black regardless of theme, so text on
  // it needs a fixed light palette, not the themed foreground.
  readonly property color onScrim: "white"
  readonly property color onScrimDim: Qt.rgba(1, 1, 1, 0.55)
  readonly property color onScrimUrgent: "#ff6b6b"

  function open(ssid) {
    root.requestedSsid = String(ssid || "")
    root.ssid = ""
    generate()
    root.opened = true
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root._retire(root._qrRequest)
    root._qrRequest = null
    root._qrRun = null
    root._retire(root._pwRequest)
    root._pwRequest = null
    root.opened = false
    root.pendingShow = false
    // Both generations are dead before either child is stopped: cancelling a
    // job reports its terminal transition synchronously, and that callback
    // has to find a handle this close already retired, or it would
    // repopulate a card the user just dismissed.
    root._cancel(root._qrScope)
    root._cancel(root._pwScope)
    root._pwJob = null
    root.qrSize = 0
    root.qrRows = []
    root.error = ""
    root.loading = false
    root.requestedSsid = ""
    root.ssid = ""
    root.secured = false
    // The Wi-Fi password only enters shell memory while the card is up.
    root.password = ""
    root.passwordVisible = false
    root.passwordError = ""
  }

  function generate() {
    if (root._qrRun !== null) {
      // Whether the run in flight is a dismissal's SIGTERM still landing
      // or a live generation, the latest request wins: queue it for the
      // terminal transition and stop the old child.
      const queued = root._begin(root._qrScope, "matrix")
      if (!RequestGate.current(queued)) return
      root.pendingShow = true
      root._qrRequest = queued
      // The queued generation is already current, so the child this cancels
      // is stale the moment it settles, and _settleQr's handover is what
      // moves the card on to it.
      root._cancel(root._qrScope)
      return
    }
    const run = root._begin(root._qrScope, "matrix")
    if (!RequestGate.current(run)) return
    root._qrRequest = run
    root._qrRun = run
    // A re-open without a close() in between may share a different
    // connection now: neither the previous reveal's password nor a reveal
    // still in flight may survive onto the new card.
    root._retire(root._pwRequest)
    root._pwRequest = null
    root._cancel(root._pwScope)
    root._pwJob = null
    root.qrSize = 0
    root.qrRows = []
    root.error = ""
    root.loading = true
    root.secured = false
    root.password = ""
    root.passwordVisible = false
    root.passwordError = ""
    // The argv is unchanged: the SSID stays an argument and no shell ever
    // sees it. The run's own generation is what a terminal result is
    // measured against, so the job needs no reference of its own here.
    root._spawn(root.requestedSsid !== ""
      ? ["vb-network-qr", "--meta", "--ssid", root.requestedSsid]
      : ["vb-network-qr", "--meta"], root._qrScope, result => root._settleQr(run, result))
  }

  function updateQr(raw) {
    const parsed = Model.parseQrOutput(raw)
    root.qrRows = parsed.matrix.rows
    root.qrSize = parsed.matrix.size
    if (parsed.meta.ssid !== "") root.ssid = parsed.meta.ssid
    root.secured = parsed.meta.security !== "" && parsed.meta.security !== "nopass"
    // Good output settles the run: a canceled predecessor's stderr may have
    // landed after this generation started, and must not shadow its result.
    if (root.qrSize > 0) root.error = ""
  }

  function togglePassword() {
    // One-time use: the first press fetches the secret and swaps the
    // button for it, permanently for this showing. Closing drops the
    // secret; reopening starts over with a fresh button.
    if (root.passwordVisible || root.password !== "") return
    // A lookup that failed keeps its error slot, and the button is gone
    // with it, so the one-time rule also bounds a missing helper: a card
    // cannot be asked for the same secret until it is closed again.
    if (root.passwordError !== "") return
    if (root._pwJob !== null || root.ssid === "") return
    root.passwordError = ""
    // Only a deliberate new lookup issues a password generation, right as
    // it launches. The secret is looked up by the shared SSID so any
    // saved network (not just the active one) can reveal it.
    const handle = root._begin(root._pwScope, "ssid")
    if (!RequestGate.current(handle)) return
    root._pwRequest = handle
    // The argv is unchanged: the SSID stays an argument, no shell sees it,
    // and the value the child answers with is never placed anywhere but the
    // panel property. Unlike the QR run, this one records its child, because
    // the reveal button is one-time and a second press has to see a lookup
    // that is still in flight.
    const job = root._spawn(["vb-network-password", "--ssid", root.ssid],
      root._pwScope, result => root._settlePw(handle, result))
    if (job !== null && RequestGate.current(handle)) root._pwJob = job
  }

  // One registry-owned child per generation, under the same bounds. The
  // registry reports a command it refuses, a job it cannot build, and a
  // terminal child through the single settle callback, so a spawn failure, a
  // nonzero exit and a timeout all end the same way instead of leaving the
  // card loading. A child the runtime never confirms is failed by the job's
  // own watchdog, and the attempt and backoff bounds stop a helper that
  // stays missing from being retried for the rest of the session.
  function _spawn(argv, owner, settle) {
    let job = null
    try {
      job = ProcessRegistry.start(argv, owner, {
        timeoutMs: root._timeoutMs,
        maxAttempts: root._maxAttempts,
        backoffMs: root._backoffMs,
        maxBackoffMs: root._maxBackoffMs,
        spawnWatchdogMs: root._spawnWatchdogMs,
        spawnPollMs: root._spawnPollMs,
        onFinished: settle,
        onFailed: () => settle(null)
      })
    } catch (ignored) {
      job = null
    }
    // A pre-spawn rejection settles synchronously, so a null job here is the
    // registry refusing the argv or the owner outright rather than a child
    // that will report later.
    if (job === null) {
      settle(null)
      return null
    }
    return job
  }

  // A live job of this owner is cancelled and a settled one is already gone
  // from the registry, so the call is idempotent and a terminal transition
  // that arrives twice cannot publish twice.
  function _cancel(owner) {
    try {
      return ProcessRegistry.cancelOwner(owner) > 0
    } catch (ignored) {
      return false
    }
  }

  // The single terminal path of one QR generation. The run is dropped first
  // and the generation is retired before any state is published, so nothing
  // here can leave loading set on a card whose request is gone: a queued
  // replacement hands over to generate(), and a retired run publishes
  // nothing at all.
  function _settleQr(run, result) {
    const request = root._qrRequest
    root._qrRun = null
    if (root.pendingShow) {
      root.pendingShow = false
      // The queued request owns the pair, so nothing the retired run still
      // emits applies to it. A dismissal can retire the queued handle
      // before the delayed generate lands, which then no-ops.
      Qt.callLater(function() {
        if (RequestGate.current(request)) root.generate()
      })
      return
    }
    if (!RequestGate.current(run)) return
    root._retire(run)
    root.loading = false
    // Only a clean exit publishes a matrix, so a failed run cannot leave a
    // half-read code behind, and the collectors' one terminal text replaces
    // the pair of racing stream callbacks a raw child needed.
    const code = result === null ? "" : String(result.code)
    if (code === "ok" && String(result.stdout || "") !== "") root.updateQr(String(result.stdout))
    if (root.qrSize > 0) return
    root.qrSize = 0
    root.qrRows = []
    root.error = result === null
      ? root._qrFailed
      : String(result.stderr || "").trim()
        || (code === "spawn_failed" ? root._qrUnavailable : root._qrFailed)
  }

  // The single terminal path of one password lookup. It bails when the card
  // is gone, so a fetch that was in flight during dismissal cannot stash the
  // secret into a closed panel's state, and it drops a fetch whose handle a
  // regeneration retired, so it cannot reveal the previous network's
  // password under the new card. The secret is read from the result and
  // nowhere else, and only the child's own stderr reaches the error slot, so
  // a failure can never echo the value back onto the screen.
  function _settlePw(handle, result) {
    if (!root.opened) return
    if (!RequestGate.current(handle)) return
    root._pwJob = null
    root._retire(handle)
    const secret = result === null ? "" : String(result.stdout || "").trim()
    if (secret !== "") {
      root.password = secret
      root.passwordVisible = true
      return
    }
    const stderr = result === null ? "" : String(result.stderr || "").trim()
    root.passwordError = stderr !== ""
      ? stderr
      : (result !== null && String(result.code) === "spawn_failed"
        ? root._pwUnavailable
        : root._pwFailed)
  }

  function _begin(scope, key) {
    return { id: RequestGate.begin(scope, key), scope: scope, key: key }
  }

  function _retire(handle) {
    if (handle === null) return
    RequestGate.invalidate(handle)
  }

  // A registry job outlives the object that started it, so a teardown that
  // never reached close() still has to drop both children. The generations go
  // first, for the same reason close() orders it that way: the cancel that
  // follows reports its terminal transition synchronously, and that callback
  // must find a handle this teardown already retired.
  Component.onDestruction: {
    root._retire(root._qrRequest)
    root._retire(root._pwRequest)
    root._cancel(root._qrScope)
    root._cancel(root._pwScope)
  }

  PanelWindow {
    visible: root.opened
    screen: root.targetScreen
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "vibranium:network-qr"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // Deep scrim: the floating code needs the backdrop to carry the contrast
    // on any wallpaper. Either mouse button dismisses.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.78)

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: root.close()
      }
    }

    Item {
      id: keyCatcher

      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.close()
      Keys.onPressed: event => {
        if (event.key === Qt.Key_Backspace) {
          root.close()
          event.accepted = true
        }
      }

      Item {
        anchors.centerIn: parent
        width: content.implicitWidth
        height: content.implicitHeight
        // Narrow or heavily scaled outputs: shrink the whole card rather
        // than clipping it at the screen edge.
        scale: Math.min(1,
          (keyCatcher.width - 32) / Math.max(1, width),
          (keyCatcher.height - 32) / Math.max(1, height))

        // Swallow left clicks so only the scrim outside the content
        // dismisses; right clicks fall through to the scrim and close.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.LeftButton
          onClicked: {}
        }

        ColumnLayout {
          id: content

          anchors.fill: parent
          spacing: Ui.l

          // Every QR module as an integer-sized native rectangle. Stays
          // crisp, no temp images or file-cache races. Only dark modules
          // paint, so the white canvas keeps its square corners; the spec
          // quiet zone baked into the matrix keeps the code clear of them.
          Rectangle {
            id: qrCanvas

            readonly property int moduleSize: root.qrSize > 0
              ? Math.max(4, Math.floor(320 / root.qrSize))
              : 0

            visible: root.showingQr
            Layout.preferredWidth: root.qrSize * moduleSize
            Layout.preferredHeight: root.qrSize * moduleSize
            color: "white"
            Layout.alignment: Qt.AlignHCenter

            Grid {
              anchors.fill: parent
              columns: root.qrSize

              Repeater {
                model: root.qrSize * root.qrSize

                Rectangle {
                  required property int index
                  readonly property int matrixRow: Math.floor(index / root.qrSize)
                  readonly property int matrixColumn: index % root.qrSize

                  width: qrCanvas.moduleSize
                  height: qrCanvas.moduleSize
                  color: root.qrRows[matrixRow].charAt(matrixColumn) === "1" ? "#111111" : "transparent"
                }
              }
            }
          }

          Text {
            visible: root.loading
            text: "Generating QR code..."
            color: root.onScrimDim
            font.family: Ui.fontFamily
            font.pixelSize: Ui.fontS
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            textFormat: Text.PlainText
            visible: root.error !== ""
            text: root.error
            color: root.onScrimUrgent
            font.family: Ui.fontFamily
            font.pixelSize: Ui.fontS
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            Layout.maximumWidth: 340
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: root.showingQr
            text: "Scan to join this network"
            color: root.onScrimDim
            font.family: Ui.fontFamily
            font.pixelSize: Ui.fontS
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
          }

          // Fixed-height action slot: the button, the secret and the error
          // all live in this one box, so swapping between them never moves
          // the code above.
          Item {
            visible: root.showingQr && root.secured
            Layout.fillWidth: true
            Layout.preferredHeight: 40

            Button {
              visible: !root.passwordVisible && root.passwordError === ""
              anchors.centerIn: parent
              variant: "outline"
              label: "Show password"
              labelColor: "white"
              onClicked: root.togglePassword()
            }

            // The revealed secret, wrapped so long passphrases never leave
            // the scrim. Replaces the button one-time; closing drops it.
            Text {
              textFormat: Text.PlainText
              visible: root.passwordVisible
              anchors.centerIn: parent
              width: Math.min(parent.width, 340)
              text: root.password
              color: root.onScrim
              font.family: Ui.fontFamily
              font.pixelSize: Ui.fontS
              wrapMode: Text.WrapAnywhere
              maximumLineCount: 2
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              visible: !root.passwordVisible && root.passwordError !== ""
              anchors.centerIn: parent
              width: Math.min(parent.width, 340)
              text: root.passwordError
              color: root.onScrimUrgent
              font.family: Ui.fontFamily
              font.pixelSize: Ui.fontS
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
