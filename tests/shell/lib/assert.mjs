// Assertion kit for the JS library suites.
//
// A suite is a node module that imports `suite` from here, calls its cases,
// and returns. The kit keeps the count, prints one line per case in the same
// shape as the bash harness so a single runner can report both, and exits
// non-zero when anything failed.
//
// The shape mirrors harness.sh on purpose: same section/case vocabulary, same
// TSV result file, so a reader who knows one knows the other.

import fs from 'node:fs'
import path from 'node:path'

const COLOR = process.stdout.isTTY && !process.env.NO_COLOR
const c = (code) => (COLOR ? `\u001b[${code}m` : '')
const GREEN = c('0;32')
const RED = c('0;31')
const CYAN = c('0;36')
const YELLOW = c('0;33')
const DIM = c('0;90')
const BOLD = c('1')
const OFF = c('0')

let pass = 0
let fail = 0
let total = 0
let name = 'unnamed'
let resultsFile = process.env.SHELL_TEST_RESULTS || ''

// The current section, recorded into the results file so a failure is
// attributable to its group. Declared before section() assigns to it.
let section_ = ''

// suite(label, description) starts a suite. Mirrors t_init.
export function suite(label, description = '') {
  name = label
  process.stdout.write(`${BOLD}${label}${OFF}${description ? ` ${DIM}- ${description}${OFF}` : ''}\n`)
}

// section(label) groups the following cases. Mirrors t_section.
export function section(label) {
  section_ = label
  process.stdout.write(`\n${CYAN}--- ${label} ---${OFF}\n`)
}

function record(status, label, detail = '') {
  if (!resultsFile) return
  try {
    // One assertion must be exactly one TSV row. A detail routinely spans two
    // lines ("expect: ...\ngot: ..."), and written raw that second line
    // becomes a second row - which could even forge a status for the runner
    // that classifies on this file.
    const flat = String(detail).replace(/\n/g, '\\n').replace(/\t/g, '\\t')
    fs.appendFileSync(resultsFile, `${status}\t${section_}\t${label}\t${flat}\n`)
  } catch {
    // A results file that cannot be written must not fail the suite; the
    // runner falls back to the exit status.
  }
}

function ok(label, detail = '') {
  pass++
  total++
  record('PASS', label, detail)
  process.stdout.write(`  ${DIM}[${String(total).padStart(2, '0')}]${OFF} ${GREEN}PASS${OFF} ${label}\n`)
}

function no(label, detail = '') {
  fail++
  total++
  record('FAIL', label, detail)
  process.stdout.write(`  ${DIM}[${String(total).padStart(2, '0')}]${OFF} ${RED}FAIL${OFF} ${label}\n`)
  if (detail) {
    for (const line of String(detail).split('\n')) {
      process.stdout.write(`        ${DIM}${line}${OFF}\n`)
    }
  }
}

// show renders a value the way the failure messages should show it:
// strings bare, everything else as stable JSON.
function show(v) {
  if (typeof v === 'string') return v
  if (v === undefined) return 'undefined'
  try {
    return JSON.stringify(v, replacer, 0)
  } catch {
    return String(v)
  }
}

// replacer keeps the key order of the objects the shell passes around stable
// enough to diff, and renders non-JSON values rather than throwing.
function replacer(_k, v) {
  if (typeof v === 'bigint') return `${v}n`
  if (typeof v === 'function') return `[fn ${v.name || 'anon'}]`
  if (typeof v === 'undefined') return '[undefined]'
  if (v instanceof Map) return { __map: [...v.entries()] }
  if (v instanceof Set) return { __set: [...v.values()] }
  return v
}

export { show }

// eq(label, actual, expected) - deep structural equality.
export function eq(label, actual, expected) {
  if (deepEqual(actual, expected)) ok(label)
  else no(label, `expect: ${show(expected)}\ngot:    ${show(actual)}`)
}

// ne(label, actual, unexpected)
export function ne(label, actual, unexpected) {
  if (!deepEqual(actual, unexpected)) ok(label)
  else no(label, `must not be: ${show(unexpected)}`)
}

// is(label, actual, predicate, description) - a named boolean check, for the
// many contracts in this tree that are predicates rather than values.
export function is(label, actual, predicate, description) {
  let r
  try {
    r = predicate(actual)
  } catch (e) {
    no(label, `predicate threw: ${e.message}\nvalue: ${show(actual)}`)
    return
  }
  if (r) ok(label)
  else no(label, `predicate (${description}) rejected: ${show(actual)}`)
}

// match(label, actual, regex) - regex against the string form of the value.
export function match(label, actual, regex) {
  const s = typeof actual === 'string' ? actual : show(actual)
  if (regex.test(s)) ok(label)
  else no(label, `must match ${regex}\ngot: ${s}`)
}

// notMatch(label, actual, regex)
export function notMatch(label, actual, regex) {
  const s = typeof actual === 'string' ? actual : show(actual)
  if (!regex.test(s)) ok(label)
  else no(label, `must not match ${regex}\ngot: ${s}`)
}

// contains(label, haystack, needle)
export function contains(label, haystack, needle) {
  const s = typeof haystack === 'string' ? haystack : show(haystack)
  if (s.includes(needle)) ok(label)
  else no(label, `must contain: ${show(needle)}\ngot:           ${s}`)
}

// notContains(label, haystack, needle)
export function notContains(label, haystack, needle) {
  const s = typeof haystack === 'string' ? haystack : show(haystack)
  if (!s.includes(needle)) ok(label)
  else no(label, `must not contain: ${show(needle)}\ngot:              ${s}`)
}

// throws(label, fn, messagePattern) - the call must throw, and when a
// pattern is given the message must match it. Several of these libraries
// signal failure by throwing rather than by returning a sentinel.
export function throws(label, fn, messagePattern) {
  let err = null
  try {
    fn()
  } catch (e) {
    err = e
  }
  if (!err) {
    no(label, 'expected a throw, call returned normally')
    return
  }
  if (messagePattern && !messagePattern.test(String(err.message))) {
    no(label, `message must match ${messagePattern}\ngot: ${err.message}`)
    return
  }
  ok(label)
}

// noThrow(label, fn) - for the purity contracts: these libraries are on the
// per-keystroke path, so a throw is a real defect.
export function noThrow(label, fn) {
  try {
    const v = fn()
    ok(label, typeof v === 'string' ? v : '')
  } catch (e) {
    no(label, `threw: ${e.message}`)
  }
}

// approx(label, actual, expected, epsilon) - the numeric comparisons in this
// tree are geometric and colour conversions, where exact equality is the
// wrong assertion.
export function approx(label, actual, expected, epsilon = 1e-9) {
  if (typeof actual === 'number' && Number.isFinite(actual) && Math.abs(actual - expected) <= epsilon) {
    ok(label)
  } else {
    no(label, `expect ~${expected} (+-${epsilon}), got ${show(actual)}`)
  }
}

// skip(label, reason) - an explicitly unverified behaviour. Counted, never a
// pass, so the coverage gap is visible in the total.
export function skip(label, reason = 'no reason given') {
  total++
  record('SKIP', label, reason)
  process.stdout.write(
    `  ${DIM}[${String(total).padStart(2, '0')}]${OFF} ${YELLOW}SKIP${OFF} ${label} ${DIM}(${reason})${OFF}\n`,
  )
}

// deepEqual is structural equality that treats an object and a matching
// Map/Set/array as unequal, and is not fooled by key order. Node's
// util.isDeepStrictEqual does all of that already; it is wrapped so the
// failure message stays in the kit's format.
export function deepEqual(a, b) {
  if (a === b) return true
  if (typeof a === 'number' && typeof b === 'number') {
    return Number.isNaN(a) && Number.isNaN(b)
  }
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  if (a instanceof Map || b instanceof Map) {
    if (!(a instanceof Map) || !(b instanceof Map) || a.size !== b.size) return false
    for (const [k, v] of a) {
      if (!b.has(k) || !deepEqual(v, b.get(k))) return false
    }
    return true
  }
  if (a instanceof Set || b instanceof Set) {
    if (!(a instanceof Set) || !(b instanceof Set) || a.size !== b.size) return false
    for (const v of a) if (!b.has(v)) return false
    return true
  }
  const ka = Object.keys(a)
  const kb = Object.keys(b)
  if (ka.length !== kb.length) return false
  for (const k of ka) {
    if (!Object.prototype.hasOwnProperty.call(b, k)) return false
    if (!deepEqual(a[k], b[k])) return false
  }
  return true
}

// case registers a labelled group of assertions, so a failing assertion
// inside it is attributable to the case and not just to a line number.
//
// The group's label is prefixed onto the *current* section and restored
// afterwards, so nesting a case inside a case does not concatenate labels
// into one unreadable run of text.
export function case_(label, fn) {
  const outer = section_
  const nested = outer ? `${outer} / ${label}` : label
  section_ = nested
  process.stdout.write(`\n${DIM}  . ${label}${OFF}\n`)
  try {
    fn()
  } catch (e) {
    no(`${label} (threw)`, `${e.stack || e.message}`)
  }
  section_ = outer
}

// group is the friendlier name for case_.
export const group = case_

// finish prints the summary and exits with the harness's contract:
// 0 all passed, 1 at least one failed. Suites that cannot run here should
// call blocked() instead, which exits 77.
export function finish() {
  const width = 62
  const bar = '='.repeat(width)
  process.stdout.write(`\n${bar}\n`)
  if (fail === 0) {
    process.stdout.write(`  ${GREEN}${pass} passed${OFF}`)
  } else {
    process.stdout.write(
      `  ${GREEN}${pass} passed${OFF}  ${RED}${fail} failed${OFF}  ${total} total`,
    )
  }
  process.stdout.write(`  ${DIM}(${name})${OFF}\n${bar}\n\n`)
  process.exit(fail === 0 ? 0 : 1)
}

// blocked(reason) - the suite cannot run on this host. Exit 77, which the
// runner classifies as BLOCKED rather than as a pass or a failure.
export function blocked(reason) {
  process.stdout.write(`\n${YELLOW}BLOCKED${OFF} ${reason}\n`)
  if (resultsFile) {
    try {
      fs.appendFileSync(resultsFile, `BLOCKED\t\t${name}\t${reason}\n`)
    } catch {
      /* runner falls back to the exit status */
    }
  }
  process.exit(77)
}

// SHELL_DIR is the shell tree, resolved from this file's location so a suite
// can be run from any working directory. lib/ sits at tests/shell/lib, so
// three levels up is the checkout root and `shell` is the tree inside it.
export const SHELL_DIR = path.resolve(path.dirname(import.meta.dirname), '..', '..', 'shell')
