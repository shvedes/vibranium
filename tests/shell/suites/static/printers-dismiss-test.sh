#!/bin/bash
# Suite: printers-dismiss - one cleared job must light the all-done verdict.
#
# Printers is a `pragma Singleton` service: the construction suite pins
# qs.services.Printers as needs-environment (no PanelWindow backend under
# QT_QPA_PLATFORM=offscreen), so it cannot be instantiated headlessly. What CAN
# be checked without a compositor is the mutation path itself, so this suite
# lifts the real dismiss functions out of Printers.qml and evaluates them
# against minimal stubs - the same lift-and-evaluate approach
# lockscreen-grace-test.sh uses for its grace functions.
#
# The defect: dismissJob() assigns root.dismissed and saves, then calls
# root._maybeAllDone(next) with a `next` it never declared. In non-strict QML JS
# that resolves as an undeclared global and throws a ReferenceError, so the
# verdict never lights for a single finished job and the rest of the click
# handler can abort - while the IPC dismiss verb still returns "ok".
# dismissFinished() declares `next` correctly. Both verbs must share one
# mutation boundary that assigns, saves, and calls _maybeAllDone with the
# freshly built map (whose bindings have not settled yet).

source "$(dirname "${BASH_SOURCE[0]}")/../../lib/lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../../lib/harness.sh"

t_init "printers-dismiss" "a single-job dismiss lights all-done and the two verbs share one commit"

require_tools node

PRINTERS="$SHELL_DIR/services/system/Printers.qml"
t_file "the dismiss logic lives in the printers service" "$PRINTERS"

# --- lift and evaluate the mutation functions -------------------------------

RESULTS="$(PRINTERS="$PRINTERS" node - <<'NODE'
const fs = require("fs")
const src = fs.readFileSync(process.env.PRINTERS, "utf8")

// A function by name, balanced to its closing brace. Reading it from the
// source rather than restating it here means a change to the logic is what
// this suite measures. opt=true returns "" when the function is absent (the
// shared boundary does not exist on the buggy tree).
function lift(name, opt) {
  const m = new RegExp("function\\s+" + name + "\\s*\\([^)]*\\)\\s*\\{").exec(src)
  if (!m) {
    if (opt) return ""
    throw new Error("no function " + name)
  }
  let depth = 0
  let end = m.index + m[0].length - 1
  for (; end < src.length; end++) {
    const c = src[end]
    if (c === "{") depth++
    else if (c === "}") { depth--; if (depth === 0) { end++; break } }
  }
  return src.slice(m.index, end)
}

const srcs = {
  dismissJob: lift("dismissJob", false),
  dismissFinished: lift("dismissFinished", false),
  _maybeAllDone: lift("_maybeAllDone", false),
  _commitDismissed: lift("_commitDismissed", true),
}

// Stubs for the whole world these functions touch. The Model projection is
// kept faithful to PrintersLib's contract so the verdict is computed, not
// assumed: a dismissed row is filtered out, an active row keeps active=true,
// and a down printer is the failed fallback for an empty shown list.
const activeStates = new Set(["processing", "canceling"])
const failedStates = new Set(["cancelled", "aborted"])
const Model = {
  isActiveJobState: (s) => activeStates.has(s),
  filterDismissed: (jobs, dismissed) =>
    jobs.filter((j) => !Object.prototype.hasOwnProperty.call(dismissed, String(j["job-id"]))),
  activeJobs: (jobs) => jobs.filter((j) => activeStates.has(j["job-state"])),
  failedJobs: (jobs) => jobs.some((j) => failedStates.has(j["job-state"])),
  printerIsDown: (p) => p.down === true,
}
const EntryMap = {
  withEntry: (map, key, value) => {
    const next = Object.assign({}, map)
    next[key] = value
    return next
  },
}

let saves = 0
let maybeCalls = 0
let captured = []
const ShellState = { updateSection: () => { saves++ } }

const body = Object.values(srcs).filter(Boolean).join("\n") +
  "\nreturn { dismissJob, dismissFinished, _maybeAllDone, " +
  "_commitDismissed: typeof _commitDismissed !== 'undefined' ? _commitDismissed : undefined }"

// The lifted functions read `root` as a free variable, so the SAME object must
// be handed to new Function below and mutated in the scenarios above it.
const root = {
  jobs: [],
  printers: [],
  dismissed: {},
  _recentlyDone: false,
  _saveDismissed: () => { saves++ },
  _maybeAllDone(next) {
    maybeCalls++
    captured.push(next)
    return root._maybeAllDoneImpl(next)
  },
}
const api = new Function("root", "EntryMap", "Model", "ShellState", body)(
  root, EntryMap, Model, ShellState)
root._maybeAllDoneImpl = api._maybeAllDone
if (api._commitDismissed) root._commitDismissed = api._commitDismissed
root.dismissJob = api.dismissJob
root.dismissFinished = api.dismissFinished

const reset = () => { saves = 0; maybeCalls = 0; captured = []; root._recentlyDone = false; root.dismissed = {} }
const out = {}

// One finished job, one healthy printer: clearing it leaves nothing shown, so
// the verdict must light. On the buggy tree dismissJob throws before the
// verdict is computed.
reset()
root.jobs = [{ "job-id": 42, "job-state": "completed" }]
root.printers = [{ name: "P", down: false }]
let threw = false
let errName = ""
try { root.dismissJob(42) } catch (e) { threw = true; errName = e && e.name ? e.name : "throw" }
out.jobThrew = threw
out.jobError = errName
out.jobDismissed = root.dismissed["42"] === true
out.jobSaveCalls = saves
out.jobMaybeCalls = maybeCalls
out.jobMaybeArg42 = captured.length > 0 && captured[0]["42"] === true
out.jobRecentDone = root._recentlyDone
out.hasCommit = typeof root._commitDismissed === "function"

// The header verb must take the same path and light the same verdict.
reset()
root.jobs = [{ "job-id": 42, "job-state": "completed" }]
root.printers = [{ name: "P", down: false }]
threw = false
try { root.dismissFinished() } catch (e) { threw = true }
out.finishedThrew = threw
out.finishedDismissed = root.dismissed["42"] === true
out.finishedSaveCalls = saves
out.finishedMaybeCalls = maybeCalls
out.finishedRecentDone = root._recentlyDone

// Refusals must not mutate, save, or publish a verdict.
reset()
root.jobs = [{ "job-id": 7, "job-state": "processing" }]
root.printers = [{ name: "P", down: false }]
root.dismissJob(7)
out.activeRefused = Object.keys(root.dismissed).length === 0 && saves === 0 && maybeCalls === 0

reset()
root.jobs = [{ "job-id": 42, "job-state": "completed" }]
root.dismissJob("")
root.dismissJob(999)
out.missingRefused = Object.keys(root.dismissed).length === 0 && saves === 0 && maybeCalls === 0

for (const k of Object.keys(out)) process.stdout.write(k + "=" + out[k] + "\n")
NODE
)" || { t_block "node could not evaluate the dismiss functions"; }

declare -A R
while IFS='=' read -r key value; do
  [[ -n $key ]] && R["$key"]="$value"
done <<<"$RESULTS"

t_section "a single finished-job dismiss commits and lights the verdict"
t_eq "dismissJob does not throw" "false" "${R[jobThrew]}"
t_eq "the dismissed row is recorded" "true" "${R[jobDismissed]}"
t_eq "the dismissed map is saved exactly once" "1" "${R[jobSaveCalls]}"
t_eq "_maybeAllDone is called exactly once" "1" "${R[jobMaybeCalls]}"
t_eq "_maybeAllDone receives the freshly built map" "true" "${R[jobMaybeArg42]}"
t_eq "the all-done verdict lights" "true" "${R[jobRecentDone]}"

t_section "both verbs share one mutation boundary"
t_eq "a shared _commitDismissed boundary exists" "true" "${R[hasCommit]}"
t_eq "dismissFinished does not throw" "false" "${R[finishedThrew]}"
t_eq "dismissFinished records the row" "true" "${R[finishedDismissed]}"
t_eq "dismissFinished saves exactly once" "1" "${R[finishedSaveCalls]}"
t_eq "dismissFinished publishes one verdict" "1" "${R[finishedMaybeCalls]}"
t_eq "dismissFinished lights the same verdict" "true" "${R[finishedRecentDone]}"

t_section "refused dismisses do nothing"
t_eq "an active job is not hidden" "true" "${R[activeRefused]}"
t_eq "an empty id or an unknown job is refused" "true" "${R[missingRefused]}"

t_note "Printers is a needs-environment Singleton, so the full service cannot be built under offscreen Qt. The real functions are lifted from source and run against stubbed Model/EntryMap/ShellState; this reproduces the exact ReferenceError the undeclared 'next' raises in the live click handler."

t_summary
