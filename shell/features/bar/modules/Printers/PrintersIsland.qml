pragma ComponentBehavior: Bound

// qmllint disable signal-handler-parameters
import QtQuick
import qs.common
import qs.services as Svc
import "../../../../services/system/PrintersLib.js" as Model

// Printers island. Header: the section-cap style (lib Title level 2,
// the caps + leading glyph the ArchUpdates island uses for its own
// header) with the muted subtitle underneath and the CUPS-settings and
// reload affordances on the right. Sections use the same caps style:
// KNOWN PRINTERS (always visible, with an info placeholder while empty)
// and JOBS (five rows visible at most, the rest scrolls). Job rows are
// Finder-style zebra rows with a file-type icon, a pending spinner,
// Hold/Release/Delete; printer rows carry connect / options / remove
// plus the two-press test page. The default printer wears the accent printer icon. Renaming a printer edits a local
// display alias (click the name; CUPS has no queue rename). A press on
// any empty spot of the card commits an open rename.
//
// NOTE: anchorItem / anchorWindow / barPosition live on the shared
// host, never here - redeclaring them shadows the host wiring and
// silently breaks positioning.
Item {
  id: root

  property int islandContentWidth: 420
  property int islandContentHeight: Math.ceil(contentRoot.bodyHeight) + 2 * Ui.outerPad
  property bool islandSelfAnimating: false
  property var islandHost: null

  // Content lent to the shared host: incubated on show, destroyed after
  // the close fade. The card sizes from contentRoot.bodyHeight above.
    Item {
      id: contentRoot

      anchors.fill: parent

      // Height of the loaded content column; the island's
      // islandContentHeight binding reads it through contentRoot.
      readonly property real bodyHeight: body.implicitHeight

      // Inline rename state, held here (not in the delegate) so a scroll
      // during an edit neither loses it nor double-instantiates editors:
      // exactly one printer is in rename mode, `stagedAlias` carries the
      // text. Empty name = no active editor.
      property string renamingName: ""
      property string stagedAlias: ""

      function commitRename() {
        if (contentRoot.renamingName === "") return
        Svc.Printers.setPrinterAlias(contentRoot.renamingName, contentRoot.stagedAlias)
        contentRoot.renamingName = ""
      }

      function cancelRename() {
        contentRoot.renamingName = ""
      }

      // Commit only when `name` is still the active editor (a stale
      // focus-loss event from a just-replaced editor must not commit the
      // new editor's untouched text).
      function commitIf(name) {
        if (contentRoot.renamingName === name) contentRoot.commitRename()
      }

      // Jobs as shown (the service already minus locally cleared history).
      readonly property var jobs: Svc.Printers.shownJobs
      readonly property var printers: Svc.Printers.printers
      // CUPS down: the island shows the warning block only - every
      // section and hint below the header hides.
      readonly property bool cupsDown: Svc.Printers.cupsHealth === "inactive"
        || Svc.Printers.cupsHealth === "missing"
      // True while any shown job already left the queue (the clear
      // button below has something to do).
      readonly property bool hasHistory: {
        const shown = contentRoot.jobs
        for (let i = 0; i < shown.length; i++)
          if (!Model.isActiveJobState(shown[i]["job-state"])) return true
        return false
      }
      // Queue skeleton window: four rows (Volume/Bluetooth pattern).
      // Live rows fill from the top and static skeleton rows pad the
      // rest, so jobs land on laid-out rows instead of growing the
      // section.
      readonly property int queueWindow: 4
      readonly property var queueFiller: contentRoot._queueFillerRows()
      // Pulse the skeletons only while a reload is in flight with an
      // empty queue; beside real rows they stay fully static.
      readonly property bool queueLoading: Svc.Printers.state === "loading"
        && contentRoot.jobs.length === 0
      function _queueFillerRows() {
        const out = []
        const n = Math.max(0, contentRoot.queueWindow - contentRoot.jobs.length)
        for (let i = 0; i < n; i++) out.push({})
        return out
      }

      // Subtitle under the caps header: the default queue plus the
      // live queue depth.
      readonly property string subtitleText: {
        if (Svc.Printers.printers.length === 0 && Svc.Printers.shownJobs.length === 0)
          return "No printers configured"
        const parts = []
        if (Svc.Printers.printers.length > 0) {
          if (Svc.Printers.defaultPrinter !== "") {
            const alias = Svc.Printers.aliases[Svc.Printers.defaultPrinter]
            parts.push("Default: "
              + (alias !== undefined && alias !== "" ? alias : Svc.Printers.defaultPrinter))
          } else {
            parts.push("No default printer")
          }
        }
        const active = Model.activeJobs(Svc.Printers.shownJobs).length
        if (active > 0) parts.push(active + (active === 1 ? " job" : " jobs"))
        return parts.join(" - ")
      }

      // Click-anywhere commit: sits beneath the content column so real
      // controls and rows keep their own clicks (ArchUpdates pattern).
      // A press on an empty spot commits any open printer rename.
      MouseArea {
        z: -1
        anchors.fill: parent
        onPressed: contentRoot.commitRename()
      }

      Column {
        id: body

        width: parent.width
        spacing: Ui.m

        // Header: section-cap title (lib Title level 2, the caps style
        // the ArchUpdates island uses for its own header) with the
        // leading printer glyph, the muted subtitle underneath, and the
        // two global affordances on the right. Settings opens the CUPS
        // app and closes the island behind it (the new window is the
        // context now); Reload re-reads printers and jobs in place.
        Row {
          width: parent.width
          spacing: Ui.m

          Column {
            width: parent.width - headerBtns.width - parent.spacing
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            Row {
              width: parent.width
              spacing: Ui.s

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "printer"
                colorKey: "foreground_1"
                size: 14
                opacity: 0.7
              }

              Title {
                level: 2
                width: parent.width - Ui.s - 14
                anchors.verticalCenter: parent.verticalCenter
                text: "PRINTERS"
              }
            }

            // Subtitle row: the muted line with the reload spinner ahead
            // of it. While a refresh runs the line reads "Reloading…"
            // so the reload press answers visibly (same asset and loop
            // as the network island's scan indicator).
            Row {
              width: parent.width
              spacing: Ui.s
              visible: Svc.Printers.state === "loading" || contentRoot.subtitleText !== ""

              Icon {
                id: reloadSpin

                visible: Svc.Printers.state === "loading"
                anchors.verticalCenter: parent.verticalCenter
                name: "update"
                colorKey: "foreground_1"
                size: 12
                opacity: 0.7
                transformOrigin: Item.Center

                // Activity feedback, not decoration: the spinner runs while a
                // reload is in flight regardless of the motion policy.
                RotationAnimation on rotation {
                  from: 0
                  to: 360
                  duration: 1000
                  loops: Animation.Infinite
                  running: Svc.Printers.state === "loading"
                  onRunningChanged: if (!running) reloadSpin.rotation = 0
                }
              }

              Title {
                level: 4
                width: parent.width - (reloadSpin.visible ? reloadSpin.width + parent.spacing : 0)
                anchors.verticalCenter: parent.verticalCenter
                text: Svc.Printers.state === "loading" ? "Reloading…" : contentRoot.subtitleText
                elide: Text.ElideRight
              }
            }
          }

          // The pair rides its own tight row: one small gap between the
          // buttons, the outer gap only ahead of the title column.
          Row {
            id: headerBtns

            anchors.verticalCenter: parent.verticalCenter
            spacing: Ui.s

            IconButton {
              id: settingsBtn

              anchors.verticalCenter: parent.verticalCenter
              name: "settings"
              iconSize: 16
              tipText: "Print settings"
              onClicked: {
                Svc.Printers.openPrinterConfig("")
                root.islandHost.close()
              }
            }

            IconButton {
              id: refreshBtn

              anchors.verticalCenter: parent.verticalCenter
              name: "rotate-cw"
              iconSize: 16
              tipText: "Reload printers and jobs"
              // Dims mid-load (the subtitle spinner owns the feedback);
              // the service drops overlapping refreshes anyway.
              enabled: Svc.Printers.state !== "loading"
              onClicked: Svc.Printers.refresh()
            }
          }
        }

        // CUPS liveness: red warning glyph over a plain-language line
        // when neither cups.service nor cups.socket runs (package
        // missing or service down). The empty lists below would
        // otherwise read as "no printers" with no hint why. The text
        // stays the muted body color - only the glyph carries red.
        Column {
          visible: contentRoot.cupsDown
          width: parent.width
          spacing: Ui.s

          Icon {
            anchors.horizontalCenter: parent.horizontalCenter
            name: "warning"
            colorKey: "red"
            size: 28
          }

          Title {
            level: 5
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: Svc.Printers.cupsHealth === "missing"
              ? "No printer service found - install the CUPS package to manage printers"
              : "Printer service is not running - enable cups.service or cups.socket"
          }
        }

        // Refresh-level error (cupsd down) and action-level error (a
        // failed hold/release/cancel, as the IPP status token). The
        // refresh error hides while the health block above owns the
        // story (it would just repeat "cupsd unreachable" under it).
        Title {
          level: 5
          visible: Svc.Printers.errorText !== "" && !contentRoot.cupsDown
          width: parent.width
          text: Svc.Printers.errorText
          color: Ui.solid("red")
        }

        Title {
          level: 5
          visible: Svc.Printers.actionError !== "" && !contentRoot.cupsDown
          width: parent.width
          text: Svc.Printers.actionError
          color: Ui.solid("red")
        }

        // No default printer yet (fresh setup, or the default queue was
        // deleted): point at the link action on a printer row instead of
        // leaving every row's connect button unexplained.
        Title {
          level: 5
          visible: !contentRoot.cupsDown && Svc.Printers.printers.length > 0 && Svc.Printers.defaultPrinter === ""
          width: parent.width
          text: "No default printer - press the link icon on a printer to set it"
          wrapMode: Text.WordWrap
        }

        // Printers section: always visible, even with zero queues - the
        // empty slot reads as a placeholder, never as a missing list.
        // Hidden while CUPS is down (warning owns the island then).
        Column {
          visible: !contentRoot.cupsDown
          width: parent.width
          spacing: Ui.s

          Row {
            spacing: Ui.s

            Icon {
              anchors.verticalCenter: parent.verticalCenter
              name: "printer"
              colorKey: "foreground_1"
              size: 14
              opacity: 0.7
            }

            Title {
              level: 2
              anchors.verticalCenter: parent.verticalCenter
              text: "KNOWN PRINTERS - " + contentRoot.printers.length
            }
          }

          // Empty slot: centered info glyph with the pointer text
          // underneath (no queues yet, or the last one was deleted).
          Column {
            visible: contentRoot.printers.length === 0
            width: parent.width
            spacing: Ui.s

            Icon {
              anchors.horizontalCenter: parent.horizontalCenter
              name: "info"
              colorKey: "foreground_1"
              size: 28
              opacity: 0.3
            }

            Title {
              level: 5
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Known printers will appear here"
            }

            Title {
              level: 5
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Add one in CUPS settings (top-right icon)"
              color: Ui.tint("foreground_1", 0.5)
            }
          }

          List {
            id: printersList

            visible: contentRoot.printers.length > 0
            selectionHighlight: false
            width: parent.width
            height: Math.min(contentHeight, 260)
            stableModel: contentRoot.printers
            spacing: 0
            interactive: contentHeight > height
            delegate: printerDelegate
            clip: true
          }
        }

        // Jobs section: always visible, even with an empty queue - the
        // empty slot reads as a placeholder, never as a missing list.
        // Hidden while CUPS is down (warning owns the island then).
        Column {
          visible: !contentRoot.cupsDown
          width: parent.width
          spacing: Ui.s

          Item {
            width: parent.width
            height: 26

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Ui.s

              Icon {
                anchors.verticalCenter: parent.verticalCenter
                name: "list"
                colorKey: "foreground_1"
                size: 14
                opacity: 0.7
              }

              Title {
                level: 2
                anchors.verticalCenter: parent.verticalCenter
                text: "JOBS - " + contentRoot.jobs.length
              }
            }

            // Clear finished entries: a labeled outline button (default
            // accent, not red). Only finished work clears - in-flight
            // jobs keep their own Delete buttons. Shrunk to the 26px
            // header like the bluetooth refresh button.
            Button {
              visible: contentRoot.hasHistory
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              variant: "outline"
              label: "Clear all"
              height: 22
              implicitHeight: 22
              onClicked: Svc.Printers.dismissFinished()
            }
          }

          List {
            id: jobsList

            visible: contentRoot.jobs.length > 0
            selectionHighlight: false
            width: parent.width
            // Five rows visible at most (rows are 44px); the rest scrolls.
            height: Math.min(contentHeight, 5 * 44)
            stableModel: contentRoot.jobs
            spacing: 0
            interactive: contentHeight > height
            delegate: jobDelegate
            clip: true
          }

          // Filler skeleton rows under the live ones, up to the four-row
          // window shared with the empty state: static whenever real rows
          // are on screen, pulsing only while a reload is in flight with
          // an empty queue (see queueLoading). Discoveries land on rows
          // that are already laid out instead of growing the section.
          Item {
            visible: contentRoot.jobs.length < contentRoot.queueWindow
            width: parent.width
            height: queueFillerList.height

            List {
              id: queueFillerList

              selectionHighlight: false
              width: parent.width
              height: contentHeight
              stableModel: contentRoot.queueFiller
              spacing: 0
              interactive: false
              delegate: queueSkeletonDelegate
              clip: true
              opacity: 0.8
            }

            // Empty overlay: the idle note centered over the dimmed
            // skeletons (Volume empty pattern), so the queue keeps its
            // populated footprint while reading as idle.
            Column {
              visible: contentRoot.jobs.length === 0
              anchors.centerIn: parent
              spacing: Ui.s

              Icon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "list"
                colorKey: "foreground_1"
                size: Math.round(32 * 1.2)
                opacity: 0.7
              }

              Title {
                anchors.horizontalCenter: parent.horizontalCenter
                level: 5
                font.pixelSize: Math.round(Ui.fontS * 1.2)
                text: "Print jobs will appear here"
                color: Ui.tint("foreground_1", 0.6)
              }
            }
          }
        }
      }

      // One job row: zebra band, file-type icon, filename title (led by
      // the green check / red xmark once finished) over generic info,
      // pending spinner, in-flight state, Hold/Release/Delete.
      // Delete cancels in-flight jobs on the server and clears finished
      // entries locally. Layout is anchor-based (Bluetooth row pattern):
      // the identity column stretches between the icon and the right
      // cluster, so long names elide instead of squeezing the subtext
      // out.
      Component {
        id: jobDelegate

        Item {
          id: jobRow

          required property var modelData
          required property int index

          // Named jobState: `state` is the QQuickItem state machine.
          // Normalized through the lib: the -tv report spells states
          // out ("completed", "pending-held"), never as numbers.
          readonly property int jobState: Model.jobStateNum(jobRow.modelData["job-state"])
          readonly property bool active: Model.isActiveJobState(jobRow.jobState)
          readonly property bool pending: Model.jobIsPending(jobRow.jobState)
          readonly property bool processing: Model.jobIsProcessing(jobRow.jobState)
          readonly property bool done: Model.jobIsDone(jobRow.jobState)
          readonly property bool failed: Model.jobIsFailed(jobRow.jobState)

          width: ListView.view ? ListView.view.width : 0
          height: 44

          // Decorative zebra band: the row itself is not a control, the
          // buttons inside carry the clicks.
          ZebraRow {
            anchors.fill: parent
            rowIndex: jobRow.index
            interactive: false
          }

          // Leading file icon, picked from the document extension
          // (clipboard file-* tables).
          Icon {
            id: leadIcon

            anchors.left: parent.left
            anchors.leftMargin: Ui.s
            anchors.verticalCenter: parent.verticalCenter
            name: Model.jobFileIcon(jobRow.modelData)
            colorKey: "foreground_0"
            size: 16
          }

          Column {
            anchors.left: leadIcon.right
            anchors.leftMargin: Ui.m
            anchors.right: rightCluster.left
            anchors.rightMargin: Ui.m
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            // Title line: finished rows lead with the status glyph (green
            // check / red xmark), processing rows with the yellow spinning
            // update - all in the same slot ahead of the filename,
            // cheaper than the text labels they replace.
            Row {
              width: parent.width
              spacing: Ui.s

              Icon {
                id: statusIcon

                visible: jobRow.done || jobRow.failed || jobRow.processing
                anchors.verticalCenter: parent.verticalCenter
                name: jobRow.processing ? "update" : (jobRow.done ? "check" : "xmark")
                colorKey: jobRow.processing ? "yellow" : (jobRow.done ? "green" : "red")
                size: 12
                transformOrigin: Item.Center

                RotationAnimation on rotation {
                  from: 0
                  to: 360
                  duration: 1000
                  loops: Animation.Infinite
                  running: jobRow.processing
                  onRunningChanged: if (!running) statusIcon.rotation = 0
                }
              }

              Title {
                level: 3
                width: parent.width - (statusIcon.visible ? statusIcon.width + parent.spacing : 0)
                anchors.verticalCenter: parent.verticalCenter
                text: Model.jobTitle(jobRow.modelData)
                color: Ui.solid("foreground_0")
                font.bold: true
              }
            }

            Title {
              level: 4
              width: parent.width
              text: Model.jobSub(jobRow.modelData, Svc.Printers.aliases)
            }
          }

          // Right cluster: pending spinner, state label, actions. The
          // Row skips invisible children, so hidden buttons cost no
          // width and the identity column above goes full-bleed.
          Row {
            id: rightCluster

            anchors.right: parent.right
            anchors.rightMargin: Ui.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: Ui.s

            // Scheduled (pending) jobs spin the shared update glyph -
            // the network island's scan indicator, same asset, same
            // one-second loop.
            Icon {
              id: pendingSpin

              visible: jobRow.pending
              anchors.verticalCenter: parent.verticalCenter
              name: "update"
              colorKey: "foreground_1"
              size: 14
              opacity: 0.7
              transformOrigin: Item.Center

              RotationAnimation on rotation {
                from: 0
                to: 360
                duration: 1000
                loops: Animation.Infinite
                running: jobRow.pending
                onRunningChanged: if (!running) pendingSpin.rotation = 0
              }
            }

            // In-flight state, except processing (the title spinner says
            // that); anything unparseable hides instead of printing
            // "Unknown".
            Title {
              id: stateLabel

              level: 4
              visible: jobRow.active && !jobRow.processing
              anchors.verticalCenter: parent.verticalCenter
              text: Model.jobStateLabel(jobRow.modelData["job-state"])
              color: Ui.tint("foreground_1", 0.7)
              font.bold: true
            }

            // Hold: pending/stopped (already held = no-op; processing
            // rows spin instead of offering it).
            IconButton {
              visible: jobRow.active && jobRow.jobState !== 4 && !jobRow.processing
              anchors.verticalCenter: parent.verticalCenter
              name: "hourglass"
              iconSize: 14
              faint: true
              tipText: "Hold job"
              onClicked: {
                const printer = String(jobRow.modelData.printer ?? "")
                const id = String(jobRow.modelData["job-id"] ?? "")
                Svc.Printers.holdJob(printer, id)
              }
            }

            // Release: held only (already queued = no-op).
            IconButton {
              visible: jobRow.active && jobRow.jobState === 4
              anchors.verticalCenter: parent.verticalCenter
              name: "check"
              iconSize: 14
              faint: true
              tipText: "Release job"
              onClicked: {
                const printer = String(jobRow.modelData.printer ?? "")
                const id = String(jobRow.modelData["job-id"] ?? "")
                Svc.Printers.releaseJob(printer, id)
              }
            }

            // Delete: in-flight jobs cancel on the server, finished
            // entries clear locally (CUPS has no unprivileged history
            // delete) - trash glyph, same convention as the
            // notification island's remove affordance.
            IconButton {
              anchors.verticalCenter: parent.verticalCenter
              name: "remove"
              iconSize: 14
              colorKey: "red"
              tipText: jobRow.active ? "Cancel job" : "Clear job"
              onClicked: {
                const printer = String(jobRow.modelData.printer ?? "")
                const id = String(jobRow.modelData["job-id"] ?? "")
                // The job id and the queue, never the job title: a filename
                // is unbounded free text and this is a record of the action,
                // not of the document.
                if (jobRow.active) {
                  Svc.Printers.cancelJob(printer, id)
                } else {
                  Svc.Printers.dismissJob(id)
                }
              }
            }
          }
        }
      }

      // Queue skeleton row: a 44px mock of one job row - file-icon slot,
      // title bar over subtext bar, state bar plus action-icon slot on
      // the right (the job row's anchor pattern: icon left, actions
      // right, identity stretched between). Bars pulse on the shared
      // stagger only while a reload is in flight with an empty queue
      // (contentRoot.queueLoading); beside real rows they are fully
      // static, like the bluetooth fillers. Chrome matches the island
      // skeletons: tint @0.13/0.14/0.10, 0.55 shared opacity, 2px corners.
      Component {
        id: queueSkeletonDelegate

        Item {
          id: skeletonRow

          required property int index
          width: ListView.view ? ListView.view.width : 0
          height: 44

          Rectangle {
            id: leadMock

            anchors.left: parent.left
            anchors.leftMargin: Ui.s
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            radius: RoundingPolicy.radius
            color: Ui.tint("foreground_1", 0.13)
            opacity: 0.55

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: contentRoot.queueLoading && MotionPolicy.enabled
              SkeletonPulse { index: skeletonRow.index }
            }
          }

          Row {
            id: rightMock

            anchors.right: parent.right
            anchors.rightMargin: Ui.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: Ui.s

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 36
              height: 8
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_1", 0.10)
              opacity: 0.55

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: contentRoot.queueLoading && MotionPolicy.enabled
                SkeletonPulse { index: skeletonRow.index; offset: 75 }
              }
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 14
              height: 14
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_1", 0.13)
              opacity: 0.55

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: contentRoot.queueLoading && MotionPolicy.enabled
                SkeletonPulse { index: skeletonRow.index; offset: 75 }
              }
            }
          }

          Column {
            anchors.left: leadMock.right
            anchors.leftMargin: Ui.m
            anchors.right: rightMock.left
            anchors.rightMargin: Ui.m
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Rectangle {
              width: parent.width * (0.52 + ((Number(skeletonRow.index) || 0) % 2) * 0.2)
              height: 8
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_1", 0.14)
              opacity: 0.55

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: contentRoot.queueLoading && MotionPolicy.enabled
                SkeletonPulse { index: skeletonRow.index }
              }
            }

            Rectangle {
              width: parent.width * 0.72
              height: 6
              radius: RoundingPolicy.radius
              color: Ui.tint("foreground_1", 0.10)
              opacity: 0.55

              SequentialAnimation on opacity {
                loops: Animation.Infinite
                running: contentRoot.queueLoading && MotionPolicy.enabled
                SkeletonPulse { index: skeletonRow.index; offset: 150 }
              }
            }
          }
        }
      }

      // One printer row: zebra band, queue glyph, display name (click to
      // rename as a local alias), state/offline/ink lines, and the action
      // row. Test page lives on the default row only and needs two
      // presses within 3 s (the glyph turns yellow while armed).
      Component {
        id: printerDelegate

        Item {
          id: printerRow

          required property var modelData
          required property int index

          readonly property string name: String(modelData["printer-name"] ?? "")
          readonly property string display: Model.displayName(modelData, Svc.Printers.aliases)
          readonly property bool isDefault: printerRow.name !== "" && printerRow.name === Svc.Printers.defaultPrinter
          readonly property bool down: Model.printerIsDown(modelData)
          readonly property bool offline: Model.printerIsOffline(modelData)
          readonly property var inks: Model.markers(modelData)
          readonly property bool testArmed: Svc.Printers.testArm === printerRow.name
          // Guarded against "": an empty queue name never matches the
          // idle editor state, so no row can sit in rename mode unasked.
          readonly property bool renaming: contentRoot.renamingName !== ""
            && contentRoot.renamingName === printerRow.name

          width: ListView.view ? ListView.view.width : 0
          height: 48

          ZebraRow {
            anchors.fill: parent
            rowIndex: printerRow.index
            interactive: false
          }

          Row {
            anchors.fill: parent
            anchors.leftMargin: Ui.s
            anchors.rightMargin: Ui.s
            spacing: Ui.m

            // Queue glyph: printer-error two-tone (red xmark) while the
            // queue is stopped or not accepting, muted printer while the
            // printer itself is offline, the accent printer while this is
            // the default queue, plain printer otherwise.
            Icon {
              id: queueIcon

              anchors.verticalCenter: parent.verticalCenter
              name: printerRow.down ? "printer-error" : "printer"
              colorKey: printerRow.down ? "foreground_0"
                : (printerRow.offline ? "foreground_1"
                  : (printerRow.isDefault ? "accent" : "foreground_0"))
              accentKey: printerRow.down ? "red" : ""
              size: 16
              opacity: printerRow.offline ? 0.6 : 1
            }

            Column {
              id: identityCol

              width: parent.width - queueIcon.width - actionsCol.width - 2 * parent.spacing
              anchors.verticalCenter: parent.verticalCenter
              spacing: 2
              // Offline queues gray out (identity side only - the action
              // buttons stay fully legible).
              opacity: printerRow.offline ? 0.5 : 1

              // Name line: the display title and its rename field share one
              // fixed box - renaming swaps the paint, never the geometry,
              // so the row (and the island) never jumps. The field wears
              // no box chrome (transparent ground, no border, title type),
              // so it reads as the name itself, editable.
              Item {
                width: parent.width
                height: nameLabel.implicitHeight

                Title {
                  id: nameLabel

                  level: 3
                  visible: !printerRow.renaming
                  anchors.left: parent.left
                  anchors.right: parent.right
                  text: printerRow.display
                  color: printerRow.isDefault ? Ui.solid("foreground_0") : Ui.solid("foreground_1")
                  font.bold: printerRow.isDefault
                }

                InputField {
                  id: renameField

                  visible: printerRow.renaming
                  anchors.fill: parent
                  fontSize: Ui.fontS
                  clearable: false
                  // Zero text inset: the field's text must start exactly
                  // where the title's does, or entering rename mode
                  // visibly shifts the line right.
                  basePadding: 0
                  color: "transparent"
                  border.width: 0
                  text: contentRoot.stagedAlias
                  onEdited: t => contentRoot.stagedAlias = t
                  onAccepted: contentRoot.commitRename()
                  onEscaped: contentRoot.cancelRename()

                  // Commit on focus loss (click anywhere else in the
                  // card); guarded so a replaced editor never commits
                  // twice.
                  Connections {
                    target: renameField.input

                    function onActiveFocusChanged() {
                      if (!renameField.input.activeFocus) contentRoot.commitIf(printerRow.name)
                    }
                  }
                }

                MouseArea {
                  id: nameHover

                  visible: !printerRow.renaming
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    contentRoot.commitRename()
                    contentRoot.stagedAlias = printerRow.display
                    contentRoot.renamingName = printerRow.name
                    Qt.callLater(renameField.grabFocus)
                  }
                }
              }

              // State line: short state + reasons only (the make/model
              // string never fit and crowded the row out). Offline queues
              // read the generic "Offline" instead.
              Title {
                level: 4
                width: parent.width
                text: printerRow.offline ? "Offline" : Model.printerLine(printerRow.modelData)
              }

              Title {
                level: 4
                width: parent.width
                visible: printerRow.inks.length > 0
                text: {
                  const parts = []
                  for (let i = 0; i < printerRow.inks.length; i++)
                    parts.push(printerRow.inks[i].name + " " + printerRow.inks[i].level + "%")
                  return parts.join(" - ")
                }
              }
            }

            // Action row: every control in one line - connect (unless
            // default), options, remove, and the two-press test page on
            // the default queue. The default queue needs no marker here -
            // its printer icon already wears the accent color.
            Row {
              id: actionsCol

              anchors.verticalCenter: parent.verticalCenter
              spacing: Ui.s

              // Connect = set the user default (lpoptions -d); hidden
              // while already default.
              IconButton {
                visible: !printerRow.isDefault
                width: 14
                height: 14
                name: "link"
                iconSize: 14
                faint: true
                tipText: "Set as default"
                  onClicked: {
                  Svc.Printers.connectPrinter(printerRow.name)
                }
              }

              // This queue's own options page (the header button opens
              // the app's main page instead). Closes the island: the
              // new window is the context now.
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                name: "settings"
                iconSize: 14
                faint: true
                tipText: "Printer options for " + printerRow.display
                  onClicked: {
                  Svc.Printers.openPrinterConfig(printerRow.name)
                  root.islandHost.close()
                }
              }

              // Remove the queue (lpadmin -x, user-privileged).
              IconButton {
                anchors.verticalCenter: parent.verticalCenter
                name: "remove"
                iconSize: 14
                colorKey: "red"
                tipText: "Remove printer"
                  onClicked: {
                  Svc.Printers.removePrinter(printerRow.name)
                }
              }

              // Two-press test page (default printer only): first press
              // arms, second within 3 s prints. While armed the button
              // wears its hovered look so the pending confirm reads.
              IconButton {
                visible: printerRow.isDefault
                anchors.verticalCenter: parent.verticalCenter
                name: "file"
                iconSize: 14
                colorKey: printerRow.testArmed ? "yellow" : "foreground_0"
                forceHover: printerRow.testArmed
                tipText: printerRow.testArmed ? "Press again to print the test page" : "Print test page"
                  onClicked: {
                  if (printerRow.testArmed) {
                    Svc.Printers.printTestPage(printerRow.name)
                  } else {
                    Svc.Printers.armTestPage(printerRow.name)
                  }
                }
              }
            }
          }
        }
      }
    }
}
