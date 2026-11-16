#!/usr/bin/env node
// Suite: shell/common/ui/LayerSpec.js - the layer-shell specification.
//
// The table is normative, so this suite is a conformance check rather than a
// feature test: the shipped table MUST validate, the counts MUST match the
// windows the shell maps, and the validator MUST reject each fault it claims to
// catch. That last half is the part that keeps `validate` honest - a validator
// that returned [] for everything would pass the first half.
//
// The library is loaded through `node:vm` rather than `import`: it carries a
// `.pragma library` line, which is a QML directive and not valid JavaScript.
// Stripping it is cheaper, and truer to the shipped text, than keeping a third
// file in sync. Everything that crosses back out of the context goes through
// `host()`: an array made in the vm realm has that realm's prototype, and
// `deepEqual` treats the two `Array` types as different objects.

import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { createContext, runInContext } from "node:vm"

const SOURCE_URL = new URL("../../../../shell/common/ui/LayerSpec.js", import.meta.url)
const source = readFileSync(SOURCE_URL, "utf8")
const code = source.replace(/^\s*\.pragma library\s*$/m, "")

const L = runInContext(
  `${code}\n;({ SPECS, FIELDS, DOMAINS, validate, names, clientsOf, spec, has,
        needsRule, orderedNames, duplicates, layerFor, focusFor, exclusionFor,
        BACKGROUND, BOTTOM, TOP, OVERLAY })`,
  createContext({})
)

const host = value => Array.from(value)
const validate = table => host(L.validate(table))
const names = () => host(L.names())
const orderedNames = () => host(L.orderedNames())
const duplicates = () => host(L.duplicates())
const clientsOf = name => host(L.clientsOf(name))
const allowed = field => host(L.DOMAINS[field])

// A table with fresh row and client objects, so a test can break one row
// without touching the shipped table or another test.
function cloneTable() {
  const table = {}
  for (const [name, row] of Object.entries(L.SPECS)) {
    table[name] = { ...row, clients: [...row.clients] }
  }
  return table
}

function allClients() {
  return Object.values(L.SPECS).flatMap(row => [...row.clients])
}

test("the shipped table conforms to its own schema", () => {
  assert.deepEqual(validate(), [])
})

test("the table is fourteen classes over twenty-four windows", () => {
  assert.equal(names().length, 14)
  assert.equal(allClients().length, 24)
  assert.equal(new Set(allClients()).size, 24, "a client maps exactly one class")
})

test("every row carries the declared fields, in the declared order", () => {
  for (const [name, row] of Object.entries(L.SPECS)) {
    assert.deepEqual(Object.keys(row), host(L.FIELDS), `${name} field order`)
  }
})

test("the domains are the closed sets the spec names", () => {
  assert.deepEqual(allowed("layer"), [L.BACKGROUND, L.BOTTOM, L.TOP, L.OVERLAY])
  assert.deepEqual(allowed("focus"), ["none", "ondemand", "exclusive"])
  assert.deepEqual(allowed("mask"), ["none", "empty", "content"])
  assert.deepEqual(allowed("mapped"), ["always", "open"])
  assert.deepEqual(allowed("exclusion"), ["normal", "ignore"])
})

test("orderedNames is exactly the rows with an order to carry", () => {
  const expected = Object.entries(L.SPECS)
    .filter(([, row]) => row.order !== 0)
    .map(([name]) => name)
    .sort()
  assert.deepEqual(orderedNames().sort(), expected)
  assert.equal(expected.length, 5, "five classes are ordered by a rule")
})

test("needsRule follows the rule flag, not the order", () => {
  assert.equal(names().filter(name => L.needsRule(name)).length, 7)
  assert.equal(L.needsRule("vibranium:nope"), false)
})

test("an unknown namespace degrades to the safe defaults", () => {
  assert.equal(L.spec("vibranium:nope"), null)
  assert.equal(L.has("vibranium:nope"), false)
  assert.deepEqual(clientsOf("vibranium:nope"), [])
  assert.equal(L.layerFor("vibranium:nope"), L.OVERLAY)
  assert.equal(L.focusFor("vibranium:nope"), "none")
  assert.equal(L.exclusionFor("vibranium:nope"), "ignore")
})

test("no namespace is declared twice", () => {
  assert.deepEqual(duplicates(), [])
})

test("validate rejects an unknown field", () => {
  const table = cloneTable()
  table["vibranium:bar"].shadow = true
  assert.match(validate(table).join("\n"), /unknown field shadow/)
})

test("validate rejects a missing field", () => {
  const table = cloneTable()
  delete table["vibranium:bar"].mask
  assert.match(validate(table).join("\n"), /missing field mask/)
})

test("validate rejects a value outside its domain", () => {
  const table = cloneTable()
  table["vibranium:hud"].focus = "sometimes"
  table["vibranium:hud"].layer = 9
  const problems = validate(table).join("\n")
  assert.match(problems, /focus is outside its domain/)
  assert.match(problems, /layer is outside its domain/)
})

test("validate rejects an order with no rule to carry it", () => {
  const table = cloneTable()
  table["vibranium:island"].rule = false
  assert.match(validate(table).join("\n"), /order 1 without a rule/)
})

test("validate rejects a client claimed by two classes", () => {
  const table = cloneTable()
  table["vibranium:popup"].clients.push("osd")
  assert.match(validate(table).join("\n"), /osd: mapped by both/)
})

test("validate rejects a class with no clients and a bad name", () => {
  const table = cloneTable()
  table["vibranium:hud"].clients = []
  table["vibranium:HUD"] = cloneTable()["vibranium:hud"]
  const problems = validate(table).join("\n")
  assert.match(problems, /clients is not a non-empty list/)
  assert.match(problems, /vibranium:HUD: name is not/)
})

test("validate reports the shipped count of problems, which is none", () => {
  assert.equal(validate().length, 0)
})
