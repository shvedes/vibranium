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
// deepEqual treats the two `Array` types as different objects.

import { readFileSync } from 'node:fs'
import { createContext, runInContext } from 'node:vm'
import { suite, group, eq, match, finish } from '../../lib/assert.mjs'

const SOURCE_URL = new URL('../../../../shell/common/ui/LayerSpec.js', import.meta.url)
const source = readFileSync(SOURCE_URL, 'utf8')
const code = source.replace(/^\s*\.pragma library\s*$/m, '')

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

// A table with fresh row and client objects, so a case can break one row
// without touching the shipped table or another case.
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

suite('layerspec', 'the layer-shell table against its own schema and validator')

group('the shipped table conforms to its own schema', () => {
  eq('the shipped table validates', validate(), [])
})

group('the table is fourteen classes over twenty-four windows', () => {
  eq('fourteen classes', names().length, 14)
  eq('twenty-four windows', allClients().length, 24)
  eq('a client maps exactly one class', new Set(allClients()).size, 24)
})

group('every row carries the declared fields, in the declared order', () => {
  for (const [name, row] of Object.entries(L.SPECS)) {
    eq(name + ' field order', Object.keys(row), host(L.FIELDS))
  }
})

group('the domains are the closed sets the spec names', () => {
  eq('the layer domain', allowed('layer'), [L.BACKGROUND, L.BOTTOM, L.TOP, L.OVERLAY])
  eq('the focus domain', allowed('focus'), ['none', 'ondemand', 'exclusive'])
  eq('the mask domain', allowed('mask'), ['none', 'empty', 'content'])
  eq('the mapped domain', allowed('mapped'), ['always', 'open'])
  eq('the exclusion domain', allowed('exclusion'), ['normal', 'ignore'])
})

group('orderedNames is exactly the rows with an order to carry', () => {
  const expected = Object.entries(L.SPECS)
    .filter(([, row]) => row.order !== 0)
    .map(([name]) => name)
    .sort()
  eq('orderedNames', orderedNames().sort(), expected)
  eq('five classes are ordered by a rule', expected.length, 5)
})

group('needsRule follows the rule flag, not the order', () => {
  eq('seven classes need a rule', names().filter(name => L.needsRule(name)).length, 7)
  eq('an unknown class needs no rule', L.needsRule('vibranium:nope'), false)
})

group('an unknown namespace degrades to the safe defaults', () => {
  eq('spec is null', L.spec('vibranium:nope'), null)
  eq('has is false', L.has('vibranium:nope'), false)
  eq('clientsOf is empty', clientsOf('vibranium:nope'), [])
  eq('the layer is OVERLAY', L.layerFor('vibranium:nope'), L.OVERLAY)
  eq('the focus is none', L.focusFor('vibranium:nope'), 'none')
  eq('the exclusion is ignore', L.exclusionFor('vibranium:nope'), 'ignore')
})

group('no namespace is declared twice', () => {
  eq('no duplicates', duplicates(), [])
})

group('validate rejects an unknown field', () => {
  const table = cloneTable()
  table['vibranium:bar'].shadow = true
  match('an unknown field is rejected', validate(table).join('\n'), /unknown field shadow/)
})

group('validate rejects a missing field', () => {
  const table = cloneTable()
  delete table['vibranium:bar'].mask
  match('a missing field is rejected', validate(table).join('\n'), /missing field mask/)
})

group('validate rejects a value outside its domain', () => {
  const table = cloneTable()
  table['vibranium:hud'].focus = 'sometimes'
  table['vibranium:hud'].layer = 9
  const problems = validate(table).join('\n')
  match('focus is checked', problems, /focus is outside its domain/)
  match('layer is checked', problems, /layer is outside its domain/)
})

group('validate rejects an order with no rule to carry it', () => {
  const table = cloneTable()
  table['vibranium:island'].rule = false
  match('an order without a rule is rejected', validate(table).join('\n'), /order 1 without a rule/)
})

group('validate rejects a client claimed by two classes', () => {
  const table = cloneTable()
  table['vibranium:popup'].clients.push('osd')
  match('a shared client is rejected', validate(table).join('\n'), /osd: mapped by both/)
})

group('validate rejects a class with no clients and a bad name', () => {
  const table = cloneTable()
  table['vibranium:hud'].clients = []
  table['vibranium:HUD'] = cloneTable()['vibranium:hud']
  const problems = validate(table).join('\n')
  match('empty clients are rejected', problems, /clients is not a non-empty list/)
  match('a bad name is rejected', problems, /vibranium:HUD: name is not/)
})

group('validate reports the shipped count of problems, which is none', () => {
  eq('the shipped table has no problems', validate().length, 0)
})

finish()
