.pragma library

.import "../../common/theme/FileIcons.js" as FileIcons
.import "../../common/text/Format.js" as Format
// Pure helpers for the Printers service and bar module: ipptool -tv report
// parsing, state-label formatting, filtering. No Qt imports - node's vm
// hosts it exactly like QJSEngine does (the
// tests/shell/suites/js/services-calendar-weather.test.mjs harness).

// Parse an `ipptool -tv` report. Returns rows for the objects the response
// carries: response groups are delimited by `-- separator --` lines, every
// attribute inside one group belongs to that group's row (attribute order
// within a group is the server's, NOT the anchor's - printer-state
// precedes printer-name, job-printer-uri precedes job-id). A repeated
// attribute inside one group becomes an array in insertion order. Groups
// that never saw the anchor (an error response's status-message and
// friends) are dropped, or every failure would render one ghost entry.
// Response section only (lines after the [PASS]/[FAIL] marker).
// Returns [] when nothing parsed.
//
// Structured input first: a JSON array of row objects is accepted
// verbatim (normalized through the same anchor/cap rule below), so a
// caller that already holds structured rows never re-renders them as
// text to be re-scraped. The wire itself has no JSON mode (ipptool
// offers -X plist, -c CSV and -t text only), so the text branch is the
// live one and stays byte-identical.
function parseReport(text, anchorAttr) {
  if (typeof text === "string") {
    const trimmed = text.trim()
    if (trimmed.charAt(0) === "[") {
      try {
        const arr = JSON.parse(trimmed)
        if (Array.isArray(arr)) return _normalizeRows(arr, anchorAttr)
      } catch (ignored) {
        // Not JSON - fall through to the text report below.
      }
    }
  } else if (Array.isArray(text)) {
    return _normalizeRows(text, anchorAttr)
  }
  const rows = []
  if (!text) return rows
  const lines = String(text).split("\n")
  // Type tokens are CamelCase (nameWithoutLanguage, naturalLanguage...).
  const attrRe = /^\s+([a-zA-Z0-9-]+)(?: \(([A-Za-z0-9 -]+)\) )?= (.*)$/
  let row = null
  let inResponse = false
  for (let i = 0; i < lines.length; i++) {    const line = lines[i]
    if (!inResponse) {
      // The response section starts at the [PASS]/[FAIL] verdict line.
      if (line.indexOf("[PASS]") !== -1 || line.indexOf("[FAIL]") !== -1) inResponse = true
      continue
    }
    // Object group boundary: close the open row and start a new one.
    if (/^\s*-- separator --\s*$/.test(line)) {
      if (row !== null) {
        rows.push(row)
        row = null
      }
      continue
    }
    const m = attrRe.exec(line)
    if (!m) continue
    const name = m[1]
    const value = m[3]
    if (row === null) row = {}
    if (row[name] !== undefined) {
      // Repeated attribute within one open row: scalar folds into an array.
      if (Array.isArray(row[name])) row[name].push(value)
      else row[name] = [row[name], value]
    } else {
      row[name] = value
    }
  }
  if (row !== null) rows.push(row)
  // Anchorless rows are error-response strays, never objects.
  return rows.filter(r => r[anchorAttr] !== undefined)
}

// Shared anchor/cap rule for both input shapes: keep rows carrying the
// anchor attribute, drop the rest. Structured rows pass through
// untouched (no field caps - a JSON caller owns its lengths).
function _normalizeRows(arr, anchorAttr) {
  const out = []
  for (let i = 0; i < arr.length; i++) {
    const r = arr[i]
    if (r === null || typeof r !== "object" || Array.isArray(r)) continue
    if (r[anchorAttr] === undefined) continue
    out.push(r)
  }
  return out
}

// Extract the status-code token from a report ("successful-ok",
// "client-error-not-authenticated", ...). Empty string when absent.
function statusCode(text) {
  if (!text) return ""
  const m = /\bstatus-code = ([a-z-]+)/.exec(String(text))
  return m ? m[1] : ""
}

// ipptool -tv renders state enums SYMBOLICALLY ("idle", "processing",
// "pending-held", "completed" - never 3/4/5/9), so every state read in
// this lib, the service and the delegates goes through these
// normalizers. Plain integers pass through, names map to their number,
// anything else is NaN (callers render blank, never "Unknown").
const JOB_STATES = {
  pending: 3, "pending-held": 4, held: 4,
  processing: 5, "processing-stopped": 6, stopped: 6,
  canceled: 7, cancelled: 7, aborted: 8, completed: 9
}
const PRINTER_STATES = { idle: 3, processing: 4, stopped: 5 }

function numState(value, table) {
  const n = parseInt(String(value ?? ""), 10)
  if (isFinite(n)) return n
  const t = String(value ?? "").trim().toLowerCase()
  return table[t] !== undefined ? table[t] : NaN
}

function jobStateNum(value) {
  return numState(value, JOB_STATES)
}

function printerStateNum(value) {
  return numState(value, PRINTER_STATES)
}

// True when printer-state parses to 5 (stopped) or
// printer-is-accepting-jobs parses to false - and the queue is not
// merely offline (an unplugged printer reads stopped too; it gets the
// calm gray treatment instead of the red attention icon).
// String-tolerant (the -tv report carries everything as strings).
function printerIsDown(row) {
  if (!row) return false
  if (printerIsOffline(row)) return false
  if (printerStateNum(row["printer-state"]) === 5) return true
  if (String(row["printer-is-accepting-jobs"]) === "false") return true
  return false
}

// True when CUPS reports the printer itself unreachable (an "offline"
// token in the state reasons or the state message). Drives the grayed
// row + generic "Offline" subtext; kept separate from printerIsDown so
// an unplugged printer never trips the red attention icon.
function printerIsOffline(row) {
  if (!row) return false
  const parts = []
  let reasons = row["printer-state-reasons"]
  if (Array.isArray(reasons)) reasons = reasons.join(" ")
  parts.push(String(reasons || ""))
  parts.push(String(row["printer-state-message"] || ""))
  parts.push(String(row["cups-printer-state-message"] || ""))
  return /offline/i.test(parts.join(" "))
}

// "3" | 3 | "idle" -> "Idle" / "Processing" / "Stopped"
function printerStateLabel(state) {
  switch (printerStateNum(state)) {
    case 3: return "Idle"
    case 4: return "Printing"
    case 5: return "Stopped"
    default: return "Unknown"
  }
}

// "3".."9" (or their names) -> Pending / Held / Processing / Stopped /
// Canceled / Aborted / Completed
function jobStateLabel(state) {
  switch (jobStateNum(state)) {
    case 3: return "Pending"
    case 4: return "Held"
    case 5: return "Processing"
    case 6: return "Stopped"
    case 7: return "Canceled"
    case 8: return "Aborted"
    case 9: return "Completed"
    default: return "Unknown"
  }
}

// Human one-liner for a printer row: state label + reasons
// ("Stopped - paused", "Idle - toner-low", "Idle").
function printerLine(row) {
  const label = printerStateLabel(row["printer-state"])
  let reasons = row["printer-state-reasons"]
  if (Array.isArray(reasons)) reasons = reasons.join(", ")
  reasons = String(reasons || "").trim()
  if (reasons === "" || reasons === "none") return label
  return label + " - " + reasons
}

// Pair marker-names/marker-levels into [{name, level}] (both arrive as
// repeated attributes, i.e. arrays after parseReport).
function markers(row) {
  const names = row["marker-names"]
  const levels = row["marker-levels"]
  if (names === undefined || levels === undefined) return []
  const nameList = Array.isArray(names) ? names : [names]
  const levelList = Array.isArray(levels) ? levels : [levels]
  const out = []
  const n = Math.min(nameList.length, levelList.length)
  for (let i = 0; i < n; i++) {
    out.push({
      // CUPS writes ink names with escaped spaces ("Black\ ink").
      name: String(nameList[i]).replace(/\\ /g, " "),
      level: Math.round(Number(levelList[i]))
    })
  }
  return out
}

// Local display aliases, namespaced in shell.jsonc (ShellState section
// "printers"). All helpers tolerate missing/absent sections and objects.
function aliasesFrom(sectionObj) {
  const s = sectionObj && typeof sectionObj === "object" ? sectionObj.aliases : undefined
  if (!s || typeof s !== "object") return {}
  const out = {}
  for (const k in s) {
    if (typeof k !== "string" || k === "") continue
    const v = String(s[k] ?? "")
    if (v !== "") out[k] = v
  }
  return out
}

// Display name for a printer row: local alias wins over the queue name.
function displayName(row, aliases) {
  const q = String(row ? row["printer-name"] ?? "" : "")
  const a = aliases && typeof aliases === "object" ? aliases[q] : undefined
  return a !== undefined && a !== "" ? a : q
}

// True when at least one job is processing.
function anyPrinting(jobs) {
  for (let i = 0; i < jobs.length; i++)
    if (jobStateNum(jobs[i]["job-state"]) === 5) return true
  return false
}

// True when at least one job failed (state 8 aborted) or sits on a
// stopped printer (7 canceled is the state a job keeps on a stopped
// queue while the reason lives on the printer).
function failedJobs(jobs) {
  for (let i = 0; i < jobs.length; i++) {
    const s = jobStateNum(jobs[i]["job-state"])
    if (s === 7 || s === 8) return true
  }
  return false
}

// Bar-module job icon name for one row: processing -> printer (animated
// page), held -> hourglass, otherwise check (pending/stopped).
// (Kept for API compatibility; the island now leads with jobFileIcon and
// a pending spinner instead.)
// True while the job still occupies the queue (pending/held/processing/
// stopped). Completed/canceled/aborted are history: shown with Delete so
// the user can clear them, but they drive no spinner, no flash, no toast.
function isActiveJobState(state) {
  const s = jobStateNum(state)
  return s >= 3 && s <= 6
}

// The in-flight subset of Get-Jobs rows (order preserved).
function activeJobs(rows) {
  const out = []
  for (let i = 0; i < rows.length; i++)
    if (isActiveJobState(rows[i]["job-state"])) out.push(rows[i])
  return out
}

// True while the job waits in the queue (pending): the "scheduled" rows
// that carry the island's spinner.
function jobIsPending(state) {
  return jobStateNum(state) === 3
}

// True while the job is on the printer (processing): the rows that
// carry the yellow spinning update glyph in the title slot.
function jobIsProcessing(state) {
  return jobStateNum(state) === 5
}

// True once the job left the queue successfully (completed).
function jobIsDone(state) {
  return jobStateNum(state) === 9
}

// True once the job left the queue unsuccessfully (canceled/aborted).
function jobIsFailed(state) {
  const s = jobStateNum(state)
  return s === 7 || s === 8
}

// Basename of a path ("~/docs/a.pdf" -> "a.pdf"); pass-through when
// there is no directory part.
function baseName(p) {
  const s = String(p ?? "")
  const i = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"))
  return i >= 0 ? s.substring(i + 1) : s
}

// Display title for a job row: the file name. CUPS usually carries the
// document name in job-name (sometimes a full path, hence the basename);
// fall back to the document attributes, then to a bare "Job #id" so the
// title never renders blank.
function jobTitle(row) {
  const cands = [row ? row["job-name"] : "",
    row ? row["document-name"] : "",
    row ? row["document-name-supplied"] : ""]
  for (let i = 0; i < cands.length; i++) {
    const t = String(cands[i] ?? "").trim()
    if (t !== "") return baseName(t)
  }
  const id = String(row ? row["job-id"] ?? "" : "").trim()
  return id !== "" ? "Job " + id : "Untitled job"
}

// Generic second line for a job row: printer - time - size (no user
// name - single-user boxes only repeat it). The printer shows its local
// alias when one is set, so renaming a queue renames it in its jobs
// too (the binding re-evaluates on every alias write - instantly).
// Parts with no data are skipped (never a dangling separator); falls
// back to the state label so the line is never blank either.
function jobSub(row, aliases) {
  const parts = []
  const q = String(row ? row.printer ?? "" : "").trim()
  let printer = q
  if (q !== "" && aliases && typeof aliases === "object") {
    const a = aliases[q]
    if (a !== undefined && a !== "") printer = a
  }
  if (printer !== "") parts.push(printer)
  const t = jobTime(row ? row["time-at-creation"] : 0)
  if (t !== "") parts.push(t)
  const kb = Number(row ? row["job-k-octets"] ?? NaN : NaN)
  if (isFinite(kb) && kb > 0) {
    parts.push(kb >= 1024
      ? trim1(kb / 1024) + " MB"
      : String(Math.round(kb)) + " KB")
  }
  if (parts.length > 0) return parts.join(" - ")
  return jobStateLabel(row ? row["job-state"] : 0)
}

// One decimal unless it rounds away ("1024.0" -> "1024").
function trim1(n) {
  return Format.trim1(n)
}
// Extension sets steering the job row's file icon (clipboard tables,
// adapted). Declared above their reader so the QML engine never warns
// about use-before-declaration.
const ARCHIVE_EXTS = {
  zip: true, tar: true, gz: true, tgz: true, bz2: true,
  xz: true, "7z": true, rar: true, zst: true, lz: true, lzma: true
}

const IMAGE_EXTS = {
  png: true, jpg: true, jpeg: true, webp: true, gif: true,
  bmp: true, tiff: true, tif: true, avif: true,
  heic: true, heif: true
}

const SHEET_EXTS = { xls: true, xlsx: true, ods: true, csv: true, tsv: true }
const DB_EXTS = {
  db: true, sqlite: true, sqlite3: true, sql: true, mdb: true, accdb: true
}

const FONT_EXTS = {
  ttf: true, otf: true, woff: true, woff2: true, eot: true, fon: true, pfb: true
}
const MUSIC_EXTS = {
  mp3: true, flac: true, ogg: true, oga: true, opus: true, wav: true,
  m4a: true, aac: true, wma: true, mid: true, midi: true, it: true, xm: true
}
const CODE_EXTS = {
  rs: true, ts: true, tsx: true, js: true, jsx: true, mjs: true, cjs: true,
  py: true, c: true, h: true, cc: true, cpp: true, hh: true, hpp: true,
  go: true, rb: true, java: true, kt: true, kts: true, swift: true,
  lua: true, sh: true, bash: true, zsh: true, fish: true, nu: true,
  vim: true, el: true, nix: true, pl: true, pm: true, php: true, cs: true,
  dart: true, zig: true, hs: true, ml: true,
  clj: true, ex: true, exs: true, erl: true, gleam: true, rkt: true,
  vue: true, svelte: true, astro: true,
  html: true, htm: true, css: true, scss: true, sass: true, less: true,
  styl: true, xml: true, json: true, jsonc: true, json5: true, toml: true,
  yaml: true, yml: true, ini: true, cfg: true, conf: true,
  service: true, timer: true, socket: true, desktop: true,
  properties: true, env: true, gradle: true, cmake: true, mk: true,
  makefile: true, dockerfile: true, justfile: true,
  editorconfig: true, proto: true, graphql: true, gql: true,
  prisma: true, tf: true, tfvars: true, hcl: true, md: true, markdown: true,
  rst: true, adoc: true, org: true, tex: true, bib: true
}

// Leading icon for a job row, picked from the document extension.
// Never "" : unknown/extensionless names fall back to "file".
function jobFileIcon(row) {
  const name = jobTitle(row)
  const dot = name.lastIndexOf(".")
  const e = dot > 0 ? name.substring(dot + 1).toLowerCase() : ""
  if (e === "") return "file"
  if (e === "pdf") return "file-pdf"
  if (e === "svg") return "file-svg"
  if (IMAGE_EXTS[e] === true) return "file-image"
  if (ARCHIVE_EXTS[e] === true) return "file-archive"
  if (SHEET_EXTS[e] === true) return "file-xls"
  if (DB_EXTS[e] === true) return "file-db"
  if (FileIcons.DIFF_EXTS[e]) return "file-diff"
  if (FONT_EXTS[e] === true) return "file-font"
  if (MUSIC_EXTS[e] === true) return "file-music"
  if (CODE_EXTS[e] === true) return "file-code"
  return "file"
}

// Drop locally cleared history entries (service `dismissed` map,
// job-id -> true). Never mutates the input.
function filterDismissed(rows, dismissed) {
  if (!dismissed || typeof dismissed !== "object") return rows
  const out = []
  for (let i = 0; i < rows.length; i++) {
    if (dismissed[String(rows[i]["job-id"] ?? "")] === true) continue
    out.push(rows[i])
  }
  return out
}

// Case-insensitive filter over printer rows: queue name, local alias,
// model, location. Empty q -> all rows. Never mutates the input.
// Case-insensitive filter over job rows (name, user, printer).
function filterRows(rows, q, keys) {
  if (!q || String(q).trim() === "") return rows
  const needle = String(q).toLowerCase()
  const out = []
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    for (let k = 0; k < keys.length; k++) {
      if (String(row[keys[k]] ?? "").toLowerCase().indexOf(needle) !== -1) {
        out.push(row)
        break
      }
    }
  }
  return out
}

// DD.MM HH:MM from a unix time-at-creation integer (seconds). ""
// when absent so generic lines skip it instead of printing an epoch
// artifact.
function jobTime(unix) {
  if (!unix || !isFinite(Number(unix))) return ""
  const d = new Date(Number(unix) * 1000)
  const dd = Format.pad2(d.getDate())
  const mo = Format.pad2(d.getMonth() + 1)
  const hh = Format.pad2(d.getHours())
  const mm = Format.pad2(d.getMinutes())
  return dd + "." + mo + " " + hh + ":" + mm}

// --- what changed, as a diff against the previous read ---------------------
//
// This service polls IPP, so nothing announces that a job was queued or that a
// printer went offline. The previous read is the only record of what it was,
// which makes that snapshot load-bearing rather than a convenience.
//
// The diffs live HERE and not in the service because they are the part that can
// be wrong in a way nobody notices: a transition reported against the wrong
// previous state is a true sentence about a false event. Pure functions over
// two reads can be pinned; the emission cannot.

// printerStates(rows) -> { printer-name: printer-state label }.
//
// The label rather than the raw enum because a state change is reported as a
// transition, and "idle > stopped" is the sentence a reader wants. CUPS's own
// vocabulary, not ours.
function printerStates(rows) {
  const out = {}
  if (!Array.isArray(rows)) return out
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (!row || typeof row !== "object") continue
    const name = String(row["printer-name"] ?? "")
    if (name === "") continue
    out[name] = printerStateLabel(row["printer-state"])
  }
  return out
}

// printerStateTransitions(prev, next) -> [{ printer, from, to }].
//
// `to === null` means the printer left the queue. An EMPTY previous map yields
// nothing at all: the first read is a snapshot of what CUPS already said, not
// a change this shell watched, so a printer that was already stopped when the
// shell started was not stopped by it.
function printerStateTransitions(prev, next) {
  const out = []
  const before = (prev && typeof prev === "object") ? prev : {}
  const after = (next && typeof next === "object") ? next : {}
  const names = Object.keys(after)
  for (let i = 0; i < names.length; i++) {
    // One rule covers both "the first read" and "a queue that just joined":
    // with no previous state there is no transition, and a queue that was
    // already stopped when the shell started was not stopped by it. An earlier
    // version tested emptiness of `before` separately as well; that was
    // redundant, because an absent queue always reads as undefined here.
    const was = before[names[i]]
    if (was === undefined || was === after[names[i]]) continue
    out.push({ printer: names[i], from: was, to: after[names[i]] })
  }
  const gone = Object.keys(before)
  for (let i = 0; i < gone.length; i++) {
    if (after[gone[i]] !== undefined) continue
    out.push({ printer: gone[i], from: before[gone[i]], to: null })
  }
  return out
}

// queuedJobs(prevJobs, jobs) -> [{ id, printer, active }].
//
// A job id absent from the previous read is new work. The active count travels
// with it because "one of four jobs is in flight" is the fact that makes the
// number meaningful, and computing it in the service would mean walking the
// list a second time for no reason.
//
// An empty previous list yields nothing: on the first read every job in
// CUPS's history would otherwise be announced as newly queued.
function queuedJobs(prevJobs, jobs) {
  const out = []
  const prev = Array.isArray(prevJobs) ? prevJobs : []
  const now = Array.isArray(jobs) ? jobs : []
  if (prev.length === 0) return out
  const known = {}
  for (let i = 0; i < prev.length; i++) {
    const row = prev[i]
    if (!row || typeof row !== "object") continue
    known[String(row["job-id"])] = true
  }
  // `activeJobs` reads `job-state` off every row it is handed, so the list is
  // narrowed to real rows HERE rather than passed on as it arrived. Guarding
  // each row in the loop below and then handing the same unfiltered list to
  // another reader would be a claim this function cannot keep.
  const clean = []
  for (let i = 0; i < now.length; i++) {
    const row = now[i]
    if (row && typeof row === "object") clean.push(row)
  }
  const active = activeJobs(clean).length
  for (let i = 0; i < clean.length; i++) {
    const id = String(clean[i]["job-id"] ?? "")
    if (id === "" || known[id] === true) continue
    out.push({ id: id, printer: String(clean[i].printer || ""), active: active })
  }
  return out
}
