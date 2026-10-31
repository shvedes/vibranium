#!/usr/bin/env node
// Suite: common/path/PathPolicy.js and common/process/CommandSpec.js.
//
// Two pure-JS libraries with no filesystem, no process and no shell
// involvement, and therefore every claim they make is a claim about strings.
// That makes them the place where the tree's security vocabulary actually
// lives: what a path decision may say, what a command may carry, and which
// IPC verb a caller is allowed to believe exists.
//
// Each library's own header is the contract, and where the behaviour is
// deliberate but surprising the test says so and pins the real value rather
// than the intuitive one.

import fs from 'node:fs'
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import {
  suite,
  section,
  group,
  eq,
  ne,
  is,
  match,
  notMatch,
  contains,
  notContains,
  noThrow,
  throws,
  skip,
  show,
  finish,
} from '../../lib/assert.mjs'

// The shell tree, resolved from this file's own location the way
// text.test.mjs does. `SHELL_DIR` in the kit climbs four levels out of
// tests/shell/lib and lands on `<repo>/../shell`, which does not exist, so it
// is not usable as a load root here.
const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const REPO = path.resolve(SHELL, '..')
const PP = loadLib(path.join(SHELL, 'common', 'path', 'PathPolicy.js'))
const CS = loadLib(path.join(SHELL, 'common', 'process', 'CommandSpec.js'))


// The keys that only an allow carries. A refusal that grew one of them would
// be a path decision that reports a join it never authorised.
const ALLOW_ONLY = ['relative', 'depth', 'existing']

suite(
  'common/path + common/process + common/runtime',
  'PathPolicy, CommandSpec, IpcManifest',
)

// ---------------------------------------------------------------------------
section('PathPolicy - the root is read as a sequence of literal segments')
// ---------------------------------------------------------------------------

group('a trailing separator, a doubled separator and "." are all identity', () => {
  eq('a trailing slash is dropped', PP.lexical('/r/', 'a', {}).root, '/r')
  eq('a doubled slash is dropped', PP.lexical('//r', 'a', {}).root, '/r')
  eq('a tripled slash is dropped', PP.lexical('///r', 'a', {}).root, '/r')
  eq('an interior doubled slash is dropped', PP.lexical('/a//b', 'x', {}).root, '/a/b')
  eq('a trailing "." is identity', PP.lexical('/r/.', 'a', {}).root, '/r')
  eq('an interior "." is identity', PP.lexical('/a/./b', 'x', {}).root, '/a/b')
  eq('the filesystem root has no segments', PP.lexical('/', 'a', {}).root, '/')
  // "/" really is a root that contains a single-segment candidate, so this is
  // an allow and not a degenerate case: containment under "/" is trivially
  // true and the code says so rather than refusing a legitimate root.
  eq('a single segment below "/" is allowed', PP.lexical('/', 'a', {}).path, '/a')
  eq('a two-segment candidate below "/" is still a leaf question', PP.lexical('/', 'a/b', {}).code, 'not_leaf')
})

group('".." pops, and popping past the beginning is the escape', () => {
  eq('one pop', PP.lexical('/r/../s', 'a', {}).root, '/s')
  eq('two pops', PP.lexical('/r/s/../..', 'a', {}).root, '/')
  eq('a pop that lands back on the filesystem root is a root of "/"', PP.lexical('/r/..', 'a', {}).path, '/a')
  eq('a root that normalises to "/" contains "/etc"', PP.lexical('/r/..', '/etc', {}).path, '/etc')
  eq('popping past the beginning is an invalid root', PP.lexical('/..', 'a', {}).code, 'invalid_root')
  eq('popping past the beginning twice is an invalid root', PP.lexical('/a/../../b', 'a', {}).code, 'invalid_root')
  // The root is normalised, so a caller that spells its root with a ".." gets
  // the root it actually named, not the one it wrote. The facade then hands
  // that normalised path back, which is the only thing a later containment
  // claim could be based on.
  eq('the normalised root is what the result reports', PP.lexical('/r/../etc', 'a', {}).root, '/etc')
  eq('a root that normalises elsewhere still contains its own children', PP.lexical('/r/../etc', 'passwd', {}).path, '/etc/passwd')
})

group('a root must be a non-empty string, and a relative one needs the flag', () => {
  eq('empty string', PP.lexical('', 'a', {}).code, 'invalid_root')
  eq('null', PP.lexical(null, 'a', {}).code, 'invalid_root')
  eq('undefined', PP.lexical(undefined, 'a', {}).code, 'invalid_root')
  eq('number', PP.lexical(5, 'a', {}).code, 'invalid_root')
  eq('array', PP.lexical(['/r'], 'a', {}).code, 'invalid_root')
  eq('object', PP.lexical({ path: '/r' }, 'a', {}).code, 'invalid_root')
  // A relative root cannot anchor containment on its own, so it is refused
  // unless the caller accepts the weaker form explicitly.
  eq('a relative root is refused by default', PP.lexical('r', 'a', {}).code, 'invalid_root')
  eq('a relative root is read under the flag', PP.lexical('r', 'a', { allowRelativeRoot: true }).root, 'r')
  eq('a relative root joins without a leading slash', PP.lexical('r', 'a', { allowRelativeRoot: true }).path, 'r/a')
  // An absolute candidate under a relative root is judged on its own segments,
  // and the two do not share a prefix, so it is an escape rather than a match.
  eq('an absolute candidate under a relative root escapes', PP.lexical('r', '/a', { allowRelativeRoot: true }).code, 'escapes_root')
  // The library is string-only, so a NUL in the root is not rejected even
  // though every syscall treats it as the end of the path. The candidate side
  // does refuse one (see the NUL group below), so the two halves disagree about
  // a corrupted string; pinned because the root is caller-owned, not data.
  eq('a NUL in the root is not rejected', PP.lexical('/r\0', 'a', {}).ok, true)
  eq('the corrupted root is echoed verbatim', PP.lexical('/r\0', 'a', {}).root, '/r\0')
})

// ---------------------------------------------------------------------------
section('PathPolicy - containment is a segment prefix, never a string prefix')
// ---------------------------------------------------------------------------

group('the classic bug: a string prefix that is not a path prefix', () => {
  // This is the case a startsWith() check gets wrong. `prefixed()` compares
  // segments one by one, so a sibling whose name merely extends the root's
  // last segment is an escape, not a hit.
  eq('/home/u/.config does not authorise /home/u/.configevil/x', PP.lexical('/home/u/.config', '/home/u/.configevil/x', { allowLeaf: true }).code, 'escapes_root')
  eq('/data does not authorise /database/x', PP.lexical('/data', '/database/x', { allowLeaf: true }).code, 'escapes_root')
  eq('the sibling is not even a leaf question', PP.lexical('/home/u/.config', '/home/u/.configevil/x', {}).code, 'escapes_root')
  eq('the refused sibling is reported at its own path', PP.lexical('/home/u/.config', '/home/u/.configevil/x', {}).path, '/home/u/.configevil/x')
  eq('a one-character extension of the root name', PP.lexical('/data', '/datax', {}).code, 'escapes_root')
  // prefix = [] is a real prefix of anything, which is what makes a root of
  // "/" contain every single-segment absolute candidate.
  eq('an empty segment list prefixes everything', PP.prefixed(['a', 'b'], []), true)
  eq('a longer list is not a prefix of a shorter one', PP.prefixed(['a'], ['a', 'b']), false)
  eq('a partial string match is not a segment match', PP.prefixed(['ab'], ['a']), false)
  eq('a full segment match is a prefix', PP.prefixed(['a', 'b'], ['a']), true)
})

group('an absolute candidate is judged on length as well as on segments', () => {
  // The code distinguishes "shorter than the root" (it can only point above
  // it) from "the same length or longer" (it sits beside it or below). Both
  // are refusals; the code says which.
  eq('a strict ancestor is not_below_root', PP.lexical('/home/u/.config', '/home', {}).code, 'not_below_root')
  eq('an unrelated shorter path is not_below_root', PP.lexical('/home/u/.config', '/etc/passwd', {}).code, 'not_below_root')
  eq('the root itself is not_below_root, never a self-allow', PP.lexical('/home/u/.config', '/home/u/.config', {}).code, 'not_below_root')
  eq('a sibling of the same length is escapes_root', PP.lexical('/a/b/c', '/a/b/d', {}).code, 'escapes_root')
  eq('an unrelated path beside a one-segment root is escapes_root', PP.lexical('/data', '/etc/passwd', {}).code, 'escapes_root')
  eq('a child of the root is allowed', PP.lexical('/home/u/.config', '/home/u/.config/a', {}).ok, true)
  eq('the child depth is measured below the root', PP.lexical('/home/u/.config', '/home/u/.config/a', {}).depth, 1)
  // A root that collapses to "." is the root itself, so a candidate that also
  // collapses to nothing is a self-reference rather than a child.
  eq('"." is the root, not a child of it', PP.lexical('/r', '.', {}).code, 'not_below_root')
  eq('"a/.." is the root too', PP.lexical('/r', 'a/..', {}).code, 'not_below_root')
})

group('"relative: true" refuses an absolute candidate outright', () => {
  eq('an absolute candidate below the root is refused', PP.lexical('/r', '/r/a', { relative: true }).code, 'absolute_path')
  eq('an absolute escape is refused as absolute, not as an escape', PP.lexical('/r', '/etc/x', { relative: true }).code, 'absolute_path')
  eq('a relative candidate is unaffected', PP.lexical('/r', 'a', { relative: true }).ok, true)
  // The refusal reports the joined path even though the request never happened,
  // which is what lets a caller log what it asked for.
  eq('the refused absolute path is still reported', PP.lexical('/r', '/r/a', { relative: true }).path, '/r/a')
})

group('the relative field is the joined segment text, not the part below the root', () => {
  // For an absolute candidate `relative` is the whole path minus its leading
  // slash, so it is not something a consumer can use as a root-relative name.
  // `path` is the field to open; `relative` is a display/diagnostic string.
  eq('a relative candidate gets only its own segments', PP.lexical('/r', 'a', {}).relative, 'a')
  eq('an absolute candidate gets its whole path', PP.lexical('/home/u/.config', '/home/u/.config/a', {}).relative, 'home/u/.config/a')
  eq('a nested relative candidate keeps its separators', PP.lexical('/r', 'a/b', { allowLeaf: true }).relative, 'a/b')
  ne('the absolute form is not the part below the root', PP.lexical('/home/u/.config', '/home/u/.config/a', {}).relative, 'a')
})

// ---------------------------------------------------------------------------
section('PathPolicy - leaf versus nested, and the two flags that change it')
// ---------------------------------------------------------------------------

group('with no flags a candidate is exactly one segment below the root', () => {
  eq('one segment is allowed', PP.lexical('/r', 'a', {}).ok, true)
  eq('two segments are not_leaf', PP.lexical('/r', 'a/b', {}).code, 'not_leaf')
  eq('four segments are not_leaf', PP.lexical('/r', 'a/b/c/d', {}).code, 'not_leaf')
  eq('a refused depth still reports the joined path', PP.lexical('/r', 'a/b', {}).path, '/r/a/b')
})

group('allowLeaf admits a nested path, without changing what counts as a root', () => {
  eq('nested is allowed', PP.lexical('/r', 'a/b', { allowLeaf: true }).ok, true)
  eq('the depth is the segment count below the root', PP.lexical('/r', 'a/b/c/d', { allowLeaf: true }).depth, 4)
  eq('the escape is still refused', PP.lexical('/r', '../x', { allowLeaf: true }).code, 'invalid_candidate')
  eq('an absolute sibling is still refused', PP.lexical('/r', '/etc/x', { allowLeaf: true }).code, 'escapes_root')
  eq('the root is still not below itself', PP.lexical('/r', '/r', { allowLeaf: true }).code, 'not_below_root')
})

group('leafRelative demands a single segment and refuses to read a path', () => {
  eq('one segment is allowed', PP.lexical('/r', 'a', { leafRelative: true }).ok, true)
  eq('two segments are invalid, not a denial', PP.lexical('/r', 'a/b', { leafRelative: true }).code, 'invalid_candidate')
  eq('an absolute single segment is invalid', PP.lexical('/r', '/a', { leafRelative: true }).code, 'invalid_candidate')
  eq('"." is not a leaf name', PP.lexical('/r', '.', { leafRelative: true }).code, 'invalid_candidate')
  eq('".." is not a leaf name', PP.lexical('/r', '..', { leafRelative: true }).code, 'invalid_candidate')
  eq('an empty candidate is invalid', PP.lexical('/r', '', { leafRelative: true }).code, 'invalid_candidate')
  eq('a dotfile is a leaf name', PP.lexical('/r', '.bashrc', { leafRelative: true }).path, '/r/.bashrc')
  eq('a dotdot inside a name is just a name', PP.lexical('/r', '..bashrc', { leafRelative: true }).path, '/r/..bashrc')
  eq('singleSegment accepts a plain name', PP.singleSegment('a'), 'a')
  eq('singleSegment accepts a dotted name', PP.singleSegment('a.b'), 'a.b')
  eq('singleSegment accepts a tilde as data', PP.singleSegment('~'), '~')
  eq('singleSegment refuses ""', PP.singleSegment(''), null)
  eq('singleSegment refuses "."', PP.singleSegment('.'), null)
  eq('singleSegment refuses ".."', PP.singleSegment('..'), null)
  eq('singleSegment refuses a separator', PP.singleSegment('/'), null)
  eq('singleSegment refuses "a/b"', PP.singleSegment('a/b'), null)
})

group('the two flags answer the same question at different strengths', () => {
  eq('isLeaf is false with no flags', PP.isLeaf({}), false)
  eq('allowLeaf makes it true', PP.isLeaf({ allowLeaf: true }), true)
  eq('leafRelative makes it true', PP.isLeaf({ leafRelative: true }), true)
  eq('a false flag does not make it true', PP.isLeaf({ allowLeaf: false }), false)
  eq('an unrelated flag does not make it true', PP.isLeaf({ atomic: true }), false)
  // allowLeaf reads a path; leafRelative refuses to. Both admit the same leaf,
  // so a caller can use the stricter one without changing the decision.
  eq('both flags allow the same leaf', [PP.lexical('/r', 'a', { allowLeaf: true }).path, PP.lexical('/r', 'a', { leafRelative: true }).path], ['/r/a', '/r/a'])
})

// ---------------------------------------------------------------------------
section('PathPolicy - traversal: every escape form is refused')
// ---------------------------------------------------------------------------

group('a relative candidate that walks out of the root is invalid_candidate', () => {
  // These cannot be expressed as a denial because the candidate does not
  // reduce to a path at all: its own ".." popped past its own beginning, so
  // there is nothing left to compare against the root.
  const escapes = [
    '../x',
    '../../x',
    'a/../../x',
    'a/b/../../../x',
    'a/./../../x',
    './../x',
    '..',
    'a/../../',
    'a/b/../../..',
  ]
  for (const candidate of escapes) {
    eq(`${JSON.stringify(candidate)} is refused`, PP.lexical('/r', candidate, {}).ok, false)
    eq(`${JSON.stringify(candidate)} is not even a valid candidate`, PP.lexical('/r', candidate, {}).code, 'invalid_candidate')
  }
  // A ".." that lands back inside the root is not an escape, and a name that
  // merely looks like one is not a traversal token. Both are pinned here
  // because the escape list above is where they would be expected to be.
  eq('"a/b/.." reduces to a leaf inside the root and is allowed', PP.lexical('/r', 'a/b/..', {}).path, '/r/a')
  eq('"...." is an ordinary directory name', PP.lexical('/r', '....//x', {}).code, 'not_leaf')
  eq('"..%2fx" is an ordinary name, because nothing is decoded', PP.lexical('/r', '..%2fx', {}).path, '/r/..%2fx')
  // A Unicode-lookalike dot is data, not a traversal token.
  eq('a fullwidth full stop is an ordinary name', PP.lexical('/r', '．．/x', { allowLeaf: true }).ok, true)
})

group('an absolute candidate that walks out of the root is a denial, not an invalid one', () => {
  // The candidate reduces to a real path, so the refusal can say where it
  // pointed, and the reduced path is what gets reported.
  eq('one level out', PP.lexical('/r', '/r/../x', {}).code, 'escapes_root')
  eq('the reduced path is reported', PP.lexical('/r', '/r/../x', {}).path, '/x')
  eq('two levels out', PP.lexical('/r', '/r/a/../../x', {}).code, 'escapes_root')
  eq('a walk out of a nested root', PP.lexical('/home/u', '/home/../etc/passwd', {}).code, 'escapes_root')
  eq('a walk that lands back inside is allowed', PP.lexical('/r', '/r/a/../b', {}).ok, true)
  eq('and it is the reduced path that is authorised', PP.lexical('/r', '/r/a/../b', {}).path, '/r/b')
})

group('a candidate that reduces to the root is never a self-allow', () => {
  eq('"/r" is not below "/r"', PP.lexical('/r', '/r', {}).code, 'not_below_root')
  eq('"/r/." is not below "/r"', PP.lexical('/r', '/r/.', {}).code, 'not_below_root')
  eq('"/r/a/.." is not below "/r"', PP.lexical('/r', '/r/a/..', {}).code, 'not_below_root')
  eq('"." is not below "/r"', PP.lexical('/r', '.', {}).code, 'not_below_root')
  eq('"a/.." is not below "/r"', PP.lexical('/r', 'a/..', {}).code, 'not_below_root')
})

// ---------------------------------------------------------------------------
section('PathPolicy - spaces, quotes, Unicode and encodings are data')
// ---------------------------------------------------------------------------

group('nothing in a name is rejected and nothing is re-encoded', () => {
  // The header is explicit: quoting is a property of the shell, and data that
  // has to be quoted has already been concatenated into source upstream. So
  // the lexical pass treats every metacharacter as an ordinary character.
  const data = [
    ['a b', '/r/a b'],
    ["a'b", "/r/a'b"],
    ['a"b', '/r/a"b'],
    ['a;b|c&d$e`f', '/r/a;b|c&d$e`f'],
    ['a\\b', '/r/a\\b'],
    ['a\nb', '/r/a\nb'],
    ['a>b<c', '/r/a>b<c'],
    ['$(id)', '/r/$(id)'],
    ['a b/c d', '/r/a b/c d'],
    ['ünïcodé/файл.txt', '/r/ünïcodé/файл.txt'],
    ['日本語', '/r/日本語'],
    ['emoji-🙂', '/r/emoji-🙂'],
    ['%2e%2e%2fx', '/r/%2e%2e%2fx'],
  ]
  for (const [candidate, expected] of data) {
    const flags = candidate.includes('/') ? { allowLeaf: true } : {}
    eq(`${JSON.stringify(candidate)} is allowed as data`, PP.lexical('/r', candidate, flags).path, expected)
  }
})

group('a tilde is a name, not an expansion', () => {
  // No shell and no filesystem means no home expansion, so "~" is a literal
  // segment. A caller that wanted the home directory has to pass the resolved
  // path, which is the only form that can be contained.
  eq('a bare tilde is a leaf name', PP.lexical('/home/u', '~', {}).path, '/home/u/~')
  eq('a tilde path is a nested candidate, so it needs allowLeaf', PP.lexical('/home/u', '~/.config', {}).code, 'not_leaf')
  eq('and then it is a name, not an expansion', PP.lexical('/home/u', '~/.config', { allowLeaf: true }).path, '/home/u/~/.config')
  eq('the root is not expanded either', PP.lexical('~', 'a', { allowRelativeRoot: true }).root, '~')
})

group('percent-encoding is not decoded, and the header says the consumer must', () => {
  // "%2e%2e%2f" decodes to "../" . The header states plainly that
  // percent-encoding is not decoded here "so a consumer that decodes a name
  // must check the decoded name again", so the lexical allow here is correct
  // and the second check is the caller's job. Pinned with the decoded form
  // beside it so the gap is impossible to misread as safety.
  eq('the encoded form is allowed lexically', PP.lexical('/r', '..%2f..%2fx', {}).path, '/r/..%2f..%2fx')
  eq('the decoded form really would escape', PP.lexical('/r', decodeURIComponent('..%2f..%2fx'), {}).ok, false)
  eq('an encoded dotdot is a leaf name', PP.lexical('/r', '%2e%2e', { leafRelative: true }).path, '/r/%2e%2e')
  eq('and decoding it gives the traversal token', decodeURIComponent('%2e%2e'), '..')
})

// ---------------------------------------------------------------------------
section('PathPolicy - the degenerate inputs a per-keystroke caller produces')
// ---------------------------------------------------------------------------

group('an unusable candidate is invalid_candidate', () => {
  eq('empty string', PP.lexical('/r', '', {}).code, 'invalid_candidate')
  eq('null', PP.lexical('/r', null, {}).code, 'invalid_candidate')
  eq('undefined', PP.lexical('/r', undefined, {}).code, 'invalid_candidate')
  eq('number', PP.lexical('/r', 5, {}).code, 'invalid_candidate')
  eq('array', PP.lexical('/r', ['a'], {}).code, 'invalid_candidate')
  eq('object', PP.lexical('/r', { path: 'a' }, {}).code, 'invalid_candidate')
  eq('a NUL anywhere in the candidate', PP.lexical('/r', 'a\0b', {}).code, 'invalid_candidate')
  eq('a NUL in an absolute candidate', PP.lexical('/r', '/r/a\0b', {}).code, 'invalid_candidate')
  eq('a NUL in the first segment', PP.lexical('/r', '\0/a', {}).code, 'invalid_candidate')
})

group('an unusable options object is refused, never defaulted', () => {
  eq('undefined options', PP.lexical('/r', 'a', undefined).code, 'invalid_options')
  eq('null options', PP.lexical('/r', 'a', null).code, 'invalid_options')
  eq('an array of options', PP.lexical('/r', 'a', []).code, 'invalid_options')
  eq('a string of options', PP.lexical('/r', 'a', 'read').code, 'invalid_options')
  eq('a number of options', PP.lexical('/r', 'a', 5).code, 'invalid_options')
  eq('a function of options', PP.lexical('/r', 'a', () => ({})).code, 'invalid_options')
  eq('isOptions accepts a plain object', PP.isOptions({}), true)
  eq('isOptions accepts a null-prototype object', PP.isOptions(Object.create(null)), true)
  eq('isOptions refuses an array', PP.isOptions([]), false)
  eq('isOptions refuses null', PP.isOptions(null), false)
})

// ---------------------------------------------------------------------------
section('PathPolicy - mode and operation are closed vocabularies')
// ---------------------------------------------------------------------------

group('mode is matched for exact equality and echoes the lexical marker', () => {
  for (const mode of ['create', 'write', 'replace', 'read', 'rename_dest']) {
    eq(`${mode} is accepted`, PP.lexical('/r', 'a', { mode }).ok, true)
  }
  eq('a near-miss spelling is refused', PP.lexical('/r', 'a', { mode: 'Read' }).code, 'invalid_mode')
  eq('an empty mode is refused', PP.lexical('/r', 'a', { mode: '' }).code, 'invalid_mode')
  eq('an unknown mode is refused', PP.lexical('/r', 'a', { mode: 'delete' }).code, 'invalid_mode')
  eq('a non-string mode is refused', PP.lexical('/r', 'a', { mode: 5 }).code, 'invalid_mode')
  // The result field `mode` now echoes the requested verb instead of the
  // module's own LEXICAL marker, so a caller can read back which verb it
  // asked for.
  eq('the result mode echoes the requested verb', PP.lexical('/r', 'a', { mode: 'read' }).mode, 'read')})

group('operation is matched for exact equality against its own list', () => {
  const single = ['theme_dir', 'git_list', 'wallpaper_source', 'leaf_delete']
  const recursive = ['recursive_delete', 'recursive_copy', 'recursive_move']
  for (const operation of single) {
    eq(`${operation} is in the vocabulary`, PP.isOperation(operation), true)
    eq(`${operation} is not helper-owned`, PP.helperOwned(operation), false)
  }
  for (const operation of recursive) {
    eq(`${operation} is in the vocabulary`, PP.isOperation(operation), true)
    eq(`${operation} is helper-owned`, PP.helperOwned(operation), true)
  }
  eq('secret is in the vocabulary', PP.isOperation('secret'), true)
  eq('secret is helper-owned', PP.helperOwned('secret'), true)
  // The gates key on the exact name, so a near-miss spelling must be refused
  // before the candidate is read rather than judged as a single-path request.
  eq('a case variant is refused', PP.lexical('/r', 'a', { operation: 'Recursive_Delete' }).code, 'invalid_operation')
  eq('trailing whitespace is refused', PP.lexical('/r', 'a', { operation: 'recursive_delete ' }).code, 'invalid_operation')
  eq('a leading space is refused', PP.lexical('/r', 'a', { operation: ' secret' }).code, 'invalid_operation')
  eq('an empty operation is refused', PP.lexical('/r', 'a', { operation: '' }).code, 'invalid_operation')
  eq('a mode name is not an operation', PP.isOperation('read'), false)
  eq('a mode name passed as an operation is refused', PP.lexical('/r', 'a', { operation: 'read' }).code, 'invalid_operation')
  eq('a number is refused', PP.lexical('/r', 'a', { operation: 5 }).code, 'invalid_operation')
  eq('undefined is refused by isOperation', PP.isOperation(undefined), false)
  eq('helperOwned ignores undefined', PP.helperOwned(undefined), false)
  eq('the operation is echoed into an allow', PP.lexical('/r', 'a', { operation: 'git_list' }).operation, 'git_list')
  eq('operation() is "" for a non-string', PP.operation({ operation: 5 }), '')
})

// ---------------------------------------------------------------------------
section('PathPolicy - the gates run before any candidate is read')
// ---------------------------------------------------------------------------

group('a recursive or private request without a verified root is refused', () => {
  eq('recursive_delete needs canonicalRoot', PP.lexical('/r', 'a', { operation: 'recursive_delete' }).code, 'unverified_root')
  eq('recursive_copy needs canonicalRoot', PP.lexical('/r', 'a', { operation: 'recursive_copy' }).code, 'unverified_root')
  eq('recursive_move needs canonicalRoot', PP.lexical('/r', 'a', { operation: 'recursive_move' }).code, 'unverified_root')
  // The two refusals are deliberately different codes: a recursive request is
  // missing a root fact, a private one is missing the helper that owns the
  // open. The header names both vocabularies separately for that reason.
  eq('secret answers containment_unavailable instead', PP.lexical('/r', 'a', { operation: 'secret' }).code, 'containment_unavailable')
  eq('a secret request lists atomic as unavailable', PP.lexical('/r', 'a', { operation: 'secret' }).unavailable, ['containment_unavailable', 'atomic'])
  eq('a secret request lists file_mode as unverified', PP.lexical('/r', 'a', { operation: 'secret' }).unverified, ['symlink_escape', 'toctou', 'existence', 'file_mode'])
  eq('a recursive request does not list atomic', PP.lexical('/r', 'a', { operation: 'recursive_delete' }).unavailable, ['containment_unavailable'])
})

group('a gate refusal is reached before the candidate is examined', () => {
  // The candidate here would be refused on its own merits too, and the gate's
  // code is the one that comes back, which is what proves the ordering.
  eq('the gate wins over an escaping candidate', PP.lexical('/r', '../x', { operation: 'recursive_delete' }).code, 'unverified_root')
  eq('the gate wins over an invalid candidate', PP.lexical('/r', '', { operation: 'secret' }).code, 'containment_unavailable')
  eq('the gate refusal carries no candidate path', PP.lexical('/r', '../x', { operation: 'recursive_delete' }).path, '')
  eq('a gate refusal carries the root', PP.lexical('/r', '../x', { operation: 'recursive_delete' }).root, '/r')
  eq('an invalid root is refused before the gates run', PP.lexical('/..', '../x', { operation: 'recursive_delete' }).code, 'invalid_root')
  eq('and an invalid operation is refused before the root is read', PP.lexical('/..', 'a', { operation: 'nope' }).code, 'invalid_operation')
})

group('requireCanonical is the caller asserting it needs a verified root', () => {
  eq('the assertion without the fact is unverified_root', PP.lexical('/r', 'a', { requireCanonical: true }).code, 'unverified_root')
  eq('the assertion with the fact is allowed', PP.lexical('/r', 'a', { requireCanonical: true, canonicalRoot: true }).ok, true)
  eq('a verified root clears containment_unavailable', PP.lexical('/r', 'a', { canonicalRoot: true }).unavailable, [])
  eq('canonicalRoot is echoed as a boolean, not as the raw option', PP.lexical('/r', 'a', { canonicalRoot: 'yes' }).canonicalRoot, false)
  eq('a truthy non-boolean does not verify the root', PP.lexical('/r', 'a', { canonicalRoot: 1, operation: 'recursive_copy' }).code, 'unverified_root')
})

group('allowExisting is a leaf assertion, and a malformed combination is refused', () => {
  eq('it is refused without a leaf flag', PP.lexical('/r', 'a', { allowExisting: true }).code, 'invalid_options')
  eq('with allowLeaf it is accepted', PP.lexical('/r', 'a', { allowExisting: true, allowLeaf: true }).existing, 'allowed')
  eq('with leafRelative it is accepted', PP.lexical('/r', 'a', { allowExisting: true, leafRelative: true }).existing, 'allowed')
  eq('the default is unverified, because nothing was observed', PP.lexical('/r', 'a', {}).existing, 'unverified')
  eq('existingDecision echoes the assertion only', PP.existingDecision({ allowExisting: 'yes' }), 'unverified')
  eq('the gate fires before the candidate too', PP.lexical('/r', '../x', { allowExisting: true }).code, 'invalid_options')
})

group('a single-path operation is judged on its path alone', () => {
  // theme_dir, git_list, wallpaper_source and leaf_delete "name a single path
  // below the root, whether a directory to read or one file to remove, so none
  // of them traverses and no gate keys on them". They are in the vocabulary
  // only so a near-miss spelling cannot read as "touches one path".
  for (const operation of ['theme_dir', 'git_list', 'wallpaper_source', 'leaf_delete']) {
    eq(`${operation} allows a leaf`, PP.lexical('/r', 'a', { operation }).ok, true)
    eq(`${operation} still refuses an escape`, PP.lexical('/r', '../x', { operation }).code, 'invalid_candidate')
    eq(`${operation} is not marked secret`, PP.lexical('/r', 'a', { operation }).secret, false)
  }
  eq('a recursive operation is echoed as recursive in a batch', PP.authorize('/r', { candidates: ['a'], operation: 'recursive_copy', canonicalRoot: true }).recursive, true)
  eq('a leaf operation is not recursive in a batch', PP.authorize('/r', { candidates: ['a'], operation: 'leaf_delete' }).recursive, false)
})

// ---------------------------------------------------------------------------
section('PathPolicy - what every result says about what it did not check')
// ---------------------------------------------------------------------------

group('no result ever claims containment', () => {
  eq('an allow', PP.lexical('/r', 'a', {}).containment, 'unverified')
  eq('a denial', PP.lexical('/r', '../x', { operation: 'secret' }).containment, 'unverified')
  eq('even a verified root', PP.lexical('/r', 'a', { canonicalRoot: true }).containment, 'unverified')
  // The header: a lexical check cannot prove a symlink, a component replaced
  // between check and open, or whether a leaf already exists. Those three
  // names are therefore on every single result.
  const base = ['symlink_escape', 'toctou', 'existence']
  eq('an allow lists the three unprovables', PP.lexical('/r', 'a', {}).unverified, base)
  eq('a denial lists the three unprovables', PP.lexical('/r', '/etc/x', {}).unverified, base)
  eq('atomic adds atomic_creation', PP.unverifiedList({ atomic: true }), [...base, 'atomic_creation'])
  eq('secret adds file_mode', PP.unverifiedList({ operation: 'secret' }), [...base, 'file_mode'])
  eq('both add both, in that order', PP.unverifiedList({ operation: 'secret', atomic: true }), [...base, 'atomic_creation', 'file_mode'])
  eq('an unrelated operation adds nothing', PP.unverifiedList({ operation: 'theme_dir' }), base)
})

group('unavailable names what the shell cannot do without the helper', () => {
  eq('containment is unavailable until the root is verified', PP.unavailableList({}), ['containment_unavailable'])
  eq('a verified root clears it', PP.unavailableList({ canonicalRoot: true }), [])
  eq('atomic needs the helper that owns the open', PP.unavailableList({ canonicalRoot: true, atomic: true }), ['atomic'])
  eq('secret needs the private open', PP.unavailableList({ canonicalRoot: true, operation: 'secret' }), ['atomic'])
  eq('unverified and atomic together', PP.unavailableList({ atomic: true }), ['containment_unavailable', 'atomic'])
  eq('an atomic allow reports it', PP.lexical('/r', 'a', { atomic: true, canonicalRoot: true }).unavailable, ['atomic'])
  eq('atomic_creation is then unverified too', PP.lexical('/r', 'a', { atomic: true, canonicalRoot: true }).unverified, ['symlink_escape', 'toctou', 'existence', 'atomic_creation'])
  eq('a truthy non-boolean does not request atomic', PP.lexical('/r', 'a', { atomic: 1 }).atomic, false)
})

group('the three result shapes are disjoint in what they carry', () => {
  eq(
    'an allow has these sixteen fields',
    Object.keys(PP.lexical('/r', 'a', {})).sort(),
    ['ok', 'code', 'mode', 'operation', 'root', 'path', 'relative', 'depth', 'canonicalRoot', 'containment', 'atomic', 'secret', 'existing', 'unavailable', 'unverified'].sort(),
  )
  eq(
    'a denial has no relative, depth or existing',
    Object.keys(PP.lexical('/r', '/etc/x', {})).filter((k) => ALLOW_ONLY.includes(k)),
    [],
  )
  eq('an invalid answer is two fields', Object.keys(PP.invalid('x')), ['ok', 'code'])
  eq('an invalid answer carries no mode', PP.lexical('/r', 'a', []).mode, undefined)
  eq('a denial carries no mode field beyond the lexical marker', PP.lexical('/r', '/etc/x', {}).mode, 'lexical')
  // The three are distinguishable without reading `code`, so a consumer that
  // only branches on `ok` still cannot mistake a refusal for a join.
  is('an allow is distinguishable by ok', PP.lexical('/r', 'a', {}).ok, (v) => v === true, 'ok === true')
  is('a denial is distinguishable by ok', PP.lexical('/r', '/etc/x', {}).ok, (v) => v === false, 'ok === false')
  is('an invalid answer is distinguishable by its two fields', PP.invalid('x'), (v) => Object.keys(v).length === 2, 'two fields only')
})

// ---------------------------------------------------------------------------
section('PathPolicy - authorize is all-or-nothing')
// ---------------------------------------------------------------------------

group('a fully good batch is authorised', () => {
  const batch = PP.authorize('/r', { candidates: ['a', 'b', 'c'] })
  eq('ok', batch.ok, true)
  eq('code', batch.code, 'ok')
  eq('count', batch.count, 3)
  eq('failedIndex', batch.failedIndex, -1)
  eq('the results are in candidate order', batch.results.map((r) => r.relative), ['a', 'b', 'c'])
  eq('each result is a full allow', batch.results.map((r) => r.ok), [true, true, true])
  eq('each result carries its own path', batch.results.map((r) => r.path), ['/r/a', '/r/b', '/r/c'])
  eq('mode is the lexical marker', batch.mode, 'lexical')
  eq('root is echoed', batch.root, '/r')
  eq('rootExists is false without the assertion', batch.rootExists, false)
  eq('canonicalRoot is echoed', batch.canonicalRoot, false)
})

group('one refusal fails the whole batch and names the first one', () => {
  const batch = PP.authorize('/r', { candidates: ['a', '/etc/x', 'c', '../d'] })
  eq('ok is false even though three of four passed', batch.ok, false)
  eq('the code is the first refusal', batch.code, 'escapes_root')
  eq('failedIndex is the first refusal', batch.failedIndex, 1)
  eq('the batch is still all four results long', batch.count, 4)
  eq('the per-candidate results are still reported', batch.results.map((r) => r.ok), [true, false, true, false])
  eq('the later escape is reported as an invalid candidate', batch.results[3].code, 'invalid_candidate')
  eq('the second refusal does not overwrite the first code', batch.code, 'escapes_root')
})

group('an empty batch is a misuse, not a vacuous success', () => {
  const batch = PP.authorize('/r', { candidates: [] })
  eq('ok', batch.ok, false)
  eq('code', batch.code, 'no_candidates')
  // A refusal that happened before any candidate was judged is a plain denial
  // shape, so it has no count, no index and no results array at all. A consumer
  // that reads `results` without checking has to fail loudly rather than find
  // an empty list that looks like a completed batch, which is why the facade's
  // `_projectBatch` guards on `Array.isArray` before reading one.
  eq('failedIndex is absent, not -1', batch.failedIndex, undefined)
  eq('count is absent, not 0', batch.count, undefined)
  eq('results is absent, not empty', batch.results, undefined)
  eq('the root is still reported', batch.root, '/r')
  eq('the path is empty because no candidate was named', batch.path, '')
})

group('a single candidate and a missing one are both read', () => {
  eq('options.candidate', PP.authorize('/r', { candidate: 'a' }).count, 1)
  eq('options.candidates wins when both are present', PP.authorize('/r', { candidate: 'a', candidates: ['a', 'b'] }).count, 2)
  eq('a missing candidate is an invalid one, not a silent allow', PP.authorize('/r', {}).code, 'invalid_candidate')
  eq('and it is named at index 0', PP.authorize('/r', {}).failedIndex, 0)
  // A non-array `candidates` is not read as a candidate list; the JS helper
  // falls through to options.candidate, which is a refusal rather than a
  // permissive default. (The facade refuses a non-array candidates outright
  // with invalid_options, so this path is not reachable from QML.)
  eq('a string candidates is not a list', PP.authorize('/r', { candidates: 'a' }).code, 'invalid_candidate')
  eq('an object candidates is not a list', PP.authorize('/r', { candidates: { 0: 'a' } }).code, 'invalid_candidate')
})

group('rootExists is the conjunction of two assertions', () => {
  eq('neither assertion', PP.authorize('/r', { candidates: ['a'] }).rootExists, false)
  eq('canonicalRoot only', PP.authorize('/r', { candidates: ['a'], canonicalRoot: true }).rootExists, false)
  eq('allowExistingRoot only', PP.authorize('/r', { candidates: ['a'], allowExistingRoot: true }).rootExists, false)
  eq('both assertions', PP.authorize('/r', { candidates: ['a'], canonicalRoot: true, allowExistingRoot: true }).rootExists, true)
  eq('a truthy non-boolean is not an assertion', PP.authorize('/r', { candidates: ['a'], canonicalRoot: true, allowExistingRoot: 1 }).rootExists, false)
})

group('authorize validates its request the same way lexical does', () => {
  eq('undefined options', PP.authorize('/r', undefined).code, 'invalid_options')
  eq('an array of options', PP.authorize('/r', []).code, 'invalid_options')
  eq('a bad mode', PP.authorize('/r', { candidates: ['a'], mode: 'nope' }).code, 'invalid_mode')
  eq('a bad operation', PP.authorize('/r', { candidates: ['a'], operation: 'nope' }).code, 'invalid_operation')
  eq('an invalid root', PP.authorize('', { candidates: ['a'] }).code, 'invalid_root')
  eq('a gate refusal beats the batch', PP.authorize('/r', { candidates: ['a'], operation: 'recursive_delete' }).code, 'unverified_root')
  eq('a gate refusal carries no results at all', PP.authorize('/r', { candidates: ['a'], operation: 'recursive_delete' }).results, undefined)
  eq('an invalid answer is the two-field shape', Object.keys(PP.authorize('/r', [])), ['ok', 'code'])
})

group('a refusal never leaks into an allow', () => {
  // Two things are checked: the batch verdict is false, and the refused
  // candidate's own result carries none of the fields only an allow has, so a
  // consumer reading the results array cannot recover a join it was refused.
  const batch = PP.authorize('/r', { candidates: ['a', '/etc/x', 'c'] })
  const refused = batch.results[1]
  eq('the batch is refused', batch.ok, false)
  eq('the refused result is refused', refused.ok, false)
  eq('it has a code', refused.code, 'escapes_root')
  for (const key of ALLOW_ONLY) {
    is(`${key} is absent from a refusal`, refused, (v) => !(key in v), `${key} not in a denial`)
  }
  // The refused path is reported for logging, and it is reported as the path
  // that was refused, never as a path inside the root.
  eq('the refused path is the one asked for', refused.path, '/etc/x')
  notContains('and it does not name the root as a prefix of itself', refused.relative === undefined ? 'no relative field' : refused.relative, '/r')
  // An allowed sibling in the same batch still reports its own allow, and the
  // batch verdict is what tells the caller to ignore it.
  eq('an allowed sibling keeps its own decision', batch.results[0].ok, true)
  eq('the batch verdict overrides it', batch.ok, false)
  eq('failedIndex points at the refused sibling', batch.failedIndex, 1)
})

// ---------------------------------------------------------------------------
section('PathPolicy - the string helpers, called directly')
// ---------------------------------------------------------------------------

group('segments() is the whole normalisation rule', () => {
  eq('an absolute path', PP.segments('/a/b', true), { segments: ['a', 'b'], absolute: true, path: '/a/b' })
  eq('a relative path needs the permissive flag', PP.segments('a/b'), null)
  eq('a relative path with the flag', PP.segments('a/b', true), { segments: ['a', 'b'], absolute: false, path: 'a/b' })
  eq('the filesystem root', PP.segments('/', true), { segments: [], absolute: true, path: '/' })
  eq('"." is identity', PP.segments('/a/./b', true).path, '/a/b')
  eq('".." pops', PP.segments('/a/b/..', true).path, '/a')
  eq('a pop past the beginning is null', PP.segments('/..', true), null)
  eq('the first segment decides absoluteness, not the spelling', PP.segments('a/b', true).absolute, false)
})

group('under() is where the root and the relative text are glued', () => {
  const base = { segments: ['r'], path: '/r' }
  eq('a relative target keeps the root', PP.under(base, { segments: ['a', 'b'], absolute: false }), '/r/a/b')
  eq('an absolute target is read at its own place', PP.under(base, { segments: ['a'], absolute: true }), '/a')
  eq('an empty root does not leave a doubled slash', PP.under({ segments: [], path: '/' }, { segments: ['a'], absolute: false }), '/a')
  eq('an empty relative text leaves a trailing slash', PP.under(base, { segments: [], absolute: false }), '/r/')
  eq('a relative root joins without a leading slash', PP.under({ segments: ['r'], path: 'r' }, { segments: ['a'], absolute: false }), 'r/a')
})

group('targetLexical refuses a data-shaped path before the root is consulted', () => {
  eq('a NUL', PP.targetLexical('a\0b', {}), null)
  eq('a number', PP.targetLexical(5, {}), null)
  eq('an empty string', PP.targetLexical('', {}), null)
  eq('a single segment', PP.targetLexical('a', {}), { segments: ['a'], absolute: false, path: 'a' })
  eq('leafRelative collapses to one segment', PP.targetLexical('a', { leafRelative: true }), { segments: ['a'], absolute: false })
  // The leafRelative branch builds its record by hand and omits `path`, which
  // `segments()` always carries. Nothing reads it - `evaluate`, `under` and
  // `allowed` use `segments` and `absolute` and join the text themselves - so
  // the omission is invisible above this line. Pinned because an internal
  // record that is shaped differently depending on the flag is a trap for the
  // next reader of this function.
  is('the leaf record has no path field', PP.targetLexical('a', { leafRelative: true }), (v) => !('path' in v), 'path absent')
  is('the segmented record does have one', PP.targetLexical('a', {}), (v) => 'path' in v, 'path present')
  eq('leafRelative refuses a path', PP.targetLexical('a/b', { leafRelative: true }), null)
})

group('rootLexical is the only place a relative root is refused', () => {
  eq('an absolute root', PP.rootLexical('/r', {}).path, '/r')
  eq('a relative root without the flag', PP.rootLexical('r', {}), null)
  eq('a relative root with the flag', PP.rootLexical('r', { allowRelativeRoot: true }).path, 'r')
  eq('a non-string root', PP.rootLexical(5, {}), null)
})

group('none of these functions throw, whatever the caller passes', () => {
  const roots = ['/r', '/r/..', 'r', '', '/..', '//', '~', '日本', null, undefined, 5, [], {}]
  const candidates = ['a', 'a/b', '../a', '/r/a', '~', '%2e%2e', 'a\0b', '', null, 5, [], {}, '\n']
  const options = [
    {},
    { allowLeaf: true },
    { leafRelative: true },
    { relative: true },
    { atomic: true, canonicalRoot: true },
    { allowExisting: true },
    { operation: 'secret', canonicalRoot: true },
    { operation: 'recursive_delete', canonicalRoot: true },
    { mode: 'read' },
    { allowRelativeRoot: true },
    { candidates: [], candidate: 'a' },
  ]
  let thrown = 0
  let ran = 0
  for (const root of roots) {
    for (const candidate of candidates) {
      for (const option of options) {
        ran++
        try {
          PP.lexical(root, candidate, option)
          PP.authorize(root, { ...option, candidates: [candidate, 'b'], candidate })
        } catch (e) {
          thrown++
          process.stdout.write(`        threw: ${show(root)} + ${show(candidate)} + ${show(option)} -> ${e.message}\n`)
        }
      }
    }
  }
  is('the whole matrix ran', ran, (v) => v === roots.length * candidates.length * options.length, 'every combination ran')
  eq('nothing threw', thrown, 0)
  // The kit's own idiom for this contract, on the shapes a caller actually
  // produces while the user is still typing.
  noThrow('lexical with no arguments at all', () => PP.lexical())
  noThrow('lexical with three nulls', () => PP.lexical(null, null, null))
  noThrow('lexical with a candidate before a root is chosen', () => PP.lexical('', '', {}))
  noThrow('authorize with no arguments at all', () => PP.authorize())
  noThrow('authorize with a root and nothing else', () => PP.authorize('/r'))
  noThrow('authorize with a null root', () => PP.authorize(null, null))
  eq('and they still answer a defined refusal', PP.lexical().code, 'invalid_options')
  eq('which for authorize is also a refusal', PP.authorize().code, 'invalid_options')
})

// ---------------------------------------------------------------------------
section('CommandSpec - argv: data as elements, never as source')
// ---------------------------------------------------------------------------

group('a real argv is accepted and copied', () => {
  eq('a two-element command', CS.argv(['echo', 'hi']), { ok: true, code: 'ok', mode: 'argv', argv: ['echo', 'hi'] })
  eq('a one-element command', CS.argv(['ls']), { ok: true, code: 'ok', mode: 'argv', argv: ['ls'] })
  eq('a command with flags', CS.argv(['grep', '-e', '--color=auto', 'file']), { ok: true, code: 'ok', mode: 'argv', argv: ['grep', '-e', '--color=auto', 'file'] })
  // The copy is what keeps a caller that mutates its array after the call from
  // changing a command that was already judged.
  const source = ['echo']
  const result = CS.argv(source)
  source.push('surprise')
  eq('the result is a copy', result.argv, ['echo'])
  eq('the caller keeps its own array', source, ['echo', 'surprise'])
})

group('every shell metacharacter is data in an argv element', () => {
  // The header: "data reaches a process as an argv element ... never as shell
  // source". Nothing here is interpreted, so nothing here is rejected.
  const nasty = [
    '; rm -rf /',
    '`id`',
    '$(id)',
    'a\nrm -rf /',
    "it's",
    'a"b',
    'a b',
    'a|b',
    'a>b<c',
    'a&b',
    '*',
    '~',
    '../../etc/passwd',
    '\\x00',
    'ünïcodé',
  ]
  for (const value of nasty) {
    const result = CS.argv(['sh', '-c', value])
    eq(`${JSON.stringify(value)} travels as one element`, result.argv, ['sh', '-c', value])
  }
  eq('a newline in an element is not a separator', CS.argv(['sh', '-c', 'a\nb']).argv.length, 3)
})

group('argv refuses anything that is not a non-empty NUL-free string', () => {
  eq('an empty array', CS.argv([]), { ok: false, code: 'invalid_argv' })
  eq('a string', CS.argv('echo'), { ok: false, code: 'invalid_argv' })
  eq('undefined', CS.argv(undefined), { ok: false, code: 'invalid_argv' })
  eq('null', CS.argv(null), { ok: false, code: 'invalid_argv' })
  eq('an object with numeric keys', CS.argv({ 0: 'echo' }), { ok: false, code: 'invalid_argv' })
  eq('an empty element', CS.argv(['echo', '']), { ok: false, code: 'invalid_argv' })
  eq('an empty command name', CS.argv(['']), { ok: false, code: 'invalid_argv' })
  eq('a number element', CS.argv(['echo', 5]), { ok: false, code: 'invalid_argv' })
  eq('a null element', CS.argv(['echo', null]), { ok: false, code: 'invalid_argv' })
  eq('an undefined element', CS.argv(['echo', undefined]), { ok: false, code: 'invalid_argv' })
  eq('a nested array element', CS.argv([['echo']]), { ok: false, code: 'invalid_argv' })
  eq('a NUL element', CS.argv(['echo', 'a\0b']), { ok: false, code: 'invalid_argv' })
  eq('a lone NUL element', CS.argv(['echo', '\0']), { ok: false, code: 'invalid_argv' })
  eq('a space is data, not emptiness', CS.argv(['echo', ' ']).ok, true)
  eq('isData is the whole element rule', [CS.isData('a'), CS.isData(''), CS.isData('a\0b'), CS.isData(5)], [true, false, false, false])
})

// ---------------------------------------------------------------------------
section('CommandSpec - templateShell: /bin/sh -c template sh arg1...')
// ---------------------------------------------------------------------------

group('the reference form is exactly the documented argv', () => {
  eq('a one-hole template', CS.templateShell('notify-send "$1"', ['hi']), {
    ok: true,
    code: 'ok',
    mode: 'template',
    argv: ['/bin/sh', '-c', 'notify-send "$1"', 'sh', 'hi'],
    env: [],
    interpolation: 'none',
  })
  eq('a hole-free template still gets the fixed $0', CS.templateShell('echo hello', []).argv, ['/bin/sh', '-c', 'echo hello', 'sh'])
  // $0 is the fixed argv[3], so data starts at $1 and the arg list is appended
  // after it rather than replacing it.
  eq('$0 is fixed by the builder', CS.templateShell('echo "$0" x', []).code, 'unrecognised_hole')
  eq('the arg list is copied, not aliased', (() => {
    const args = ['a']
    const r = CS.templateShell('echo "$1"', args)
    args.push('b')
    return r.argv
  })(), ['/bin/sh', '-c', 'echo "$1"', 'sh', 'a'])
  eq('extra args beyond maxRef are carried through', CS.templateShell('echo "$1"', ['a', 'b', 'c']).argv.length, 7)
  eq('the template text is preserved byte for byte', CS.templateShell('  echo   "$1"  ', ['a']).argv[2], '  echo   "$1"  ')
  eq('a tab separator is a separator for the word scan', CS.templateShell('echo\t"$1"', ['a']).ok, true)
  eq('a newline separator is a separator too', CS.templateShell('echo\n"$1"', ['a']).ok, true)
})

group('every hole position is counted, and too many is refused', () => {
  eq('$1', CS.templateShell('echo "$1"', ['a']).ok, true)
  eq('${1}', CS.templateShell('echo "${1}"', ['a']).ok, true)
  eq('$2 needs two args', CS.templateShell('echo "$2"', ['a']).code, 'arg_count_mismatch')
  eq('$2 with two args', CS.templateShell('echo "$2"', ['a', 'b']).ok, true)
  eq('$9 needs nine args', CS.templateShell('echo "$9"', ['a']).code, 'arg_count_mismatch')
  eq('${10} needs ten args', CS.templateShell('echo "${10}"', Array(10).fill('a')).ok, true)
  eq('the highest reference is the one counted', CS.templateShell('echo "$1" "$5"', ['a', 'b']).code, 'arg_count_mismatch')
  eq('with five args it is accepted', CS.templateShell('echo "$1" "$5"', Array(5).fill('a')).ok, true)
  eq('too few args is refused too', CS.templateShell('echo "$1"', []).code, 'arg_count_mismatch')
  // A template that names no hole needs no args, so this is not a count
  // question at all: the arg list is allowed to be longer than it uses.
  eq('a hole-free template accepts any arg count', CS.templateShell('echo hi', ['a', 'b']).ok, true)
  eq('a single-quoted $1 is a literal, so it consumes no hole', CS.templateShell("echo '$1'", []).ok, true)
  eq('and the single quotes survive into the source', CS.templateShell("echo '$1'", []).argv[2], "echo '$1'")
  eq('holeIndex takes the highest number in a word', [CS.holeIndex('"$1"'), CS.holeIndex('"$1" "$5"'), CS.holeIndex('abc'), CS.holeIndex('"${12}"')], [1, 5, 0, 12])
  eq('a leading zero is a position, not $0', [CS.holeIndex('"$01"'), CS.holeIndex('"$10"')], [1, 10])
  eq('$01 needs one arg', CS.templateShell('echo "$01"', ['a']).ok, true)
  eq('templateForm reports the highest reference', CS.templateForm('echo "$1" "$2"'), { maxRef: 2 })
  eq('templateForm reports zero for a literal template', CS.templateForm('echo hi'), { maxRef: 0 })
})

group('$0 is refused because the builder fixes it', () => {
  eq('a double-quoted $0', CS.templateShell('echo "$0"', ['a']).code, 'unrecognised_hole')
  eq('a braced ${0}', CS.templateShell('echo "${0}"', ['a']).code, 'unrecognised_hole')
  eq('hasZeroReference finds $0', CS.hasZeroReference('"$0"'), true)
  eq('hasZeroReference finds ${0}', CS.hasZeroReference('"${0}"'), true)
  eq('hasZeroReference finds $0 in $0$1', CS.hasZeroReference('"$0$1"'), true)
  eq('hasZeroReference finds $0 in $0x', CS.hasZeroReference('"$0x"'), true)
  eq('hasZeroReference leaves $1 alone', CS.hasZeroReference('"$1"'), false)
  eq('hasZeroReference leaves $10 alone', CS.hasZeroReference('"$10"'), false)
  eq('hasZeroReference leaves $01 alone', CS.hasZeroReference('"$01"'), false)
  // A single-quoted $0 never reaches the check: the word is inert literal text,
  // and the shell sees a literal too, so nothing is being impersonated.
  eq('a single-quoted $0 is literal text', CS.hasZeroReference("'$0'"), true)
  eq('and the template is accepted', CS.templateShell("echo '$0'", []).ok, true)
  // positionalOnly itself accepts $0, so the refusal is the word check's, not
  // the reference scan's. That ordering is what makes the two codes distinct.
  eq('positionalOnly accepts $0', CS.positionalOnly('echo "$0"'), true)
  eq('the refusal is unrecognised_hole, not unexpanded_reference', CS.templateShell('echo "$0"', ['a']).code, 'unrecognised_hole')
})

group('a reference must be quoted, or the interpreter would split and glob it', () => {
  eq('an unquoted $1 is refused', CS.templateShell('echo $1', ['a']).code, 'unrecognised_hole')
  eq('an unquoted ${1} is refused', CS.templateShell('echo ${1}', ['a']).code, 'unrecognised_hole')
  eq('a quoted reference is a reference', CS.templateWord('"$1"'), 'reference')
  eq('a bare word is a literal', CS.templateWord('abc'), 'literal')
  eq('a flag is a literal', CS.templateWord('--flag'), 'literal')
  eq('a path is a literal', CS.templateWord('/usr/bin/env'), 'literal')
  eq('a single-quoted word is a literal', CS.templateWord("'abc'"), 'literal')
  eq('the whole template may be one quoted reference', CS.templateShell('"$1"', ['a']).ok, true)
})

group('every $ must open a positional reference', () => {
  const refused = [
    'echo $HOME',
    'echo $(id)',
    'echo $((1+1))',
    'echo "$@"',
    'echo $?',
    'echo $$',
    'echo ${#1}',
    'echo "a$b"',
    'echo ${1:-x}',
  ]
  for (const template of refused) {
    eq(`${JSON.stringify(template)} is refused as an unexpanded reference`, CS.templateShell(template, ['a']).code, 'unexpanded_reference')
  }
  // "$1x" is the boundary between the two refusals: the scan is satisfied by
  // the "$1" prefix, so the refusal comes from the word check instead, which
  // also means no unquoted expansion can slip through with a suffix attached.
  eq('"$1x" passes the reference scan', CS.positionalOnly('echo $1x'), true)
  eq('and is refused by the word check', CS.templateShell('echo $1x', ['a']).code, 'unrecognised_hole')
  eq('positionalOnly accepts a positional', CS.positionalOnly('"$1"'), true)
  eq('positionalOnly accepts several', CS.positionalOnly('"$1" "$2"'), true)
  eq('positionalOnly accepts a template with no $', CS.positionalOnly('echo hi'), true)
  eq('positionalOnly refuses a variable', CS.positionalOnly('echo $HOME'), false)
})

group('a word carrying shell syntax is source, not a name', () => {
  // INERT_WORD excludes separators, operators, substitutions, quoting
  // characters, globbing and every expansion sigil, so each of these is a
  // candidate for the trusted form and its own trust decision.
  const refused = [
    'echo | cat',
    'echo; cat',
    'echo && cat',
    'echo || cat',
    'echo > /etc/passwd',
    'echo >x',
    'echo < in',
    'echo >> out',
    'echo 2>&1',
    '(cat)',
    'echo {a,b}',
    'echo [ab]',
    'echo !x',
    'echo #x',
    'echo a\\b',
    'echo a^b',
    'echo ~',
    'echo `id`',
  ]
  for (const template of refused) {
    eq(`${JSON.stringify(template)} is refused as a hole the form does not recognise`, CS.templateShell(template, ['a']).code, 'unrecognised_hole')
  }
  // "$x" reaches this group only when the reference scan is not what refuses
  // it; here it is refused by the scan, so the code is the other one. Both are
  // refusals and the distinction is only about which rule caught it.
  eq('"$x" is caught by the reference scan, not the word check', CS.templateShell('echo $x', ['a']).code, 'unexpanded_reference')
  eq('the word check agrees it is not inert', CS.templateWord('$x'), null)
})

group('a quoted word may not be opened early or escaped out of', () => {
  eq('an unterminated single quote', CS.templateShell("echo 'a", []).code, 'unrecognised_hole')
  eq('a quote inside a single-quoted word', CS.templateShell("echo 'a'b", []).code, 'unrecognised_hole')
  eq('a backtick inside double quotes', CS.templateShell('echo "`id`"', []).code, 'unrecognised_hole')
  eq('a backslash inside double quotes', CS.templateShell('echo "a\\b"', []).code, 'unrecognised_hole')
  eq('an inner double quote', CS.templateShell('echo "a"b"', []).code, 'unrecognised_hole')
  eq('an empty double-quoted word is inert', CS.templateShell('echo ""', []).ok, true)
  eq('a variable inside double quotes', CS.templateShell('echo "$HOME"', ['a']).code, 'unexpanded_reference')
  // The word scan splits on whitespace, so a quoted word may not contain a
  // space: the word `"a` is unbalanced and the form refuses it. Pinned because
  // it reads as a quoting bug at review time and is really a word-split rule.
  eq('a quoted word with a space is refused', CS.templateShell('echo "a b"', ['a']).code, 'unrecognised_hole')
})

group('the template itself must be a usable string', () => {
  eq('an empty template', CS.templateShell('', []), { ok: false, code: 'invalid_template' })
  eq('a whitespace-only template', CS.templateShell('   ', []), { ok: false, code: 'invalid_template' })
  eq('a tab-only template', CS.templateShell('\t\n', []), { ok: false, code: 'invalid_template' })
  eq('a non-string template', CS.templateShell(null, []), { ok: false, code: 'invalid_template' })
  eq('a number template', CS.templateShell(5, []), { ok: false, code: 'invalid_template' })
  eq('a NUL in the template', CS.templateShell('echo "\0"', []), { ok: false, code: 'invalid_template' })
  eq('a non-array args', CS.templateShell('echo', 'a'), { ok: false, code: 'invalid_args' })
  eq('undefined args', CS.templateShell('echo', undefined), { ok: false, code: 'invalid_args' })
  eq('an object of args', CS.templateShell('echo', { 0: 'a' }), { ok: false, code: 'invalid_args' })
})

group('the builder validates the form, not the data it carries', () => {
  // `argv()` runs isData over every element; `templateShell()` does not run
  // isData over args at all, because the README's gate column for this builder
  // is positionalOnly/templateForm/maxRef and nothing else. Pinned so the
  // asymmetry is visible: a caller that wants the element rule must apply
  // `argv()` to the same list.
  eq('an empty arg is carried through', CS.templateShell('echo "$1"', ['']).argv[4], '')
  eq('a number arg is carried through', CS.templateShell('echo "$1"', [5]).argv[4], 5)
  eq('a NUL arg is carried through', CS.templateShell('echo "$1"', ['a\0b']).argv[4], 'a\0b')
  eq('but argv refuses the same values', [CS.argv(['echo', '']).code, CS.argv(['echo', 5]).code, CS.argv(['echo', 'a\0b']).code], ['invalid_argv', 'invalid_argv', 'invalid_argv'])
})

group('the template is caller-owned literal, so it may name any word', () => {
  // The header scopes the contract to data: "A template may only name a
  // command and pass it data", and the template is a literal in the caller.
  // INERT_WORD cannot tell a program name from a shell builtin, so `.` and
  // `eval` are inert words and are accepted. The trust boundary is the
  // template's author, not this function; pinned so it is a decision somebody
  // made rather than an accident.
  eq('the source builtin is an inert word', CS.templateShell('. /etc/x', []).ok, true)
  eq('eval is an inert word', CS.templateShell('eval "$1"', ['id']).ok, true)
  eq('an assignment word is inert', CS.templateShell('FOO=1 env', []).ok, true)
  eq('the colon builtin is inert', CS.templateShell(':', []).ok, true)
  eq('a relative path word is inert', CS.templateShell('script.sh', []).ok, true)
  eq('templateWord says so for each', [CS.templateWord('.'), CS.templateWord('FOO=1'), CS.templateWord('script.sh')], ['literal', 'literal', 'literal'])
})

// ---------------------------------------------------------------------------
section('CommandSpec - trustedShell: an explicit trust decision')
// ---------------------------------------------------------------------------

group('nothing runs without trusted: true, exactly', () => {
  eq('a fixed script with trust', CS.trustedShell('ls -la | wc -l', { trusted: true }), {
    ok: true,
    code: 'ok',
    mode: 'trusted_shell',
    argv: ['/bin/sh', '-c', 'ls -la | wc -l', 'sh'],
    env: [],
    interpolation: 'none',
  })
  eq('no options at all', CS.trustedShell('ls', null), { ok: false, code: 'invalid_options' })
  eq('an array of options', CS.trustedShell('ls', []), { ok: false, code: 'invalid_options' })
  eq('a missing claim', CS.trustedShell('ls', {}), { ok: false, code: 'untrusted_shell' })
  eq('a false claim', CS.trustedShell('ls', { trusted: false }), { ok: false, code: 'untrusted_shell' })
  eq('a truthy non-boolean claim is still no claim', CS.trustedShell('ls', { trusted: 1 }), { ok: false, code: 'untrusted_shell' })
  eq('a truthy string claim is still no claim', CS.trustedShell('ls', { trusted: 'yes' }), { ok: false, code: 'untrusted_shell' })
  eq('an empty script', CS.trustedShell('   ', { trusted: true }), { ok: false, code: 'invalid_script' })
  eq('a non-string script', CS.trustedShell(null, { trusted: true }), { ok: false, code: 'invalid_script' })
  eq('a number script', CS.trustedShell(5, { trusted: true }), { ok: false, code: 'invalid_script' })
  // This is the form the README calls the compatibility form: fixed source that
  // genuinely needs shell features, so a pipeline here is the point.
  eq('a pipeline is allowed in the trusted form', CS.trustedShell('a | b; c && d', { trusted: true }).ok, true)
})

group('the interpreter and $0 are fixed unless the caller names them', () => {
  eq('the default shell and name', CS.shellArgv('ls', {}), ['/bin/sh', '-c', 'ls', 'sh'])
  eq('a named shell', CS.shellArgv('ls', { shell: '/bin/bash' }), ['/bin/bash', '-c', 'ls', 'sh'])
  eq('a named $0', CS.shellArgv('ls', { argv0: 'mysh' }), ['/bin/sh', '-c', 'ls', 'mysh'])
  eq('both named', CS.shellArgv('ls', { shell: '/bin/bash', argv0: 'x' }), ['/bin/bash', '-c', 'ls', 'x'])
  eq('the defaults in a result', CS.trustedShell('ls', { trusted: true }).argv, ['/bin/sh', '-c', 'ls', 'sh'])
  eq('a named shell in a result', CS.trustedShell('ls', { trusted: true, shell: '/bin/bash' }).argv, ['/bin/bash', '-c', 'ls', 'sh'])
  eq('a named $0 in a result', CS.trustedShell('ls', { trusted: true, argv0: 'shell' }).argv, ['/bin/sh', '-c', 'ls', 'shell'])
  // The shell is argv[0], not a command line, so a name carrying spaces is
  // one argv element and never re-parsed by anything.
  eq('a shell path with a space is still one element', CS.trustedShell('ls', { trusted: true, shell: '/bin/sh -c x' }).argv[0], '/bin/sh -c x')
  eq('an empty shell is refused', CS.trustedShell('ls', { trusted: true, shell: '' }), { ok: false, code: 'invalid_shell' })
  eq('a non-string shell is refused', CS.trustedShell('ls', { trusted: true, shell: 5 }), { ok: false, code: 'invalid_shell' })
  eq('a shell with a NUL is refused', CS.trustedShell('ls', { trusted: true, shell: '/bin/\0sh' }), { ok: false, code: 'invalid_shell' })
  eq('a non-string $0 is refused', CS.trustedShell('ls', { trusted: true, argv0: 5 }), { ok: false, code: 'invalid_argv0' })
  eq('an empty $0 is refused', CS.trustedShell('ls', { trusted: true, argv0: '' }), { ok: false, code: 'invalid_argv0' })
})

group('the env channel is off unless it is claimed and valid', () => {
  eq('an env with the claim off is not carried', CS.trustedShell('ls', { trusted: true, env: { '1BAD': 'x' } }).env, [])
  eq('and the claim off is not a reason to refuse', CS.trustedShell('ls', { trusted: true, env: { '1BAD': 'x' } }).ok, true)
  eq('a valid env with the claim on', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { A: '1' } }).env, ['A=1'])
  eq('an invalid name with the claim on is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { '1A': 'x' } }), { ok: false, code: 'invalid_env' })
  eq('a name carrying = is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { 'A=B': 'x' } }), { ok: false, code: 'invalid_env' })
  eq('an empty name is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { '': 'x' } }), { ok: false, code: 'invalid_env' })
  eq('a name with a space is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { 'A B': 'x' } }), { ok: false, code: 'invalid_env' })
  eq('a name with a dash is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { 'A-B': 'x' } }), { ok: false, code: 'invalid_env' })
  eq('a non-string value is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { A: 1 } }), { ok: false, code: 'invalid_env' })
  eq('a NUL in a value is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: { A: 'a\0b' } }), { ok: false, code: 'invalid_env' })
  eq('an array env is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: [] }), { ok: false, code: 'invalid_env' })
  eq('a string env is refused', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: 'A=1' }), { ok: false, code: 'invalid_env' })
  eq('no env at all is fine with the claim on', CS.trustedShell('ls', { trusted: true, trusted_env: true }).env, [])
  eq('an empty object env is fine', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: {} }).env, [])
})

group('isIdentifier is the shape an env name and a hole name must have', () => {
  eq('a plain name', CS.isIdentifier('A'), true)
  eq('an underscore start', CS.isIdentifier('_x'), true)
  eq('digits after the first', CS.isIdentifier('A_1'), true)
  eq('a lowercase start', CS.isIdentifier('a'), true)
  eq('a leading digit is refused', CS.isIdentifier('1A'), false)
  eq('a dash is refused', CS.isIdentifier('A-B'), false)
  eq('an equals sign is refused', CS.isIdentifier('A=B'), false)
  eq('a space is refused', CS.isIdentifier('A B'), false)
  eq('an empty name is refused', CS.isIdentifier(''), false)
  eq('a non-string is refused', CS.isIdentifier(5), false)
  eq('a Unicode name is refused', CS.isIdentifier('é'), false)
  eq('a dollar-prefixed name is refused', CS.isIdentifier('$A'), false)
  // __proto__ matches the identifier shape. It is inert here because the
  // channel produces `NAME=VALUE` strings and never builds an object, which is
  // why this is worth pinning rather than assuming.
  eq('__proto__ matches the identifier shape', CS.isIdentifier('__proto__'), true)
  eq('an own __proto__ env key is accepted', CS.validEnv(JSON.parse('{"__proto__":"x"}')), true)
  eq('and it still becomes a plain string', CS.normalizeEnv(JSON.parse('{"__proto__":"x"}')), ['__proto__=x'])
})

group('validEnv and normalizeEnv agree about what an env is', () => {
  eq('undefined is a valid env', CS.validEnv(undefined), true)
  eq('an empty object is valid', CS.validEnv({}), true)
  eq('null is not', CS.validEnv(null), false)
  eq('a number is not', CS.validEnv(5), false)
  eq('a string is not', CS.validEnv('A=1'), false)
  eq('an array is not', CS.validEnv([]), false)
  eq('normalizeEnv of undefined is empty', CS.normalizeEnv(undefined), [])
  eq('normalizeEnv of an empty object is empty', CS.normalizeEnv({}), [])
  eq('names are sorted, so the same options are byte-identical', CS.normalizeEnv({ C: '3', A: '1', B: '2' }), ['A=1', 'B=2', 'C=3'])
  eq('an equals sign in a value is carried, not split', CS.normalizeEnv({ A: 'x=y' }), ['A=x=y'])
  eq('a newline in a value is carried', CS.normalizeEnv({ A: 'x\ny' }), ['A=x\ny'])
  eq('an empty value is still a NAME= entry', CS.normalizeEnv({ A: '' }), ['A='])
  eq('sorting is by code unit, not by locale', CS.normalizeEnv({ a: '1', B: '2' }), ['B=2', 'a=1'])
})

group('an interpolation claim is a manifest of identifiers, not a channel', () => {
  eq('the default is no interpolation', CS.trustedShell('ls $X', { trusted: true }).interpolation, 'none')
  eq('a claim with names turns it on', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: ['X'] }).interpolation, 'interpolation')
  eq('the holes are not carried in the result', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: ['X'] }).holes, undefined)
  eq('a claim with no holes changes nothing and is refused', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: [] }), { ok: false, code: 'invalid_hole' })
  eq('a claim with a bad name is refused', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: ['1X'] }), { ok: false, code: 'invalid_hole' })
  eq('a claim with a dash in a name is refused', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: ['a-b'] }), { ok: false, code: 'invalid_hole' })
  eq('a non-array holes is refused', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: 'X' }), { ok: false, code: 'invalid_hole' })
  eq('a numeric name is refused', CS.trustedShell('ls $X', { trusted: true, trusted_interpolation: true, holes: [5] }), { ok: false, code: 'invalid_hole' })
  eq('holes are not validated without the claim', CS.trustedShell('ls $X', { trusted: true, holes: [5] }).ok, true)
  eq('validHoles of undefined is true', CS.validHoles(undefined), true)
  eq('validHoles of an empty list is false', CS.validHoles([]), false)
  eq('validHoles of a good list is true', CS.validHoles(['a', '_B', 'C9']), true)
})

group('the two result constructors are the whole result vocabulary', () => {
  eq('result() prepends ok/code/mode', Object.keys(CS.result('m', { a: 1 })), ['ok', 'code', 'mode', 'a'])
  eq('result() is ok', CS.result('m', {}).ok, true)
  eq('result() code', CS.result('m', {}).code, 'ok')
  eq('result() echoes the mode', CS.result('m', {}).mode, 'm')
  eq('invalid() is two fields', Object.keys(CS.invalid('c')), ['ok', 'code'])
  eq('invalid() is not ok', CS.invalid('c').ok, false)
  eq('invalid() keeps the code verbatim', CS.invalid('weird_code').code, 'weird_code')
  // Every code the module can answer, so a new one shows up as a diff here.
  const codes = new Set()
  for (const r of [
    CS.argv([]),
    CS.trustedShell('', { trusted: true }),
    CS.trustedShell('ls', {}),
    CS.trustedShell('ls', null),
    CS.trustedShell('ls', { trusted: true, shell: '' }),
    CS.trustedShell('ls', { trusted: true, argv0: '' }),
    CS.trustedShell('ls', { trusted: true, trusted_env: true, env: [] }),
    CS.trustedShell('ls', { trusted: true, trusted_interpolation: true, holes: [] }),
    CS.templateShell('', []),
    CS.templateShell('echo', 'a'),
    CS.templateShell('echo $X', []),
    CS.templateShell('echo | cat', []),
    CS.templateShell('echo "$1"', []),
  ]) {
    codes.add(r.code)
  }
  eq('the refusal vocabulary is exactly these thirteen', [...codes].sort(), [
    'arg_count_mismatch',
    'invalid_argv',
    'invalid_args',
    'invalid_env',
    'invalid_hole',
    'invalid_options',
    'invalid_script',
    'invalid_shell',
    'invalid_argv0',
    'invalid_template',
    'unexpanded_reference',
    'unrecognised_hole',
    'untrusted_shell',
  ].sort())
})

group('nothing here throws, whatever the caller passes', () => {
  const scripts = ['', '   ', 'ls', 'ls | wc', null, undefined, 5, [], 'a\0b']
  const options = [
    null,
    undefined,
    {},
    { trusted: true },
    { trusted: true, trusted_env: true, env: { A: '1' } },
    { trusted: true, trusted_interpolation: true, holes: ['A'] },
    { trusted: true, shell: '', argv0: '' },
    { trusted: true, env: null, holes: null },
    [],
  ]
  const templates = ['', '  ', 'echo', 'echo "$1"', 'echo $X', 'echo | cat', null, 5, 'a\0b', '. /x']
  const args = [[], ['a'], [''], [5], [null], undefined, 'a', {}]
  let thrown = 0
  let ran = 0
  for (const script of scripts) {
    for (const option of options) {
      ran++
      try {
        CS.trustedShell(script, option)
      } catch (e) {
        thrown++
        process.stdout.write(`        threw: trustedShell(${show(script)}, ${show(option)}) -> ${e.message}\n`)
      }
    }
  }
  for (const template of templates) {
    for (const arg of args) {
      ran++
      try {
        CS.templateShell(template, arg)
      } catch (e) {
        thrown++
        process.stdout.write(`        threw: templateShell(${show(template)}, ${show(arg)}) -> ${e.message}\n`)
      }
    }
  }
  for (const command of [[], ['a'], [''], [5], null, undefined, 'a', {}, ['a', 'b']]) {
    ran++
    try {
      CS.argv(command)
    } catch (e) {
      thrown++
      process.stdout.write(`        threw: argv(${show(command)}) -> ${e.message}\n`)
    }
  }
  is('the whole matrix ran', ran, (v) => v === scripts.length * options.length + templates.length * args.length + 9, 'every combination ran')
  eq('nothing threw', thrown, 0)
  noThrow('argv with no arguments', () => CS.argv())
  noThrow('templateShell with no arguments', () => CS.templateShell())
  noThrow('trustedShell with no arguments', () => CS.trustedShell())
  noThrow('isData on a nullish value', () => CS.isData(null))
  noThrow('isObject on a nullish value', () => CS.isObject(null))
  noThrow('normalizeEnv on undefined', () => CS.normalizeEnv(undefined))
  // normalizeEnv is the one helper that is not total: `Object.keys(null)` is a
  // TypeError. It is unreachable through the public builders, because
  // trustedShell runs validEnv first and validEnv refuses null, so this is a
  // property of the internal rather than a hole in the contract - pinned so
  // that stays true if the guard order is ever rearranged.
  throws('normalizeEnv on null throws', () => CS.normalizeEnv(null))
  eq('and validEnv refuses the same value first', CS.validEnv(null), false)
  eq('a trusted env claim on null is refused before normalizeEnv is reached', CS.trustedShell('ls', { trusted: true, trusted_env: true, env: null }).code, 'invalid_env')
  eq('and they all answer a defined refusal', [CS.argv().code, CS.templateShell().code, CS.trustedShell().code], ['invalid_argv', 'invalid_template', 'invalid_script'])
})

finish()
