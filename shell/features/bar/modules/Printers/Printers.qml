pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import qs.common
import qs.services as Svc
import qs.features.bar
import "../../../../services/system/PrintersLib.js" as Model

// Printers bar module. One slot in the right zone, always shown while the
// slot is enabled: a box with no printing set up (or a VM, which has none at
// all) still gets the icon, and the island explains the state and offers the
// way out. Nothing here is hidden - the module is the entry point to that
// explanation.
// Icon states (printer.* assets only, all static - no blinking):
//   printer-error (red xmark) - at least one job failed / queue stopped
//   printer (yellow page) - a job is printing right now
//   printer - jobs queued but nothing printing, or idle
//   printer-check (green check) - all done, queue cleared since
CollapsibleSlot {
  id: root

  readonly property bool vmUnavailable: Quickshell.env("CHASSIS_TYPE") === "vm"
  readonly property bool printerDown: Svc.Printers.printers.some(p => Model.printerIsDown(p))
  readonly property bool failed: Svc.Printers.anyFailed
  readonly property string iconName: root.failed || root.printerDown ? "printer-error"
    : Svc.Printers.allDone ? "printer-check"
    : "printer"
  readonly property string iconAccent: root.failed || root.printerDown ? "red"
    : Svc.Printers.anyPrinting ? "yellow"
    : Svc.Printers.allDone ? "green" : ""

  // One pass over the shown queue, shared by the two consumers below. It
  // reports the four tooltip buckets and the live depth together, so the
  // queue is walked once per change rather than once per binding - and the
  // active count is a counter rather than the length of a full filtered
  // copy of the queue built to be measured and thrown away.
  //
  // `active` is the Model.activeJobs rule (in-flight states 3..6) spelled
  // as a tally: pending and processing are their own buckets, and the
  // states they do not cover - held, processing-stopped - fall through to
  // Model.isActiveJobState, so every in-flight state is counted exactly
  // once and no finished state is counted at all.
  readonly property var jobBuckets: {
    const jobs = Svc.Printers.shownJobs ?? []
    let scheduled = 0
    let processing = 0
    let done = 0
    let failed = 0
    let active = 0
    for (let i = 0; i < jobs.length; i++) {
      const st = jobs[i]["job-state"]
      if (Model.jobIsPending(st)) {
        scheduled++
        active++
      } else if (Model.jobIsProcessing(st)) {
        processing++
        active++
      } else if (Model.jobIsDone(st)) {
        done++
      } else if (Model.jobIsFailed(st)) {
        failed++
      } else if (Model.isActiveJobState(st)) {
        active++
      }
    }
    return { scheduled, processing, done, failed, active }
  }

  // Live active-job count (history rows excluded): the bubble reports
  // the queue, not the archive.
  readonly property int activeJobCount: root.jobBuckets.active
  // Tooltip detail rows ({icon, text}, the weather convention): one row
  // per printer (alias, state line, default mark) plus one row per
  // nonzero job bucket over the shown queue.
  readonly property var tipLines: {
    // A VM has no CUPS at all (the service never refreshes there), so the
    // queue lines would only say "no printers" without the reason.
    if (root.vmUnavailable) return [{ icon: "printer", text: "Printing is not available in a virtual machine" }]
    const rows = []
    const printers = Svc.Printers.printers ?? []
    for (let i = 0; i < printers.length; i++) {
      const p = printers[i]
      const name = Model.displayName(p, Svc.Printers.aliases)
      const state = Model.printerIsOffline(p) ? "Offline" : Model.printerLine(p)
      const def = String(p["printer-name"] ?? "") !== ""
        && String(p["printer-name"]) === String(Svc.Printers.defaultPrinter ?? "")
        ? " (default)" : ""
      rows.push({
        icon: Model.printerIsDown(p) ? "printer-error" : "printer",
        text: name + " - " + state + def
      })
    }
    if (rows.length === 0) rows.push({ icon: "printer", text: "No printers" })
    const b = root.jobBuckets
    if (b.scheduled > 0) rows.push({ icon: "hourglass", text: b.scheduled + " scheduled" })
    if (b.processing > 0) rows.push({ icon: "printer", text: b.processing + " processing" })
    if (b.done > 0) rows.push({ icon: "check", text: b.done + " done" })
    if (b.failed > 0) rows.push({ icon: "xmark", text: b.failed + " failed" })
    return rows
  }
  // Collapsible slot (see CollapsibleSlot.qml): always in the row while the
  // slot is enabled. The island, not the bar, is where a missing service or
  // queue is explained.
  collapseShown: true

  Icon {
    anchors.centerIn: parent
    name: root.iconName
    colorKey: "foreground_0"
    accentKey: root.iconAccent
  }

  fillButtons: Qt.LeftButton
  onClicked: mouse => root.openIsland()

  ToolTipBind {
    active: root.hovered && !root.barWindow.islandHost.isOpenFor(root)
    text: root.vmUnavailable ? "Printers - not available in a VM"
      : root.failed || root.printerDown ? "Printers - attention"
      : Svc.Printers.anyPrinting ? "Printers - printing"
      : Svc.Printers.hasActiveJobs ? "Printers - " + root.activeJobCount + (root.activeJobCount === 1 ? " job" : " jobs")
      : Svc.Printers.state === "error" ? "Printers - unreachable" : "Printers"
    lines: root.tipLines
    anchor: root
    barWindow: root.barWindow
    host: root.barWindow ? root.barWindow.toolTipHost : null
  }

  Component {
    id: islandComp

    PrintersIsland {}
  }

  // The island this module opens, declared on the base so openIsland()
  // below is the single call every click handler makes.
  islandComponent: islandComp
}
