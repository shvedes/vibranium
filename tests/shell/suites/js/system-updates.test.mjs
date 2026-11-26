#!/usr/bin/env node
// Suite: the systemUpdates target - rename, read-only dumps, and the real
// owner's update call with a JSON-array token. The owner functions are
// evaluated out of SystemUpdates.qml against stubbed triggerUpdate; no fetch,
// process or package update is started.
import fs from 'node:fs'
import path from 'node:path'
import vm from 'node:vm'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, notContains, finish, SHELL_DIR } from '../../lib/assert.mjs'

const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))
const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const SRC = fs.readFileSync(path.join(SHELL_DIR, 'services/system/SystemUpdates.qml'), 'utf8')

suite('system-updates', 'renamed target, typed dumps, and the owner update call')

function body(signature) {
  const start = SRC.indexOf(signature)
  if (start < 0) throw new Error(`missing ${signature}`)
  const open = SRC.indexOf('{', start)
  let depth = 0
  for (let i = open; i < SRC.length; i++) {
    if (SRC[i] === '{') depth++
    else if (SRC[i] === '}') {
      depth--
      if (depth === 0) return SRC.slice(open + 1, i)
    }
  }
  throw new Error(`unbalanced ${signature}`)
}

section('rename')

group('the public target uses only the new spelling', () => {
  eq('the target exists', C.findTarget('systemUpdates') !== null, true)
  eq('the retired target is gone', C.findTarget('arch-updates'), null)
  notContains('no retired id in the catalog', 'arch-updates',
    C.Manifest.targets.map((t) => t.id).join(','))
  notContains('no retired id in the owner source', 'arch-updates', SRC)
  eq('title and summary', [C.findTarget('systemUpdates').title, C.findTarget('systemUpdates').summary],
    ['System updates', 'Check for and apply system updates'])
  eq('the owner registers the new target', SRC.includes('IpcRouter.register("systemUpdates", root'), true)
  eq('the owner unregisters the new target', SRC.includes('IpcRouter.unregister("systemUpdates", root)'), true)
  eq('the native handler uses the new target', /target:\s*"systemUpdates"/.test(SRC), true)
  eq('the native help uses the new target', SRC.includes('UnitIpc.help("systemUpdates", "System updates"'), true)
  eq('the offer keeps the boot unit id', SRC.includes('Registry.offer("systemUpdates"'), true)
})

section('read-only dumps')

group('three forms with one ordered typed shape', () => {
  const columns = [
    ['name', 'Name'], ['current', 'Current'], ['candidate', 'Candidate'],
    ['repository', 'Repository'], ['size', 'Size'], ['source', 'Source']
  ]
  for (const [id, words] of [
    ['systemUpdates.dump', ['dump']],
    ['systemUpdates.dump.all', ['dump', 'all']],
    ['systemUpdates.dump.aur', ['dump', 'aur']]
  ]) {
    const r = C.findRow(id)
    eq(`${id}: row`, r !== null, true)
    eq(`${id}: words`, r.words, words)
    eq(`${id}: grammar`, P.compile(r.words).ok, true)
    eq(`${id}: grammar matches`, P.match(r.words, words).ok, true)
    eq(`${id}: route`, r.route, 'gateway')
    eq(`${id}: result adapter`, r.reply.kind, 'json')
    eq(`${id}: typed table columns`,
      r.output.columns.map((c) => [c.key, c.heading]), columns)
    eq(`${id}: an example`, r.examples.length > 0, true)
    eq(`${id}: registered`, SRC.includes(`"${id}": function`), true)
  }
  eq('no refresh or demand in the dump closures',
    ['systemUpdates.dump', 'systemUpdates.dump.all', 'systemUpdates.dump.aur']
      .every((id) => !SRC.includes(`"${id}": function () { return root._demandTransient()`)), true)
  const dump = body('function dump(source: string): string')
  eq('dump defaults to the merged rows', dump.includes('source === "aur" ? root._aurPkgs : root.packages'), true)
  eq('dump projects only the existing row fields',
    ['name', 'current', 'candidate', 'repository', 'size', 'source']
      .every((key) => dump.includes(`${key}: String(r.${key} ?? "")`)), true)
  eq('dump does not fetch or update', /refresh|triggerUpdate|demand/.test(dump), false)
})

section('argument classification and the real owner call')

group('a bad JSON token keeps its row', () => {
  const row = C.findRow('systemUpdates.update')
  eq('the row matches the JSON-array form',
    P.match(row.words, ['update', 'aur', '["artcraft-launcher-bin"]']).ok, true)
  const bad = P.match(row.words, ['update', 'aur', 'artcraft-launcher-bin'])
  eq('the bad token is an argument failure', bad.ok, false)
  eq('the failure retains its typed step', bad.error, 'invalid-argument')
  eq('the failing step is the JSON argument', bad.badType, 'json')
  eq('a wrong verb is a shape miss', P.match(row.words, ['apply', 'aur', '[]']).ok, false)
  const empty = P.match(row.words, ['update', 'repo', ''])
  eq('the legacy empty package list matches', empty.ok, true)
  eq('the empty token stays a string', empty.args.packages, '')
  eq('the help shows the quoted array form',
    row.examples.includes('vb-shell systemUpdates update aur \'["artcraft-launcher-bin"]\''), true)
})

group('the owner calls triggerUpdate with the parsed array', () => {
  const calls = []
  const asNames = body('function _asNames(pkgNames)')
  const update = body('function update(aur: string, json: string): string')
  const code = `function _asNames(pkgNames) {${asNames}}\n`
    + `function update(aur, json) {${update}}\n;({ update: update, _asNames: _asNames })`
  const ctx = { root: { triggerUpdate: (aur, names) => { calls.push([aur, names]) } } }
  const fns = vm.runInNewContext(code, ctx)
  ctx.root._asNames = fns._asNames
  const reply = fns.update('aur', '["artcraft-launcher-bin"]')
  eq('the native reply stays "ok"', reply, 'ok')
  eq('the owner started exactly one update', calls.length, 1)
  eq('the update is AUR with the one parsed name', calls[0],
    [true, ['artcraft-launcher-bin']])
})

finish()
