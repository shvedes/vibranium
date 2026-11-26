#!/usr/bin/env node
// Suite: IpcProtocol - framing, validation, grammar and result adapters.
// Loaded through the real `.pragma library` harness, with no Qt present.
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, match, notMatch, throws, finish, SHELL_DIR } from '../../lib/assert.mjs'

const P = loadLib(path.join(SHELL_DIR, 'common/text/IpcProtocol.js'))
const C = loadLib(path.join(SHELL_DIR, 'common/text/IpcCatalog.js'))

suite('ipc-protocol', 'v1 framing, strict requests, complete grammar, typed results')

// ---------------------------------------------------------------------------
section('framing')

group('prefix and deterministic compact ASCII', () => {
  match('starts with v1:', P.encode({ v: 1, kind: 'index' }), /^v1:\{/)
  eq('keys stay in insertion order', P.encode({ b: 1, a: 2 }), 'v1:{"b":1,"a":2}')
  eq('no spaces', P.encode({ a: [1, 2] }), 'v1:{"a":[1,2]}')
  eq('non-ASCII becomes one escape per UTF-16 unit',
    P.encode({ a: 'é😀' }), 'v1:{"a":"\\u00e9\\ud83d\\ude00"}')
  eq('an empty string survives', P.encode({ a: '' }), 'v1:{"a":""}')
})

group('decode accepts exactly one frame', () => {
  eq('a v1 object decodes', P.decode('v1:{"v":1,"ok":true}').ok, true)
  eq('a trailing LF is transport framing', P.decode('v1:{"v":1}\n').v, 1)
  eq('a missing prefix is rejected', P.decode('{"v":1}'), null)
  eq('trailing bytes are rejected', P.decode('v1:{"v":1}x'), null)
  eq('an array is not an envelope', P.decode('v1:[1,2]'), null)
  eq('a scalar is not an envelope', P.decode('v1:1'), null)
  eq('malformed JSON is rejected', P.decode('v1:{oops'), null)
})

// ---------------------------------------------------------------------------
section('request validation')

group('describe shapes', () => {
  eq('index', P.validateRequest('describe', { v: 1, kind: 'index' }).kind, 'index')
  eq('help path is copied', P.validateRequest('describe', { v: 1, kind: 'help', path: ['settings', 'fonts'] }).path,
    ['settings', 'fonts'])
  eq('next', P.validateRequest('describe', { v: 1, kind: 'next', cursor: 'inc.1' }).kind, 'next')
  eq('a wrong version fails', P.validateRequest('describe', { v: 2, kind: 'index' }).error, 'invalid-argument')
  eq('an unknown field fails', P.validateRequest('describe', { v: 1, kind: 'index', argv: [] }).error, 'invalid-argument')
  eq('a non-string path member fails', P.validateRequest('describe', { v: 1, kind: 'help', path: [1] }).error, 'invalid-argument')
  eq('a NUL in a path fails', P.validateRequest('describe', { v: 1, kind: 'help', path: ['a\u0000b'] }).error, 'invalid-argument')
  eq('a missing cursor fails', P.validateRequest('describe', { v: 1, kind: 'next' }).error, 'invalid-argument')
  eq('invoke cannot use describe help', P.validateRequest('invoke', { v: 1, kind: 'help', path: [] }).error, 'invalid-argument')
})

group('invoke shapes and literalFrom', () => {
  const ok = P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['state', 'get', 'slot'], literalFrom: null })
  eq('argv survives', ok.argv, ['state', 'get', 'slot'])
  eq('null literalFrom is kept', ok.literalFrom, null)
  eq('an omitted literalFrom is normalized to null',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['a'] }).literalFrom, null)
  eq('a literalFrom at the end is legal',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['a'], literalFrom: 1 }).literalFrom, 1)
  eq('a literalFrom past the end fails',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['a'], literalFrom: 2 }).error, 'invalid-argument')
  eq('a fractional literalFrom fails',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['a'], literalFrom: 0.5 }).error, 'invalid-argument')
  eq('a non-string argv member fails',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: ['a', 2] }).error, 'invalid-argument')
  eq('more than 128 words is oversize',
    P.validateRequest('invoke', { v: 1, kind: 'call', argv: Array(129).fill('x') }).error, 'oversize')
})

// ---------------------------------------------------------------------------
section('grammar')

group('fixed keywords before placeholders, complete matches', () => {
  const words = ['call', { name: 'id', type: 'string' }]
  eq('a fixed keyword matches', P.match(words, ['call', 'x']).ok, true)
  eq('a prefix is not a match', P.match(words, ['call']).ok, false)
  eq('an abbreviation is not a match', P.match(['call'], ['cal']).ok, false)
  eq('extra words are not a match', P.match(['call'], ['call', 'x']).ok, false)
  eq('a literal after a placeholder compiles',
    P.compile([{ name: 'a', type: 'string' }, 'call']).ok, true)
  eq('a literal after a placeholder matches exactly',
    P.match([{ name: 'a', type: 'string' }, 'call'], ['x', 'call']).args.a, 'x')
  eq('the literal after a placeholder must still match',
    P.match([{ name: 'a', type: 'string' }, 'call'], ['x', 'other']).ok, false)
})

group('fixed keywords after placeholders', () => {
  const fixed = ['list', { name: 'id', type: 'string' }]
  const placeholder = [{ name: 'cmd', type: 'string' }, 'list']
  const argv = ['list', 'list']

  function lead(words) {
    let n = 0
    for (const w of words) {
      if (typeof w !== 'string') break
      n++
    }
    return n
  }

  // The same first-match-by-leading-literals rule the router uses.
  const ordered = [placeholder, fixed].sort((a, b) => lead(b) - lead(a))
  const picked = ordered.map(words => [words, P.match(words, argv)]).find(([, m]) => m.ok)
  eq('both grammars accept the ambiguous argv', P.match(placeholder, argv).ok, true)
  eq('the fixed keyword alternative is chosen first', picked[0], fixed)
  eq('the chosen row binds the literal position',
    picked[1].args.id, 'list')

  eq('usage renders the literal token, not a placeholder',
    P.usage([{ name: 'id', type: 'string' }, 'tail']), '<id> tail')
  eq('usage keeps a trailing literal with no angle brackets',
    P.usage(['set', { name: 'key', type: 'string' }, 'value']), 'set <key> value')

  eq('an invalid int after a literal fails',
    P.match(['tail', { name: 'n', type: 'int' }], ['tail', '-1']).ok, false)
  eq('an invalid literal after a valid arg fails',
    P.match([{ name: 'a', type: 'string' }, 'tail'], ['x', 'tal']).ok, false)
  eq('a missing literal after a placeholder fails',
    P.match([{ name: 'a', type: 'string' }, 'tail'], ['x']).ok, false)

  // Every other compile-time rejection is still in force.
  eq('an empty name is rejected',
    P.compile([{ name: '', type: 'string' }]).ok, false)
  eq('a repeat that is not last is rejected',
    P.compile([{ name: 'x', type: 'string', repeat: true }, 'tail']).ok, false)
  eq('an unknown type is rejected',
    P.compile([{ name: 'x', type: 'nope' }]).ok, false)
  eq('an enum without values is rejected',
    P.compile([{ name: 'x', type: 'enum' }]).ok, false)
  eq('a malformed record is rejected',
    P.compile([{ name: 7, type: 'string' }]).ok, false)
})

group('optional groups and repeats', () => {
  const dnd = ['dnd', { optional: [{ name: 'value', type: 'string' }] }]
  eq('omitted optional matches', P.match(dnd, ['dnd']).ok, true)
  eq('explicit empty string is a value', P.match(dnd, ['dnd', '']).args.value, '')
  eq('two optionals are rejected', P.match(dnd, ['dnd', 'on', 'off']).ok, false)
  const path = ['help', { optional: [{ name: 'path', type: 'ref', repeat: true }] }]
  eq('a repeat consumes every remaining word', P.match(path, ['help', 'settings', 'fonts']).args.path,
    ['settings', 'fonts'])
  eq('a repeat cannot be followed by a literal',
    P.compile([{ name: 'x', type: 'string', repeat: true }, 'tail']).ok, false)
})

group('unordered flags', () => {
  const words = ['capture', { flags: ['plain', 'copy', 'save'] },
    { name: 'target', type: 'enum', values: ['screen', 'region'] }]
  eq('no flags match', P.match(words, ['capture', 'screen']).args.flags, [])
  eq('one flag matches', P.match(words, ['capture', 'copy', 'region']).args.flags, ['copy'])
  eq('flags may arrive in any order',
    P.match(words, ['capture', 'save', 'plain', 'screen']).args.flags, ['save', 'plain'])
  eq('all flags match',
    P.match(words, ['capture', 'plain', 'save', 'copy', 'screen']).args.flags,
    ['plain', 'save', 'copy'])
  eq('an unknown flag fails', P.match(words, ['capture', 'bogus', 'screen']).ok, false)
  eq('a flag after the target fails', P.match(words, ['capture', 'screen', 'plain']).ok, false)
  eq('usage names the flag set', P.usage(words), 'capture [plain|copy|save] <target>')
  eq('an empty flag name is rejected', P.compile([{ flags: [''] }]).ok, false)
})

group('typed argument rules', () => {
  const arg = (type, extra) => [{ name: 'x', type: type, ...(extra || {}) }]
  eq('decimal int', P.match(arg('int'), ['7']).args.x, 7)
  eq('a signed int is not decimal', P.match(arg('int'), ['-7']).ok, false)
  eq('a hex-looking int is not decimal', P.match(arg('int'), ['0x10']).ok, false)
  eq('JS-safe bound', P.match(arg('int'), ['9007199254740992']).ok, false)
  eq('leaf min', P.match(arg('int', { min: 1 }), ['0']).ok, false)
  eq('leaf max', P.match(arg('int', { max: 200 }), ['201']).ok, false)
  eq('bool true', P.match(arg('bool'), ['true']).args.x, true)
  eq('bool false', P.match(arg('bool'), ['false']).args.x, false)
  eq('bool is exact', P.match(arg('bool'), ['TRUE']).ok, false)
  eq('number accepts a decimal', P.match(arg('number'), ['0.5']).args.x, 0.5)
  eq('number accepts exponent notation', P.match(arg('number'), ['1e3']).args.x, 1000)
  eq('number rejects NaN', P.match(arg('number'), ['NaN']).ok, false)
  eq('enum is exact', P.match(arg('enum', { values: ['on', 'off'] }), ['On']).ok, false)
  eq('ref cannot be blank', P.match(arg('ref'), ['']).ok, false)
  eq('string keeps a leading hyphen', P.match(arg('string'), ['--x']).args.x, '--x')
  eq('string is not trimmed', P.match(arg('string'), ['  x  ']).args.x, '  x  ')
  eq('json parses one token', P.match(arg('json'), ['{"a":1}']).args.x, { a: 1 })
  eq('raw token is kept for compat', P.match(arg('json'), ['{"a":1}']).tokens.x, '{"a":1}')
  eq('json rejects bad input', P.match(arg('json'), ['{oops']).ok, false)
  eq('json empty string is opt-in', P.match(arg('json'), ['']).ok, false)
  eq('json empty string when allowed', P.match(arg('json', { allowEmptyString: true }), ['']).args.x, '')
  eq('an unknown type is a compile error', P.compile(arg('nope')).ok, false)
})

group('usage is built from words', () => {
  eq('required, optional, repeat',
    P.usage(['set', { name: 'key', type: 'string' }, { optional: [{ name: 'step', type: 'int' }] },
      { name: 'more', type: 'string', repeat: true }]),
    'set <key> [<step>] [<more>...]')
})

// ---------------------------------------------------------------------------
section('limits, cursors and adapters')

group('recorded limits', () => {
  eq('request cap', P.MAX_REQUEST_BYTES, 48 * 1024)
  eq('word cap', P.MAX_WORDS, 128)
  eq('reply cap', P.MAX_REPLY_BYTES, 24 * 1024)
  eq('snapshot cap', P.MAX_SNAPSHOT_BYTES, 4 * 1024 * 1024)
  eq('snapshot count', P.MAX_SNAPSHOTS, 8)
  eq('snapshot TTL', P.SNAPSHOT_TTL_MS, 10000)
})

group('opaque cursors', () => {
  eq('cursor shape', P.cursor('123-1-abc', 4), '123-1-abc.4')
  eq('same instance parses', P.parseCursor('123-1-abc.4', '123-1-abc'), 4)
  eq('wrong instance is refused', P.parseCursor('999-1-abc.4', '123-1-abc'), null)
  eq('no sequence is refused', P.parseCursor('123-1-abc', '123-1-abc'), null)
  eq('a non-decimal sequence is refused', P.parseCursor('123-1-abc.x', '123-1-abc'), null)
})

group('failed argument names travel with the verdict', () => {
  const row = C.findRow('app.call.audioMixer.openTab')
  const bad = P.match(row.words, ['call', 'audioMixer', 'openTab', 'bogus'])
  eq('an enum miss is invalid-argument', bad.error, 'invalid-argument')
  eq('the failed label is TAB', bad.badName, 'TAB')
  eq('the failed type is enum', bad.badType, 'enum')
  const json = P.match(C.findRow('settings.set').words, ['set', 'key', 'not-json'])
  eq('a JSON miss keeps its own type', json.badType, 'json')
  eq('a JSON miss carries its label too', json.badName, 'json')
})

group('help is a declared output kind', () => {
  eq('help is in the renderer vocabulary', P.OUTPUT_KINDS.includes('help'), true)
  const descriptor = { usage: 'vb-shell app call audioMixer', commands: [] }
  eq('formatOf keeps the help kind', P.formatOf({ output: { kind: 'help' } }, descriptor).kind, 'help')
  eq('an unknown kind falls back to value', P.formatOf({ output: { kind: 'bogus' } }, []).kind, 'value')
  eq('an alternate help kind is accepted',
    P.formatOf({ output: { kind: 'value' }, formats: [{ when: 'object', kind: 'help' }] }, descriptor).kind,
    'help')
})

group('result type adapters', () => {
  eq('json', P.adapt({ kind: 'json' }, '{"a":1}').data, { a: 1 })
  eq('settings get rejects an error field', P.adapt({ kind: 'json', rejectErrorField: true }, '{"error":"x"}').error,
    'not-found')
  eq('other json leaves keep an error field', P.adapt({ kind: 'json' }, '{"error":"x"}').data, { error: 'x' })
  eq('text preserves exact bytes', P.adapt({ kind: 'text' }, '  ok  ').data, '  ok  ')
  eq('bool true', P.adapt({ kind: 'bool' }, 'true').data, true)
  eq('bool false is not truthiness', P.adapt({ kind: 'bool' }, 'false').data, false)
  eq('count', P.adapt({ kind: 'count' }, 'ok: 12').data, 12)
  eq('lines splits an empty list', P.adapt({ kind: 'lines' }, '').data, [])
  eq('lines splits LF', P.adapt({ kind: 'lines' }, 'a\nb').data, ['a', 'b'])
  eq('none is silence', 'data' in P.adapt({ kind: 'none' }, 'ok'), false)
  eq('action ok is silence', 'data' in P.adapt({ kind: 'action' }, 'ok'), false)
  eq('action text is never a result', 'data' in P.adapt({ kind: 'action' }, 'queued'), false)
  eq('action error token maps', P.adapt({ kind: 'action' }, 'error:copy').error, 'invalid-argument')
  eq('action error reason survives', P.adapt({ kind: 'action' }, 'error:copy').message, 'copy')
  eq('action refused maps', P.adapt({ kind: 'action' }, 'refused:busy').error, 'refused')
  eq('action refusal reason survives', P.adapt({ kind: 'action' }, 'refused:busy').message, 'busy')
  eq('action unavailable maps', P.adapt({ kind: 'action' }, 'unavailable').error, 'unavailable')
  eq('action bare error gets a fixed reason', P.adapt({ kind: 'action' }, 'error').message, 'action failed')
  eq('confirmation_required maps to refused', P.adapt({ kind: 'action' }, 'confirmation_required').error, 'refused')
  eq('named special token maps', P.adapt({ kind: 'action', exceptions: { vm: 'unsupported' } }, 'vm').error,
    'unsupported')
  eq('a plain query string is not action-mapped', P.adapt({ kind: 'text' }, 'error: not an error').data,
    'error: not an error')
})

finish()
