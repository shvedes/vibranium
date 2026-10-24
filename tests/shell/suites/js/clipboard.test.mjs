#!/usr/bin/env node
// Suite: features/clipboard/ClipboardLib.js - the pure-JS library behind the
// clipboard feature.
//
// It sits on a hot path (a capture derives a row immediately), so the
// properties under test are not "does it produce a value" but:
//
//   * type/format decisions are total - a nullish or hostile input must come
//     back as "" / null / a typed sentinel rather than a throw (the handful
//     that do throw are pinned with `throws`, and named as such);
//   * the argv builders are the reviewable statement of which binaries this
//     feature can run, so their exact arrays are pinned and every payload
//     that reaches a `sh -c` fragment is pinned as landing inside a
//     single-quoted span with the executable skeleton byte-identical;
//   * the secret codec round-trips, and no projection or export can carry a
//     credential into a non-secret surface.
//
// Where a value is surprising the comment cites the source line or comment
// that produces it, and the assertion pins the real value.

import path from 'node:path'
import { loadLib, libSource } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, match, notMatch, contains, notContains,
  throws, noThrow, finish, blocked, SHELL_DIR,
} from '../../lib/assert.mjs'

const CL = loadLib(path.join(SHELL_DIR, 'features/clipboard/ClipboardLib.js'))

// ---------------------------------------------------------------------------
// Local instruments. These are test-side, not part of the assertion kit, so
// they sit above the first section.
// ---------------------------------------------------------------------------

// The marker a collapsed quote span becomes. Two visible characters, because
// a failure message that contains a control character is unreadable.
const SPAN = '@@'

// scan(fragment) walks a `sh -c` body and reports:
//   unquoted - the text with every single-quoted span replaced by SPAN
//   spans    - each fully-quoted word, quotes included
// A payload that only ever appears inside a span cannot change the shell's
// structure, so `unquoted` must be byte-identical for a benign path and for
// an injection-shaped one.
function scan(frag) {
  const spans = []
  let unquoted = ''
  let i = 0
  while (i < frag.length) {
    if (frag.charAt(i) !== "'") { unquoted += frag.charAt(i); i++; continue }
    const start = i
    i++
    unquoted += SPAN
    while (i < frag.length) {
      if (frag.charAt(i) === "'") {
        // sq() emits '\'' for an embedded quote: close, escaped quote,
        // reopen - all four characters belong to the same word.
        if (frag.charAt(i + 1) === '\\' && frag.charAt(i + 2) === "'" && frag.charAt(i + 3) === "'") { i += 4; continue }
        i++
        break
      }
      i++
    }
    spans.push(frag.substring(start, i))
  }
  return { unquoted, spans }
}

// posixUnquote is the inverse of ClipboardLib.sq(): it parses one
// single-quoted word and reports what the shell would receive plus whatever
// text sat OUTSIDE the quotes. A correctly quoted payload has bare === "".
function posixUnquote(word) {
  if (word.charAt(0) !== "'") return { value: null, bare: word, closed: false }
  let value = ''
  let bare = ''
  let i = 1
  let closed = false
  while (i < word.length) {
    const c = word.charAt(i)
    if (c !== "'") { value += c; i++; continue }
    if (word.charAt(i + 1) === '\\' && word.charAt(i + 2) === "'" && word.charAt(i + 3) === "'") { value += "'"; i += 4; continue }
    closed = true
    i++
    for (; i < word.length; i++) bare += word.charAt(i)
    break
  }
  return { value, bare, closed }
}

// body(cmd) is the `sh -c` script of a three-element argv, and is what every
// quoting assertion below is actually about.
const body = (cmd) => (Array.isArray(cmd) && cmd[0] === 'sh' && cmd[1] === '-c' ? cmd[2] : null)
const skeleton = (frag) => scan(frag).unquoted

// The ten hostiles every builder has to survive.
const INJECTIONS = [
  ["a single quote", "/tmp/it's.png"],
  ['a semicolon', '/tmp/a; rm -rf /'],
  ['a $(...) substitution', '/tmp/$(id).png'],
  ['a backtick', '/tmp/`id`.png'],
  ['a newline', '/tmp/a\nrm -rf /'],
  ['a space', '/tmp/a b.png'],
  ['a leading dash', '-rf'],
  ['a double quote', '/tmp/a"b.png'],
  ['a pipe', '/tmp/a|id.png'],
  ['a glob', '/tmp/*.png'],
]

// The same idea for the controller-side argv builders, which never reach a
// shell: there the contract is the `--` end-of-options guard, not quoting.
const OPTION_SHAPED = [
  ['a leading dash', '-rf'],
  ['a dash-dash', '--help'],
  ['a semicolon', '/tmp/a;rm -rf /'],
  ['a quote', "/tmp/it's.png"],
  ['a newline', '/tmp/a\nb'],
  ['a dot-dot', '/tmp/..'],
]

// The one payload used for the blanket "skeleton is fixed" sweep. It carries
// a single quote, a space and a command name at once, so a builder that
// failed to splice the quote would still produce a valid-looking word.
const NASTY = "/tmp/'; id '.mp4"

const HOME = '/home/u'
const TS = Date.UTC(2024, 7, 25, 14, 32, 5)

// A real `mediainfo` dump: section headers at column 0, kv lines as
// "Key<pad> : value" with the key ALSO at column 0, blank lines between
// sections (the parseMediaInfo header comment, verified on v26.05).
const MI_AUDIO = [
  'General',
  'Complete name                            : /home/u/Music/track.flac',
  'Format                                   : FLAC',
  'File size                                : 5.73 MiB',
  'Duration                                 : 2 min 38 s',
  '',
  'Audio',
  'Format                                   : FLAC',
  'Channel(s)                               : 2 channels',
  'Sampling rate                            : 44.1 KHz',
  'Bit depth                                : 16 bits',
].join('\n')

const MI_VIDEO = [
  'General',
  'Complete name                            : /home/u/Vids/clip.mp4',
  'Format                                   : Matroska',
  'Duration                                 : 1 h 2 min',
  '',
  'Video',
  'Format                                   : AVC',
  'Width                                    : 1 920 pixels',
  'Height                                   : 1 080 pixels',
  'Frame rate                               : 23.976 FPS',
  '',
  'Audio',
  'Format                                   : AAC',
  'Channel(s)                               : 6 channels',
].join('\n')

// mk builds the hay/words pair a derived row carries, so searchEntries runs
// against the same surface the service hands it.
const mk = (id, title, subLeft) => {
  const x = { id, title, subLeft: subLeft || '' }
  x.hay = CL.hayFor(x)
  x.words = CL.wordsFor(x.hay)
  return x
}
const ids = (r) => r.map((x) => x.id)

// tableKeys reads one of the library's `const` tables out of the source. The
// loader only surfaces top-level `var`/`function` declarations (a `const` in
// a .pragma library never lands on the context object), so a declared table
// is read from the text - which is the sanctioned way to pin a contract the
// namespace does not export.
const SRC = libSource(path.join(SHELL_DIR, 'features/clipboard/ClipboardLib.js'))
const CLOCK_SRC = libSource(path.join(SHELL_DIR, 'common/text/Clock.js'))
function tableKeys(name) {
  const m = SRC.match(new RegExp('const ' + name + ' = (?:Object\\.assign\\(Object\\.create\\(null\\), )?\\{([^}]*)\\}'))
  if (!m) return null
  return m[1].split(',').map((s) => s.trim().split(':')[0].trim().replace(/^["']|["']$/g, '')).filter((s) => s !== '')
}

suite('clipboard', 'ClipboardLib.js (94 fns)')

if (!CL || typeof CL.detectType !== 'function') {
  blocked('ClipboardLib.js did not load')
}

// ===========================================================================
section('ClipboardLib - type detection')
// ===========================================================================

group('detectType: text', () => {
  eq('plain text', CL.detectType(['text/plain'], 'hello', []), 'text')
  // The mime list is substring-matched, so a charset parameter does not
  // change the verdict.
  eq('text/plain;charset=utf-8', CL.detectType(['text/plain;charset=utf-8'], 'hello', []), 'text')
  eq('text/html', CL.detectType(['text/html'], '<b>x</b>', []), 'text')
  eq('empty content is still text', CL.detectType(['text/plain'], '', []), 'text')
  eq('whitespace-only content is still text', CL.detectType(['text/plain'], '   \n  ', []), 'text')
  // A bare absolute path pasted as text is NOT promoted here - the promotion
  // is textImagePath()'s job, and Clipboard.qml calls that first (line 950)
  // so a pasted image path becomes a real image row.
  eq('a path that looks like a path stays text', CL.detectType(['text/plain'], '/home/u/docs/a.txt', []), 'text')
  eq('a uri-list mime with no paths stays text', CL.detectType(['text/uri-list'], '/tmp/a.png', []), 'text')
  eq('no mimes at all', CL.detectType([], 'hello', []), 'text')
  eq('null mimes and null paths', CL.detectType(null, 'hello', null), 'text')
  eq('undefined everywhere', CL.detectType(undefined, undefined, undefined), 'text')
  // A video mime carries no uri-list and no image prefix, and its payload is
  // not a URL, so the tail of the ladder answers "text" - the type a file
  // copy gets is decided by the uri-list route, not by the video mime.
  eq('a video mime with a non-URL payload', CL.detectType(['video/mp4'], 'x', []), 'text')
  eq('an unknown mime', CL.detectType(['application/octet-stream'], 'zzz', []), 'text')
})

group('detectType: image', () => {
  eq('an embedded image mime wins over text', CL.detectType(['image/png'], '\u0089PNG', []), 'image')
  eq('an image mime beats a uri-list mime', CL.detectType(['image/png', 'text/uri-list'], 'x', ['/a.png']), 'image')
  eq('the mime is matched case-insensitively', CL.detectType(['IMAGE/PNG'], 'x', []), 'image')
  // A single uri-list path with an image extension promotes, so a copied
  // image file and a pasted image snapshot land on the same type.
  eq('a single image path in a uri-list', CL.detectType(['text/uri-list'], '', ['/tmp/a.PNG']), 'image')
  // ... but a mixed multi-selection stays "files": the image branch is only
  // consulted for length === 1.
  eq('an image inside a multi-selection is not promoted', CL.detectType(['text/uri-list'], '', ['/tmp/a.png', '/tmp/b.txt']), 'files')
})

group('detectType: archive, file and files', () => {
  eq('a single archive path', CL.detectType(['text/uri-list'], '', ['/tmp/a.zip']), 'archive')
  eq('a double extension archive', CL.detectType(['text/uri-list'], '', ['/tmp/a.tar.gz']), 'archive')
  // The single-path branch returns "file" with the source comment
  // "folder-vs-file correction arrives with the stat probe"; the correction
  // is projectFileInfo's job.
  eq('a single plain path', CL.detectType(['text/uri-list'], '', ['/tmp/a.txt']), 'file')
  eq('a single path with no extension', CL.detectType(['text/uri-list'], '', ['/tmp/README']), 'file')
  eq('two paths', CL.detectType(['text/uri-list'], '', ['/a.txt', '/b.txt']), 'files')
  eq('three paths', CL.detectType(['text/uri-list'], '', ['/a', '/b', '/c']), 'files')
  eq('an empty path list falls through to the text branch', CL.detectType(['text/uri-list'], '', []), 'text')
})

group('detectType: credential mime beats everything', () => {
  eq('x-kde-pass', CL.detectType(['application/x-kde-passwordastext'], 'x', []), 'secret')
  eq('keepassxc', CL.detectType(['application/x-keepassxc-json'], '{}', []), 'secret')
  eq('a password hint', CL.detectType(['text/plain;x-secret=password'], 'x', []), 'secret')
  eq('credential beats image', CL.detectType(['image/png', 'x-kde-pass'], 'x', []), 'secret')
  eq('credential beats uri-list', CL.detectType(['text/uri-list', 'x-kde-pass'], '/a.txt', ['/a.txt']), 'secret')
  eq('uppercase credential hint', CL.detectType(['APPLICATION/X-KEEPASSXC'], '{}', []), 'secret')
})

group('detectType: network', () => {
  // The uri-list branch owns the single-path case before the network branch
  // runs, so a network uri only reaches "network" when parseUriList dropped
  // it and left no path behind.
  eq('a single smb uri with no surviving path', CL.detectType(['text/uri-list'], 'smb://server/share', []), 'network')
  eq('a single smb uri that DID leave a path is typed file first', CL.detectType(['text/uri-list'], 'smb://server/share', ['/x']), 'file')
  eq('a raw ftp uri as text', CL.detectType(['text/plain'], 'ftp://host/a', []), 'network')
  eq('a list of network uris', CL.detectType(['text/plain'], 'ftp://h/a\nsftp://h/b', []), 'network')
  // The single-URI branch runs isNetworkUri(t) on the WHOLE trimmed string and
  // RE_URI_SCHEME_HOST stops at the first "/", so a multi-line paste whose
  // first line is a network URI is typed "network" even when the later lines
  // are not. The mixed list below therefore reads "network" for the first-line
  // reason, not the all-lines one.
  eq('first line a network uri, rest not', CL.detectType(['text/plain'], 'ftp://h/a\nhttp://h/b', []), 'network')
  // A uri-list mime whose first line is a network URI: parseUriList dropped
  // it, so the fallback on line 0 is what recovers the type.
  eq('a uri-list mime with a network first line', CL.detectType(['text/uri-list'], 'sftp://h/a', []), 'network')
  // Comment lines are excluded from the all-lines count.
  eq('a network list with a comment header', CL.detectType(['text/plain'], '# share\nsftp://h/a', []), 'network')
  // A web URL is not network storage: http/https are absent from
  // NETWORK_SCHEMES, so the url branch owns them.
  eq('https is a url, not network', CL.detectType(['text/plain'], 'https://x.dev/a', []), 'url')
})

group('detectType: url', () => {
  eq('https', CL.detectType(['text/plain'], 'https://x.dev/a', []), 'url')
  eq('http', CL.detectType(['text/plain'], 'http://x.dev', []), 'url')
  eq('www', CL.detectType(['text/plain'], 'www.x.dev', []), 'url')
  eq('uppercase scheme', CL.detectType(['text/plain'], 'HTTPS://X.DEV', []), 'url')
  // isUrl() rejects a string containing a space, so a sentence with a URL in
  // it stays text rather than becoming a link row.
  eq('a url with a space is not a url', CL.detectType(['text/plain'], 'https://x.dev/a b', []), 'text')
  eq('a sentence with a period is not a url', CL.detectType(['text/plain'], 'See the docs.', []), 'text')
  eq('ftp is consumed by the network branch, never by isUrl', CL.detectType(['text/plain'], 'ftp://h/a', []), 'network')
  eq('a bare word is not a url', CL.detectType(['text/plain'], 'x.dev', []), 'text')
  // "http://" clears the length gate and matches the scheme prefix, so a
  // scheme with no host at all is a url - unlike a network uri, which is
  // accepted only because its host group is "*" not "+".
  eq('a scheme with no host is still a url', CL.detectType(['text/plain'], 'http://', []), 'url')
})

group('isCredentialMimeTypes', () => {
  eq('password substring', CL.isCredentialMimeTypes(['application/x-password-store']), true)
  eq('sensitive substring', CL.isCredentialMimeTypes(['X-Sensitive-Thing']), true)
  eq('x-kde-pass substring', CL.isCredentialMimeTypes(['x-kde-pass']), true)
  eq('keepassxc substring', CL.isCredentialMimeTypes(['application/keepassxc']), true)
  eq('the match is case-insensitive', CL.isCredentialMimeTypes(['APPLICATION/X-KEEPASSXC']), true)
  eq('any one entry is enough', CL.isCredentialMimeTypes(['text/plain', 'x-kde-pass', 'image/png']), true)
  eq('plain text is not a credential', CL.isCredentialMimeTypes(['text/plain']), false)
  eq('an image is not a credential', CL.isCredentialMimeTypes(['image/png']), false)
  eq('an empty list', CL.isCredentialMimeTypes([]), false)
  eq('null', CL.isCredentialMimeTypes(null), false)
  eq('undefined', CL.isCredentialMimeTypes(undefined), false)
  eq('a non-string entry is stringified', CL.isCredentialMimeTypes([null]), false)
  eq('"sensitive" as a substring', CL.isCredentialMimeTypes(['text/sensitive-ish']), true)
  eq('"password" as a suffix', CL.isCredentialMimeTypes(['a/b/mypassword']), true)
  eq('secret substring', CL.isCredentialMimeTypes(['application/x-secret']), true)
  eq('credential substring', CL.isCredentialMimeTypes(['application/x-credential']), true)
  eq('keepass substring covers keepassxc', CL.isCredentialMimeTypes(['application/x-keepass']), true)
  eq('1password substring', CL.isCredentialMimeTypes(['com.1password']), true)
  eq('bitwarden substring', CL.isCredentialMimeTypes(['com.bitwarden']), true)
  eq('lastpass substring', CL.isCredentialMimeTypes(['com.lastpass']), true)
  // The needles include password, sensitive, x-kde-pass, keepassxc, secret,
  // credential, keepass, 1password, bitwarden and lastpass, so "pass" alone
  // never trips it. Pinned so a shortened list is a visible diff.
  eq('"pass" alone is not a trigger', CL.isCredentialMimeTypes(['application/x-pass']), false)
})

// ===========================================================================
section('ClipboardLib - extension and scheme predicates')
// ===========================================================================

group('extOf / extIn - one shared membership check', () => {
  eq('lowercases the extension', CL.extOf('/a/b.PNG'), 'png')
  eq('uses the last dot', CL.extOf('a.b.c'), 'c')
  eq('a directory dot does not leak', CL.extOf('/a.dir/x'), '')
  eq('a dotfile is not an extension (dot at index 0)', CL.extOf('.png'), '')
  eq('no dot', CL.extOf('noext'), '')
  eq('a trailing dot yields an empty extension', CL.extOf('a.'), '')
  eq('undefined', CL.extOf(undefined), '')
  // extIn is exported and is the single helper every isX() delegates to.
  eq('extIn hit', CL.extIn('a.mp4', { mp4: true }), true)
  eq('extIn miss', CL.extIn('a.txt', { mp4: true }), false)
  eq('extIn with an empty-string key hits a dotfile', CL.extIn('.png', { '': true }), true)
  eq('extIn is case-insensitive through extOf', CL.extIn('A.MP4', { mp4: true }), true)
})

group('isVideo', () => {
  eq('mp4', CL.isVideo('a.mp4'), true)
  eq('mkv', CL.isVideo('a.MKV'), true)
  eq('webm', CL.isVideo('a.webm'), true)
  eq('mov', CL.isVideo('a.mov'), true)
  eq('avi', CL.isVideo('a.avi'), true)
  eq('m4v', CL.isVideo('a.m4v'), true)
  eq('an audio file is not video', CL.isVideo('a.mp3'), false)
  eq('a dotfile mp4 is not video', CL.isVideo('.mp4'), false)
  eq('no extension', CL.isVideo('movie'), false)
  eq('undefined', CL.isVideo(undefined), false)
})

group('isArchive', () => {
  for (const e of ['zip', 'tar', 'gz', 'tgz', 'bz2', 'xz', '7z', 'rar', 'zst', 'lz', 'lzma']) {
    eq(`${e} is an archive`, CL.isArchive(`a.${e}`), true)
  }
  eq('a plain file is not an archive', CL.isArchive('a.txt'), false)
  eq('a directory-ish name', CL.isArchive('/a/b/'), false)
  eq('undefined', CL.isArchive(undefined), false)
  eq('a dotfile zip is not an archive', CL.isArchive('.zip'), false)
})

group('isImageExt / isImageMime / mimeForExt', () => {
  eq('png', CL.isImageExt('a.png'), true)
  eq('heic', CL.isImageExt('a.HEIC'), true)
  eq('gif', CL.isImageExt('a.gif'), true)
  eq('svg', CL.isImageExt('a.svg'), true)
  eq('ico is not in the table', CL.isImageExt('a.ico'), false)
  eq('pdf is not an image', CL.isImageExt('a.pdf'), false)
  eq('a dotfile is not an extension', CL.isImageExt('.png'), false)
  eq('mimeForExt jpeg', CL.mimeForExt('a.jpeg'), 'image/jpeg')
  eq('mimeForExt tif', CL.mimeForExt('a.tif'), 'image/tiff')
  eq('mimeForExt svg', CL.mimeForExt('a.svg'), 'image/svg+xml')
  eq('mimeForExt heif', CL.mimeForExt('a.heif'), 'image/heif')
  eq('mimeForExt is case-insensitive via extOf', CL.mimeForExt('a.PNG'), 'image/png')
  // "Anything unknown falls back to image/png" - the table's own comment.
  eq('unknown extension falls back', CL.mimeForExt('a.exe'), 'image/png')
  eq('no extension falls back', CL.mimeForExt('/tmp/x/y/'), 'image/png')
  eq('isImageMime prefix match', CL.isImageMime('image/png'), true)
  eq('isImageMime is case-insensitive', CL.isImageMime('IMAGE/PNG'), true)
  eq('a text mime that merely contains image', CL.isImageMime('text/x-png'), false)
  eq('a non-mime', CL.isImageMime(undefined), false)
  eq('isImageExt(undefined)', CL.isImageExt(undefined), false)
})

group('isNetworkScheme / isNetworkUri', () => {
  for (const s of ['ftp', 'ftps', 'sftp', 'smb', 'cifs', 'nfs', 'ssh', 'scp', 'rsync', 'webdav', 'dav', 'davs', 'afp', 's3', 'nmb']) {
    eq(`${s} is a network scheme`, CL.isNetworkScheme(s), true)
    eq(`${s}://h/x is a network uri`, CL.isNetworkUri(`${s}://h/x`), true)
  }
  eq('http is not a network scheme', CL.isNetworkScheme('http'), false)
  eq('https is not a network scheme', CL.isNetworkScheme('https'), false)
  eq('file is not a network scheme', CL.isNetworkScheme('file'), false)
  eq('the scheme lookup lowercases', CL.isNetworkScheme('SMB'), true)
  eq('undefined is not a scheme', CL.isNetworkScheme(undefined), false)
  eq('the uri matcher is case-insensitive', CL.isNetworkUri('SMB://h/x'), true)
  eq('surrounding whitespace is trimmed', CL.isNetworkUri('  smb://h/x  '), true)
  // The host group is "*" not "+", which the RE_URI_SCHEME_HOST comment calls
  // out: a bare "proto://" with nothing after it still counts as network.
  eq('a bare scheme with no host still counts', CL.isNetworkUri('smb://'), true)
  eq('a bare scheme with no host, another scheme', CL.isNetworkUri('sftp://'), true)
  eq('http:// is not network', CL.isNetworkUri('http://x'), false)
  eq('a path is not a uri', CL.isNetworkUri('/tmp/a'), false)
  eq('userinfo and port are inside the host group', CL.isNetworkUri('smb://user:pw@h:445/x'), true)
  eq('a query-only remainder is still a host', CL.isNetworkUri('nfs://h?x'), true)
  eq('a fragment-only remainder is still a host', CL.isNetworkUri('nfs://h#x'), true)
  eq('undefined', CL.isNetworkUri(undefined), false)
})

group('extIconName - the basename every file row uses', () => {
  eq('svg beats the image branch (checked first)', CL.extIconName('a.svg'), 'file-svg')
  eq('png', CL.extIconName('a.png'), 'file-image')
  eq('zip', CL.extIconName('a.zip'), 'file-archive')
  eq('pdf', CL.extIconName('a.pdf'), 'file-pdf')
  eq('xlsx', CL.extIconName('a.xlsx'), 'file-xls')
  eq('csv', CL.extIconName('a.csv'), 'file-xls')
  eq('sqlite3', CL.extIconName('a.sqlite3'), 'file-db')
  eq('patch', CL.extIconName('a.patch'), 'file-diff')
  eq('rej', CL.extIconName('a.rej'), 'file-diff')
  eq('woff2', CL.extIconName('a.woff2'), 'file-font')
  eq('mp3', CL.extIconName('a.mp3'), 'file-music')
  // Video deliberately maps to the generic "file" icon, not a media icon.
  eq('mp4 is the generic file icon', CL.extIconName('a.mp4'), 'file')
  eq('mkv is the generic file icon', CL.extIconName('a.mkv'), 'file')
  eq('ts is code', CL.extIconName('a.ts'), 'file-code')
  eq('rs is code', CL.extIconName('a.rs'), 'file-code')
  eq('json is code', CL.extIconName('a.json'), 'file-code')
  eq('an unknown extension has no icon', CL.extIconName('a.bin'), '')
  eq('a dotfile is not an extension here', CL.extIconName('.ts'), '')
  eq('no extension', CL.extIconName('noext'), '')
  eq('an empty string', CL.extIconName(''), '')
  eq('undefined', CL.extIconName(undefined), '')
})

group('iconForType', () => {
  eq('text', CL.iconForType('text'), 'text')
  eq('url maps to the link basename', CL.iconForType('url'), 'link')
  eq('network', CL.iconForType('network'), 'file-network')
  eq('secret maps to the lock', CL.iconForType('secret'), 'lock')
  eq('image', CL.iconForType('image'), 'file-image')
  eq('math', CL.iconForType('math'), 'math')
  eq('calculator', CL.iconForType('calculator'), 'calculator')
  eq('archive', CL.iconForType('archive'), 'file-archive')
  eq('an unknown type falls back to text', CL.iconForType('nope'), 'text')
  eq('undefined falls back to text', CL.iconForType(undefined), 'text')
  eq('the type is stringified', CL.iconForType(7), 'text')
})

group('isTextMime - the binary/zip reject list for the text probe', () => {
  eq('text/plain', CL.isTextMime('text/plain'), true)
  eq('a charset parameter is fine', CL.isTextMime('text/plain; charset=utf-8'), true)
  // application/octet-stream is NOT in the list, so it reads as text; the
  // probe's own "binary" marker is what rejects a real binary.
  eq('octet-stream is not rejected by mime', CL.isTextMime('application/octet-stream'), true)
  eq('charset=binary', CL.isTextMime('text/plain; charset=binary'), false)
  eq('x-executable', CL.isTextMime('application/x-executable'), false)
  eq('x-sharedlib', CL.isTextMime('application/x-sharedlib'), false)
  eq('zip', CL.isTextMime('application/zip'), false)
  eq('gzip', CL.isTextMime('application/gzip'), false)
  eq('7z', CL.isTextMime('application/x-7z'), false)
  eq('rar', CL.isTextMime('application/x-rar'), false)
  eq('zstd', CL.isTextMime('application/zstd'), false)
  eq('pdf', CL.isTextMime('application/pdf'), false)
  eq('any vnd. type', CL.isTextMime('application/vnd.ms-excel'), false)
  eq('image/png is not rejected by mime', CL.isTextMime('image/png'), true)
  eq('the match lowercases', CL.isTextMime('APPLICATION/X-EXECUTABLE'), false)
  eq('a suffix match is enough', CL.isTextMime('x-foo/application/zip-bar'), false)
})

// ===========================================================================
section('ClipboardLib - text classification (math, url, image path)')
// ===========================================================================

group('mathTextKind', () => {
  eq('a bare integer', CL.mathTextKind('42'), 'number')
  eq('a negative decimal', CL.mathTextKind('-3.14'), 'number')
  eq('a leading-plus decimal', CL.mathTextKind('+.5'), 'number')
  eq('scientific notation', CL.mathTextKind('1e6'), 'number')
  eq('a trailing decimal point', CL.mathTextKind('5.'), 'number')
  eq('an arithmetic expression', CL.mathTextKind('2+2'), 'expr')
  eq('a parenthesised expression', CL.mathTextKind('(1+2)*3'), 'expr')
  eq('a single function of x', CL.mathTextKind('x^2'), 'func')
  eq('the y = form', CL.mathTextKind('y = sin(x)'), 'func')
  // "A lone variable ('x') is valid math but not a curve worth a viewport -
  // it stays text" (the header comment).
  eq('a lone variable is not a curve', CL.mathTextKind('x'), '')
  eq('the y = x form is still bare', CL.mathTextKind('y=x'), '')
  eq('tan is a real curve', CL.mathTextKind('tan(x)'), 'func')
  // x/0 compiles but yields non-finite values at every probe, so FuncLib's
  // finite < 3 gate rejects it.
  eq('a domain-hostile body is not a curve', CL.mathTextKind('x/0'), '')
  eq('empty', CL.mathTextKind(''), '')
  eq('whitespace only', CL.mathTextKind('   '), '')
  eq('undefined', CL.mathTextKind(undefined), '')
  // "Single-line only: multi-line pastes stay text".
  eq('a newline stays text', CL.mathTextKind('1+1\n2'), '')
  eq('a carriage return stays text', CL.mathTextKind('1+1\r2'), '')
  // "over-long input is rejected before the evaluators ever see it"
  eq('257 characters is rejected', CL.mathTextKind('x'.repeat(257)), '')
  eq('a 300-character expression is rejected', CL.mathTextKind('1+'.repeat(150)), '')
  eq('a 254-character word is not math at all', CL.mathTextKind('y'.repeat(254)), '')
  eq('an ordinary sentence', CL.mathTextKind('hello world'), '')
  eq('a word with a digit', CL.mathTextKind('v1.2 release'), '')
  eq('a currency amount is not math', CL.mathTextKind('$42'), '')
})

group('funcBodyFor - the body the static preview graph binds to', () => {
  eq('x^2', CL.funcBodyFor('x^2'), 'x^2')
  eq('the y = prefix is stripped', CL.funcBodyFor('y = sin(x)'), 'sin(x)')
  eq('the plot prefix is stripped', CL.funcBodyFor('plot x^2'), 'x^2')
  eq('the graph prefix is stripped', CL.funcBodyFor('graph x^2'), 'x^2')
  eq('f(x)= is stripped', CL.funcBodyFor('f(x)=x^2'), 'x^2')
  eq('y(x)= is stripped', CL.funcBodyFor('y(x)=x^2'), 'x^2')
  eq('a trailing = is stripped', CL.funcBodyFor('x^2='), 'x^2')
  eq('a bare variable has no body', CL.funcBodyFor('x'), '')
  eq('a parenthesised bare variable has no body', CL.funcBodyFor('(x)'), '')
  eq('a negated bare variable has no body', CL.funcBodyFor('-x'), '')
  eq('an expression with no variable', CL.funcBodyFor('2+2'), '')
  eq('an unknown word', CL.funcBodyFor('x chat'), '')
  eq('empty', CL.funcBodyFor(''), '')
  eq('undefined', CL.funcBodyFor(undefined), '')
  // mathTextKind and funcBodyFor must agree about what is a curve.
  eq('agrees with mathTextKind on x^2', [CL.mathTextKind('x^2'), CL.funcBodyFor('x^2')], ['func', 'x^2'])
  eq('agrees on a bare variable', [CL.mathTextKind('x'), CL.funcBodyFor('x')], ['', ''])
  eq('agrees on an expression', [CL.mathTextKind('2+2'), CL.funcBodyFor('2+2')], ['expr', ''])
})

group('textImagePath - a pasted path that is really an image file', () => {
  eq('an absolute png', CL.textImagePath('/a/b.png', HOME), '/a/b.png')
  eq('surrounding whitespace is trimmed first', CL.textImagePath('  /a/b.png  ', HOME), '/a/b.png')
  eq('a ~ path resolves against the injected home', CL.textImagePath('~/pics/a.jpg', HOME), HOME + '/pics/a.jpg')
  // "if (!home || home === \"\") return \"\"" - a ~ path with no home is not
  // resolvable, so it is refused rather than guessed at.
  eq('a ~ path with no home is refused', CL.textImagePath('~/pics/a.jpg', ''), '')
  eq('a ~ path with an undefined home is refused', CL.textImagePath('~/pics/a.jpg', undefined), '')
  eq('a file:// uri is decoded to a path', CL.textImagePath('file:///a/b.webp', HOME), '/a/b.webp')
  // "Rejects whitespace/newlines and everything without an image extension".
  eq('a space rejects the whole string', CL.textImagePath('/a/b .png', HOME), '')
  eq('a tab rejects the whole string', CL.textImagePath('/a/b\t.png', HOME), '')
  eq('a newline rejects the whole string', CL.textImagePath('/a/b\n.png', HOME), '')
  eq('a non-image extension', CL.textImagePath('/a/b.txt', HOME), '')
  eq('a bogus extension', CL.textImagePath('/a/b.pngx', HOME), '')
  eq('a bare filename is not absolute', CL.textImagePath('x.png', HOME), '')
  // "if (t.length < 6 || t.length > 4096) return \"\"" - a five-character name
  // is refused on length before the extension is even looked at.
  eq('a five-character name is below the length floor', CL.textImagePath('a.bmp', HOME), '')
  eq('exactly six characters is allowed', CL.textImagePath('/a.png', HOME), '/a.png')
  eq('undefined', CL.textImagePath(undefined, HOME), '')
  eq('a 4096-character path is allowed', CL.textImagePath('/' + 'a'.repeat(4091) + '.png', HOME).length, 4096)
  eq('a 4097-character path is refused', CL.textImagePath('/' + 'a'.repeat(4092) + '.png', HOME), '')
  // A file:// uri whose percent-decoding fails is dropped, because the
  // decoded form is re-checked for an image extension after parseUriList.
  eq('a file:// uri that decodes to a non-image is refused', CL.textImagePath('file:///a/b.txt', HOME), '')
})

group('isUrl - the last rung of the type ladder', () => {
  eq('https', CL.isUrl('https://a'), true)
  eq('http', CL.isUrl('http://a'), true)
  eq('the match is case-insensitive', CL.isUrl('HTTPS://A'), true)
  eq('www', CL.isUrl('www.a.b'), true)
  eq('a URL with a path', CL.isUrl('https://x.dev/a/b?q=1#f'), true)
  // "if (t.length < 4) return false" - three characters cannot carry a scheme.
  eq('three characters is too short', CL.isUrl('htt'), false)
  eq('exactly four is allowed', CL.isUrl('ahtt'), false)
  // "if (isNetworkUri(t)) return false" - ftp and every other share scheme
  // was already claimed by the network branch above, so isUrl never sees one.
  eq('ftp is not a url here', CL.isUrl('ftp://h/a'), false)
  eq('smb is not a url here', CL.isUrl('smb://h/a'), false)
  eq('sftp is not a url here', CL.isUrl('sftp://h/a'), false)
  // "&& t.indexOf(\" \") < 0" - a sentence with a link in it stays text.
  eq('a URL with a space is not a url', CL.isUrl('https://x.dev/a b'), false)
  // The guard is a literal space, not a whitespace class, so a pasted
  // multi-line "https://..." block still reads as one url.
  eq('a URL with a newline is still a url', CL.isUrl('https://x.dev/a\nb'), true)
  eq('a tab is allowed, only a space is checked', CL.isUrl('https://x.dev/a\tb'), true)
  eq('a bare domain', CL.isUrl('x.dev'), false)
  eq('a file uri is not a url', CL.isUrl('file:///a'), false)
  // A scheme prefix with nothing after it still clears every gate, because
  // the regex only requires "https://" or "www." and never a host.
  eq('a scheme with no host is a url', CL.isUrl('http://'), true)
  eq('www with nothing after it is a url', CL.isUrl('www.'), true)
  eq('surrounding whitespace is trimmed', CL.isUrl('  https://a  '), true)
  eq('an empty string', CL.isUrl(''), false)
  eq('whitespace only', CL.isUrl('   '), false)
  eq('undefined stringifies to a four-letter word', CL.isUrl(undefined), false)
  eq('a bare ftp scheme is not a url', CL.isUrl('ftp://'), false)
  eq('a url with a leading dash is not a url', CL.isUrl('-https://a'), false)
})

// ===========================================================================
section('ClipboardLib - the argv builders (payload-free copy commands)')
// ===========================================================================

group('the payload-carrying copy commands take no value at all', () => {
  // The README: "No builder in ClipboardLib.js accepts a value parameter - the
  // structural reason a credential cannot be handed to one even by mistake."
  // Arity is the mechanical form of that claim for the stdin jobs.
  eq('buildCopyTextCmd arity 0', CL.buildCopyTextCmd.length, 0)
  eq('buildCopySecretCmd arity 0', CL.buildCopySecretCmd.length, 0)
  eq('buildCopyUriListCmd arity 0', CL.buildCopyUriListCmd.length, 0)
  eq('buildClearCmd arity 0', CL.buildClearCmd.length, 0)
  eq('buildWatchCmd arity 0', CL.buildWatchCmd.length, 0)
  eq('buildOrphanReapCmd arity 0', CL.buildOrphanReapCmd.length, 0)
  eq('buildListTypesCmd arity 0', CL.buildListTypesCmd.length, 0)
  eq('buildPasteTextCmd arity 0', CL.buildPasteTextCmd.length, 0)
  eq('buildPasteUriListCmd arity 0', CL.buildPasteUriListCmd.length, 0)
  eq('buildCopyTextCmd argv', CL.buildCopyTextCmd(), ['wl-copy', '-n'])
  eq('buildCopySecretCmd argv', CL.buildCopySecretCmd(), ['wl-copy', '-n', '--sensitive', '--type', 'text/plain'])
  eq('buildCopyUriListCmd argv', CL.buildCopyUriListCmd(), ['wl-copy', '-n', '--type', 'text/uri-list'])
  eq('buildClearCmd argv', CL.buildClearCmd(), ['wl-copy', '--clear'])
  eq('buildListTypesCmd argv', CL.buildListTypesCmd(), ['wl-paste', '--list-types'])
  eq('buildPasteTextCmd argv', CL.buildPasteTextCmd(), ['wl-paste', '--no-newline'])
  eq('buildPasteUriListCmd argv', CL.buildPasteUriListCmd(), ['wl-paste', '--no-newline', '--type', 'text/uri-list'])
  // The credential copy is the one that matters: a direct exec with no shell
  // anywhere in the argv, and marked sensitive.
  is('the secret copy has no sh element', CL.buildCopySecretCmd(), (a) => a.indexOf('sh') === -1, 'no "sh" in argv')
  is('the secret copy is five elements', CL.buildCopySecretCmd(), (a) => a.length === 5, 'exactly 5 argv elements')
  // The only slash in the whole argv is the one inside the mime type, so
  // there is no path and no payload in it.
  eq('the only slash is inside the mime', CL.buildCopySecretCmd().join(' ').split('/').length - 1, 1)
  eq('the secret copy type is text/plain', CL.buildCopySecretCmd()[4], 'text/plain')
  // -n is "do not serve the previous selection", which is what makes a
  // re-copy a real write rather than a re-offer of the old one.
  eq('every copy command passes -n', CL.buildCopyTextCmd().indexOf('-n') >= 0, true)
  eq('the clear command does not pass -n', CL.buildClearCmd().indexOf('-n'), -1)
})

group('buildWatchCmd - the change-event watcher', () => {
  eq('exact argv', CL.buildWatchCmd(), ['wl-paste', '--watch', 'sh', '-c', 'printf "__vc__\\n"'])
  // "Direct exec (no sh wrapper): the Process child IS wl-paste, so shell
  // teardown kills the watcher instead of orphaning it" - the sh appears as
  // the *argument* to --watch, not as the program, so body() is null here.
  eq('wl-paste is the program', CL.buildWatchCmd()[0], 'wl-paste')
  eq('--watch comes before the inner sh', CL.buildWatchCmd()[1], '--watch')
  eq('the protocol marker is one line', CL.buildWatchCmd()[4], 'printf "__vc__\\n"')
  eq('there is no leading sh', body(CL.buildWatchCmd()), null)
  // Nothing user-supplied is in this argv, so the fragment is fixed: it has
  // no single-quoted span at all, hence no placeholder in its skeleton.
  eq('the fragment has no quoted span', scan(CL.buildWatchCmd()[4]).spans, [])
  eq('the fragment is not a data channel', skeleton(CL.buildWatchCmd()[4]), 'printf "__vc__\\n"')
  eq('calling it twice is stable', CL.buildWatchCmd(), CL.buildWatchCmd())
  eq('one __vc__ per clipboard write', (CL.buildWatchCmd()[4].match(/__vc__/g) || []).length, 1)
})

group('buildOrphanReapCmd - matches only our own watcher', () => {
  eq('exact argv', CL.buildOrphanReapCmd(), ['sh', '-c', "pkill -f 'wl-paste --watch.*__vc__' 2>/dev/null || true; exit 0"])
  eq('the pattern is quoted, so no glob reaches pkill', skeleton(body(CL.buildOrphanReapCmd())), `pkill -f ${SPAN} 2>/dev/null || true; exit 0`)
  contains('the pattern is anchored on our marker', body(CL.buildOrphanReapCmd()), '__vc__')
  // "never a generic wl-paste" - the pattern requires the marker.
  notContains('no bare pkill of wl-paste', body(CL.buildOrphanReapCmd()), 'pkill wl-paste')
  contains('the reap cannot fail the caller', body(CL.buildOrphanReapCmd()), '|| true')
  eq('it always exits 0', body(CL.buildOrphanReapCmd()).endsWith('exit 0'), true)
  eq('the quoted pattern is a single span', scan(body(CL.buildOrphanReapCmd())).spans.length, 1)
  eq('and it unquotes back to the pkill pattern', posixUnquote(scan(body(CL.buildOrphanReapCmd())).spans[0]).value, 'wl-paste --watch.*__vc__')
})

group('buildCopyUrisCmd / buildCopyImageFileCmd / buildCopyImageDataCmd', () => {
  eq('a benign uri', CL.buildCopyUrisCmd('file:///tmp/a.png'), ['sh', '-c', "printf %s 'file:///tmp/a.png' | wl-copy -n --type text/uri-list"])
  eq('the skeleton is fixed regardless of the uri', skeleton(body(CL.buildCopyUrisCmd('file:///tmp/a.png'))), `printf %s ${SPAN} | wl-copy -n --type text/uri-list`)
  // The uri is a path, never credential material, and it is percent-encoded
  // first by toFileUri, so a space never reaches the shell unencoded.
  eq('a space is percent-encoded before quoting', body(CL.buildCopyUrisCmd(CL.toFileUri('/tmp/my pic.png'))), "printf %s 'file:///tmp/my%20pic.png' | wl-copy -n --type text/uri-list")
  eq('an image file is copied through the same fragment', CL.buildCopyImageFileCmd('/tmp/a.png'), CL.buildCopyUrisCmd('file:///tmp/a.png'))
  // The mime argument of buildCopyImageDataCmd is accepted and ignored: the
  // bytes already live in a snapshot file, so only a file:// URI is offered.
  eq('buildCopyImageDataCmd ignores its mime', CL.buildCopyImageDataCmd('image/png', '/tmp/a.png'), CL.buildCopyImageFileCmd('/tmp/a.png'))
  eq('buildCopyImageDataCmd with a different mime is identical', CL.buildCopyImageDataCmd('image/webp', '/tmp/a.png'), CL.buildCopyImageDataCmd('image/png', '/tmp/a.png'))
  for (const [label, p] of INJECTIONS) {
    const frag = body(CL.buildCopyImageFileCmd(p))
    notContains(`${label} never escapes the quotes`, skeleton(frag), p.replace(/\n/g, ''))
    eq(`${label} leaves the skeleton untouched`, skeleton(frag), `printf %s ${SPAN} | wl-copy -n --type text/uri-list`)
  }
  // encodeURIComponent leaves "'" alone, so the quote reaches sq() and is
  // spliced - close the word, escaped quote, reopen it.
  eq('an embedded quote is spliced, not dropped', body(CL.buildCopyImageFileCmd("/tmp/it's.png")), "printf %s 'file:///tmp/it'\\''s.png' | wl-copy -n --type text/uri-list")
  eq('the spliced word unquotes back to the uri', posixUnquote(scan(body(CL.buildCopyImageFileCmd("/tmp/it's.png"))).spans[0]).value, "file:///tmp/it's.png")
  eq('nothing is left outside the quotes', posixUnquote(scan(body(CL.buildCopyImageFileCmd("/tmp/it's.png"))).spans[0]).bare, '')
})

group('buildMkdirCmd / buildEnsurePrivateDirsCmd - the directory gate', () => {
  eq('mkdir argv', CL.buildMkdirCmd('/c/clip', '/c/clip/img'), ['mkdir', '-p', '--', '/c/clip', '/c/clip/img'])
  eq('install argv', CL.buildEnsurePrivateDirsCmd('/c/clip', '/c/clip/img'), ['install', '-d', '-m', '0700', '--', '/c/clip', '/c/clip/img'])
  // The mode is the whole point: a private directory must not be
  // world-readable, and 0700 is what install -d applies AT CREATE TIME
  // rather than in a later chmod that would leave a wider-mode window.
  eq('the private mode is 0700', CL.buildEnsurePrivateDirsCmd('/a', '/b').indexOf('0700') >= 0, true)
  is('the mode is never 0755', CL.buildEnsurePrivateDirsCmd('/a', '/b'), (a) => a.indexOf('0755') === -1, 'no 0755 anywhere')
  is('the mode is never 0777', CL.buildEnsurePrivateDirsCmd('/a', '/b'), (a) => a.indexOf('0777') === -1, 'no 0777 anywhere')
  is('the mode is not even 0700-or-wider', CL.buildEnsurePrivateDirsCmd('/a', '/b'), (a) => !/0[0-7][0-7][0-7]/.test(a.join(' ').replace('0700', '')), 'no other octal mode')
  eq('-m comes before the -- guard', CL.buildEnsurePrivateDirsCmd('/a', '/b').indexOf('-m') < CL.buildEnsurePrivateDirsCmd('/a', '/b').indexOf('--'), true)
  eq('both directories are created in one call', CL.buildEnsurePrivateDirsCmd('/a', '/b').length, 7)
  eq('the args are stringified', CL.buildEnsurePrivateDirsCmd(1, 2), ['install', '-d', '-m', '0700', '--', '1', '2'])
  eq('mkdir is idempotent by flag', CL.buildMkdirCmd('/a', '/b')[1], '-p')
  eq('neither builder runs a shell', [CL.buildMkdirCmd('/a', '/b')[0], CL.buildEnsurePrivateDirsCmd('/a', '/b')[0]], ['mkdir', 'install'])
  // These go through exec, not a shell, so quoting is irrelevant - the `--`
  // guard is what stops an option-shaped directory being read as a flag.
  for (const [label, p] of OPTION_SHAPED) {
    eq(`mkdir keeps -- in front of ${label}`, CL.buildMkdirCmd(p, p).indexOf('--') < CL.buildMkdirCmd(p, p).lastIndexOf(p), true)
    eq(`install keeps -- in front of ${label}`, CL.buildEnsurePrivateDirsCmd(p, p).indexOf('--') < CL.buildEnsurePrivateDirsCmd(p, p).lastIndexOf(p), true)
  }
})

group('buildHistoryModeCmd / buildRmPathCmd / buildRmPathsCmd', () => {
  eq('history mode argv', CL.buildHistoryModeCmd('/c/clip/history'), ['chmod', '0600', '--', '/c/clip/history'])
  // "the history must never exist at a wider mode, not even for the first
  // payload" (README) - 0600 is the widest this can ever be.
  eq('the history mode is 0600', CL.buildHistoryModeCmd('/c/clip/history')[1], '0600')
  is('never 0644', CL.buildHistoryModeCmd('/x'), (a) => a.indexOf('0644') === -1, 'no 0644')
  is('never 0666', CL.buildHistoryModeCmd('/x'), (a) => a.indexOf('0666') === -1, 'no 0666')
  eq('rm one path', CL.buildRmPathCmd('/c/clip/history'), ['rm', '-f', '--', '/c/clip/history'])
  eq('rm many paths', CL.buildRmPathsCmd(['/a b', '/c']), ['rm', '-f', '--', '/a b', '/c'])
  eq('rm an empty list is a bare rm', CL.buildRmPathsCmd([]), ['rm', '-f', '--'])
  eq('rm a null list is a bare rm', CL.buildRmPathsCmd(null), ['rm', '-f', '--'])
  eq('rm an undefined list is a bare rm', CL.buildRmPathsCmd(undefined), ['rm', '-f', '--'])
  eq('rm one path in a list matches buildRmPathCmd', CL.buildRmPathsCmd(['/x']), CL.buildRmPathCmd('/x'))
  eq('the list entries are stringified', CL.buildRmPathsCmd([1, null, undefined]), ['rm', '-f', '--', '1', 'null', 'undefined'])
  eq('the list order is preserved', CL.buildRmPathsCmd(['/b', '/a']), ['rm', '-f', '--', '/b', '/a'])
  for (const [label, p] of OPTION_SHAPED) {
    eq(`rm -f keeps -- in front of ${label}`, CL.buildRmPathCmd(p), ['rm', '-f', '--', p])
    eq(`chmod keeps -- in front of ${label}`, CL.buildHistoryModeCmd(p), ['chmod', '0600', '--', p])
    eq(`rm -- keeps -- in front of ${label}`, CL.buildRmPathsCmd([p]), ['rm', '-f', '--', p])
  }
  // An injection-shaped path reaches argv verbatim, which is safe BECAUSE
  // there is no shell. Pinned so a future refactor to a shell fragment is a
  // visible diff against this expectation.
  eq('a semicolon in a path is inert in argv', CL.buildRmPathCmd('/tmp/a;rm -rf /'), ['rm', '-f', '--', '/tmp/a;rm -rf /'])
  eq('a newline in a path is inert in argv', CL.buildRmPathCmd('/tmp/a\nb'), ['rm', '-f', '--', '/tmp/a\nb'])
  eq('a quote in a path is inert in argv', CL.buildRmPathCmd("/tmp/it's"), ['rm', '-f', '--', "/tmp/it's"])
  eq('a $(...) in a path is inert in argv', CL.buildRmPathCmd('/tmp/$(id)'), ['rm', '-f', '--', '/tmp/$(id)'])
  // The blanket form: none of these four can emit a shell, ever.
  for (const p of ['/a', '/a; id', '-rf', '/a\nb', '']) {
    is(`rm never invokes a shell for ${JSON.stringify(p)}`, CL.buildRmPathCmd(p), (a) => a[0] === 'rm' && a.indexOf('sh') === -1 && a.length === 4, 'rm -f -- <one path>')
    is(`chmod never invokes a shell for ${JSON.stringify(p)}`, CL.buildHistoryModeCmd(p), (a) => a[0] === 'chmod' && a.indexOf('sh') === -1, 'chmod, no sh')
    is(`rm -- never invokes a shell for ${JSON.stringify(p)}`, CL.buildRmPathsCmd([p]), (a) => a[0] === 'rm' && a.indexOf('sh') === -1, 'rm, no sh')
  }
  // The whole surface, checked at once: the only programs these four can run.
  eq('the controller-side programs are exactly rm and chmod', new Set([CL.buildRmPathCmd('/a')[0], CL.buildRmPathsCmd(['/a'])[0], CL.buildHistoryModeCmd('/a')[0]]), new Set(['rm', 'chmod']))
})

// ===========================================================================
section('ClipboardLib - the sh -c fragment builders')
// ===========================================================================

group('sq - the local stand-in for StringUtils.shellQuote', () => {
  eq('a plain word', CL.sq('abc'), "'abc'")
  eq('an empty string', CL.sq(''), "''")
  eq('a word with spaces', CL.sq('a b'), "'a b'")
  eq('an embedded quote is closed and reopened', CL.sq("it's"), "'it'\\''s'")
  eq('a leading quote', CL.sq("'x"), "''\\''x'")
  eq('a trailing quote', CL.sq("x'"), "'x'\\'''")
  eq('a lone quote', CL.sq("'"), "''\\'''")
  eq('two quotes each get their own splice', CL.sq("''"), "''\\'''\\'''")
  eq('a dollar is inert inside the quotes', CL.sq('$HOME'), "'$HOME'")
  eq('a backtick is inert inside the quotes', CL.sq('`id`'), "'`id`'")
  eq('a semicolon is inert inside the quotes', CL.sq('a;b'), "'a;b'")
  eq('a newline stays inside the one word', CL.sq('a\nb'), "'a\nb'")
  eq('a backslash is not an escape character here', CL.sq('a\\b'), "'a\\b'")
  eq('undefined stringifies', CL.sq(undefined), "'undefined'")
  eq('a newline does not add a span', scan(CL.sq('a\nb')).spans.length, 1)
  // The mechanical property: unquoting sq() gives the payload back, with
  // nothing left outside the quotes.
  for (const [label, p] of INJECTIONS) {
    const u = posixUnquote(CL.sq(p))
    eq(`sq round-trips ${label}`, u.value, p)
    eq(`sq leaves nothing bare for ${label}`, u.bare, '')
    eq(`sq closes the word for ${label}`, u.closed, true)
  }
})

group('buildImageSnapshotCmd', () => {
  const frag = body(CL.buildImageSnapshotCmd('image/png', '/c/clip/img/t1-0.png'))
  eq('exact fragment', frag, 'p=\'/c/clip/img/t1-0.png\'; if wl-paste --type \'image/png\' > "$p" 2>/dev/null; then chmod 0600 -- "$p" 2>/dev/null; stat -c %s "$p" 2>/dev/null; sha1sum "$p" 2>/dev/null; else rm -f -- "$p"; echo EMPTY; fi')
  eq('the path is a quoted assignment, not an interpolation', frag.startsWith("p='"), true)
  // The empty-clipboard branch removes the file it may have created, so a
  // failed snapshot leaves nothing for the GC to trip over.
  contains('the failure branch unlinks', frag, 'rm -f -- "$p"')
  contains('the failure branch is announced', frag, 'echo EMPTY')
  contains('the size is emitted before the digest', frag.indexOf('stat -c %s') < frag.indexOf('sha1sum'), true)
  contains('the snapshot is private at write', frag, 'chmod 0600 -- "$p"')
  contains('the mode is asserted before sizing', frag.indexOf('chmod 0600') < frag.indexOf('stat -c %s'), true)
  eq('the skeleton is fixed', skeleton(frag), `p=${SPAN}; if wl-paste --type ${SPAN} > "$p" 2>/dev/null; then chmod 0600 -- "$p" 2>/dev/null; stat -c %s "$p" 2>/dev/null; sha1sum "$p" 2>/dev/null; else rm -f -- "$p"; echo EMPTY; fi`)
  eq('exactly two quoted slots', scan(frag).spans.length, 2)
  eq('the path slot unquotes to the path', posixUnquote(scan(frag).spans[0]).value, '/c/clip/img/t1-0.png')
  eq('the mime slot unquotes to the mime', posixUnquote(scan(frag).spans[1]).value, 'image/png')
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildImageSnapshotCmd('image/png', p))
    eq(`the path skeleton survives ${label}`, skeleton(f2), skeleton(frag))
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
    eq(`the path slot still unquotes to the path for ${label}`, posixUnquote(scan(f2).spans[0]).value, p)
  }
  for (const [label, m] of INJECTIONS) {
    const f3 = body(CL.buildImageSnapshotCmd(m, '/c/a.png'))
    eq(`the mime skeleton survives ${label}`, skeleton(f3), skeleton(frag))
    eq(`the mime slot still unquotes to the mime for ${label}`, posixUnquote(scan(f3).spans[1]).value, m)
  }
  eq('a mime with a quote is spliced', body(CL.buildImageSnapshotCmd("image/png'; rm -rf /", '/c/a.png')), "p='/c/a.png'; if wl-paste --type 'image/png'\\''; rm -rf /' > \"$p\" 2>/dev/null; then chmod 0600 -- \"$p\" 2>/dev/null; stat -c %s \"$p\" 2>/dev/null; sha1sum \"$p\" 2>/dev/null; else rm -f -- \"$p\"; echo EMPTY; fi")
})

group('buildDimCmd - identify with the first frame only', () => {
  const frag = body(CL.buildDimCmd('/c/a.png'))
  eq('exact fragment', frag, "identify -format '%w %h\\n' '/c/a.png[0]' 2>/dev/null || true")
  // "[0] for first frame (GIFs) and no head pipe - format already single line"
  contains('the [0] frame selector is inside the quoted path', frag, "'/c/a.png[0]'")
  eq('no head pipe', frag.indexOf('| head'), -1)
  contains('a failed identify cannot fail the caller', frag, '|| true')
  eq('the skeleton is fixed', skeleton(frag), `identify -format ${SPAN} ${SPAN} 2>/dev/null || true`)
  eq('the format string is its own quoted span', posixUnquote(scan(frag).spans[0]).value, '%w %h\\n')
  eq('the path slot carries the frame selector', posixUnquote(scan(frag).spans[1]).value, '/c/a.png[0]')
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildDimCmd(p))
    eq(`the dim skeleton survives ${label}`, skeleton(f2), skeleton(frag))
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
    eq(`the path slot still unquotes for ${label}`, posixUnquote(scan(f2).spans[1]).value, p + '[0]')
  }
  eq('a quote in the path is spliced around the [0]', body(CL.buildDimCmd("/c/a';id'.png")), "identify -format '%w %h\\n' '/c/a'\\'';id'\\''.png[0]' 2>/dev/null || true")
  eq('the spliced path unquotes with its suffix intact', posixUnquote("'/c/a'\\'';id'\\''.png[0]'").value, "/c/a';id'.png[0]")
})

group('buildFileInfoCmd - one path, markerless', () => {
  const frag = body(CL.buildFileInfoCmd(['/a/b']))
  eq('exact fragment', frag, "if [ -d '/a/b' ]; then echo DIR; timeout 10 find '/a/b' -xdev -type f -printf '%s\n' 2>/dev/null | awk 'BEGIN{c=0;s=0;big=0} {c++; s+=$1; if(c>20000){print \"TOOBIG\"; big=1; exit}} END{if(!big) print c\" \"s}'; elif [ -f '/a/b' ]; then echo FILE; stat -c %s '/a/b' 2>/dev/null || echo 0; else echo MISSING; fi")
  contains('a directory is walked with find', frag, "timeout 10 find '/a/b' -xdev -type f -printf '%s\n'")
  contains('the walk stays on one filesystem', frag, '-xdev')
  contains('the walk is time-bounded', frag, 'timeout 10 find')
  contains('the walk is awk-summed', frag, "| awk 'BEGIN{c=0;s=0;big=0}")
  contains('a capped walk reports TOOBIG instead of a sum', frag, 'print "TOOBIG"')
  contains('a file is stat-ed', frag, "stat -c %s '/a/b'")
  contains('a missing path is named', frag, 'echo MISSING')
  contains('a stat failure still emits a number', frag, '|| echo 0')
  // The single-path protocol is markerless by design: the parser infers a
  // directory from the line count, so no DIR/FILE token is emitted.
  eq('no chunk marker is emitted for one path', frag.indexOf('ENDDIR'), -1)
  eq('the skeleton is fixed', skeleton(frag), `if [ -d ${SPAN} ]; then echo DIR; timeout 10 find ${SPAN} -xdev -type f -printf ${SPAN} 2>/dev/null | awk ${SPAN}; elif [ -f ${SPAN} ]; then echo FILE; stat -c %s ${SPAN} 2>/dev/null || echo 0; else echo MISSING; fi`)
  // Six quoted slots: the path three times plus the fixed find -printf
  // format and the fixed awk sum, both spans of the library's own and never
  // a payload.
  eq('six quoted slots', scan(frag).spans.length, 6)
  eq('the third slot is the fixed printf format', posixUnquote(scan(frag).spans[2]).value, '%s\n')
  eq('the fourth slot is the fixed awk sum', posixUnquote(scan(frag).spans[3]).value, 'BEGIN{c=0;s=0;big=0} {c++; s+=$1; if(c>20000){print "TOOBIG"; big=1; exit}} END{if(!big) print c" "s}')
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildFileInfoCmd([p]))
    eq(`the single-path skeleton survives ${label}`, skeleton(f2), skeleton(frag))
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
    eq(`all four path slots unquote to the path for ${label}`, scan(f2).spans.map((s) => posixUnquote(s).value), [p, p, '%s\n', 'BEGIN{c=0;s=0;big=0} {c++; s+=$1; if(c>20000){print "TOOBIG"; big=1; exit}} END{if(!big) print c" "s}', p, p])
  }
  eq('a quote in the path is spliced into all four path slots', body(CL.buildFileInfoCmd(["/a/b';id"])).split("'/a/b'\\'';id'").length - 1, 4)
})

group('buildFileInfoCmd - many paths, marker-delimited chunks', () => {
  const frag = body(CL.buildFileInfoCmd(['/a', '/b c', '/d']))
  eq('the paths are a quoted word list in a for loop', frag.startsWith("for p in '/a' '/b c' '/d'; do "), true)
  contains('each chunk is prefixed with its marker and path', frag, 'echo "DIR $p"')
  contains('a directory chunk is closed', frag, 'echo "ENDDIR"')
  contains('a file chunk is closed', frag, 'echo "ENDFILE"')
  contains('a missing chunk is closed', frag, 'echo "ENDMISSING"')
  contains('the walk is time-bounded', frag, 'timeout 10 find')
  contains('the walk stays on one filesystem', frag, '-xdev')
  // The loop reads its operand back through "$p", so even before quoting
  // nothing in a path can be re-tokenised by the shell.
  eq('the loop body only ever expands "$p"', frag.indexOf('$p') >= 0, true)
  eq('the skeleton is fixed', skeleton(frag), `for p in ${SPAN} ${SPAN} ${SPAN}; do if [ -d "$p" ]; then echo "DIR $p"; timeout 10 find "$p" -xdev -type f -printf ${SPAN} 2>/dev/null | awk ${SPAN}; echo "ENDDIR"; elif [ -f "$p" ]; then echo "FILE $p"; stat -c %s "$p" 2>/dev/null || echo 0; echo "ENDFILE"; else echo "MISSING $p"; echo "ENDMISSING"; fi; done`)
  eq('a space stays inside its quoted word', frag.indexOf("'/b c'") >= 0, true)
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildFileInfoCmd([p, p]))
    eq(`the multi skeleton survives ${label}`, skeleton(f2), `for p in ${SPAN} ${SPAN}; do if [ -d "$p" ]; then echo "DIR $p"; timeout 10 find "$p" -xdev -type f -printf ${SPAN} 2>/dev/null | awk ${SPAN}; echo "ENDDIR"; elif [ -f "$p" ]; then echo "FILE $p"; stat -c %s "$p" 2>/dev/null || echo 0; echo "ENDFILE"; else echo "MISSING $p"; echo "ENDMISSING"; fi; done`)
    eq(`both path slots unquote to the path for ${label}`, scan(f2).spans.map((s) => posixUnquote(s).value), [p, p, '%s\n', 'BEGIN{c=0;s=0;big=0} {c++; s+=$1; if(c>20000){print "TOOBIG"; big=1; exit}} END{if(!big) print c" "s}'])
  }
  eq('a quote in one path is spliced', body(CL.buildFileInfoCmd(["/b';id", '/c'])).startsWith("for p in '/b'\\'';id' '/c'; do "), true)
  eq('a single path takes the branch form, not the loop', body(CL.buildFileInfoCmd(["/b';id"])).startsWith('if [ -d'), true)
})

group('buildFileInfoCmd - the degenerate list', () => {
  eq('an empty list is a no-op', CL.buildFileInfoCmd([]), ['sh', '-c', 'true'])
  eq('a null list is a no-op', CL.buildFileInfoCmd(null), ['sh', '-c', 'true'])
  eq('an undefined list is a no-op', CL.buildFileInfoCmd(undefined), ['sh', '-c', 'true'])
  // `true` rather than an empty loop: `for p in ; do` is a syntax error, and
  // an empty `sh -c ""` would still spawn a shell to do nothing.
  eq('the no-op fragment is a single word', body(CL.buildFileInfoCmd([])), 'true')
  eq('two identical paths still take the loop form', body(CL.buildFileInfoCmd(['/a', '/a'])).startsWith('for p in'), true)
  eq('one path takes the branch form', body(CL.buildFileInfoCmd(['/a'])).startsWith('if [ -d'), true)
})

group('buildTextProbeCmd', () => {
  const frag = body(CL.buildTextProbeCmd('/a/b.txt'))
  eq('exact fragment', frag, 'if [ -r \'/a/b.txt\' ]; then file -b --mime \'/a/b.txt\' 2>/dev/null; printf "__HEAD__\\n"; head -c 24576 -- \'/a/b.txt\' 2>/dev/null || true; else echo "binary"; printf "__HEAD__\\n"; fi')
  contains('the head read is capped at 24576 bytes', frag, 'head -c 24576')
  contains('head uses -- so a leading dash is not an option', frag, 'head -c 24576 --')
  contains('an unreadable path falls back to the binary marker', frag, 'echo "binary"')
  contains('the separator is emitted in both branches', (frag.match(/__HEAD__/g) || []).length, 2)
  eq('the skeleton is fixed', skeleton(frag), `if [ -r ${SPAN} ]; then file -b --mime ${SPAN} 2>/dev/null; printf "__HEAD__\\n"; head -c 24576 -- ${SPAN} 2>/dev/null || true; else echo "binary"; printf "__HEAD__\\n"; fi`)
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildTextProbeCmd(p))
    eq(`the probe skeleton survives ${label}`, skeleton(f2), skeleton(frag))
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
    eq(`all three slots unquote to the path for ${label}`, scan(f2).spans.map((s) => posixUnquote(s).value), [p, p, p])
  }
  // A newline in the path is legal inside single quotes, so the fragment is
  // still one word - it is just an odd filename.
  eq('a newline in the path stays inside the quoted word', body(CL.buildTextProbeCmd('/a/b\nX.txt')).indexOf("'/a/b\nX.txt'") >= 0, true)
})

group('buildMediaInfoCmd - the JS-side extension gate', () => {
  const frag = body(CL.buildMediaInfoCmd('/a/b.MP3'))
  eq('mediainfo must exist or nothing runs', frag.startsWith('command -v mediainfo >/dev/null 2>&1 || exit 1; '), true)
  // "The path is lowercased before the case so .MP3 matches the same way
  // extOf() (which lowercases) matches inside isMediaPath()."
  contains('the path is lowercased before the case', frag, "tr '[:upper:]' '[:lower:]'")
  contains('the case covers the audio extensions', frag, '*.mp3|')
  contains('the case covers the video extensions', frag, '*.m4v)')
  contains('a non-media path exits 1', frag, '*) exit 1;;')
  contains('mediainfo is exec-ed, not forked', frag, 'exec mediainfo --')
  eq('the extension list has no uppercase arm', frag.indexOf('*.MP3'), -1)
  eq('mediainfo gets -- so a leading dash is not an option', frag.indexOf('mediainfo -- ') >= 0, true)
  eq('the skeleton is fixed', skeleton(frag), `command -v mediainfo >/dev/null 2>&1 || exit 1; p=${SPAN}; p=$(printf ${SPAN} "$p" | tr ${SPAN} ${SPAN}); case $p in *.mp3|*.flac|*.ogg|*.oga|*.opus|*.wav|*.m4a|*.aac|*.wma|*.mid|*.midi|*.it|*.xm|*.mp4|*.mkv|*.webm|*.mov|*.avi|*.m4v) ;; *) exit 1;; esac; exec mediainfo -- ${SPAN} 2>/dev/null`)
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildMediaInfoCmd(p))
    eq(`the media skeleton survives ${label}`, skeleton(f2), skeleton(frag))
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
    const spans = scan(f2).spans.map((s) => posixUnquote(s).value)
    eq(`the assigned path slot unquotes for ${label}`, spans[0], p)
    eq(`the exec argument unquotes for ${label}`, spans[spans.length - 1], p)
  }
  eq('the literal spans are the printf and the tr classes', scan(body(CL.buildMediaInfoCmd('/a.mp3'))).spans.slice(1, 4).map((s) => posixUnquote(s).value), ['%s', '[:upper:]', '[:lower:]'])
  eq('a quote in the path is spliced in both path slots', body(CL.buildMediaInfoCmd("/a/'; id '.mp3")).indexOf("p='/a/'\\''; id '\\''.mp3'") >= 0, true)
})

group('buildExistenceProbeCmd - the open-on-Enter existence gate', () => {
  const frag = body(CL.buildExistenceProbeCmd(['/a/b', '/c d']))
  eq('exact fragment', frag, 'if [ -e \'/a/b\' ]; then echo "0 ok"; else echo "0 missing"; fi; if [ -e \'/c d\' ]; then echo "1 ok"; else echo "1 missing"; fi; true')
  contains('each path is tested with -e', frag, "[ -e '/a/b' ]")
  contains('a space stays inside its quoted word', frag, "'/c d'")
  contains('the verdicts are index-addressed, never path-echoed', frag, 'echo "0 ok"')
  eq('an empty list is a no-op', CL.buildExistenceProbeCmd([]), ['sh', '-c', 'true'])
  eq('a null list is a no-op', CL.buildExistenceProbeCmd(null), ['sh', '-c', 'true'])
  eq('an undefined list is a no-op', CL.buildExistenceProbeCmd(undefined), ['sh', '-c', 'true'])
  eq('the skeleton is fixed', skeleton(frag), `if [ -e ${SPAN} ]; then echo "0 ok"; else echo "0 missing"; fi; if [ -e ${SPAN} ]; then echo "1 ok"; else echo "1 missing"; fi; true`)
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildExistenceProbeCmd([p]))
    eq(`the existence skeleton survives ${label}`, skeleton(f2), `if [ -e ${SPAN} ]; then echo "0 ok"; else echo "0 missing"; fi; true`)
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
    eq(`the slot unquotes to the path for ${label}`, posixUnquote(scan(f2).spans[0]).value, p)
  }
  eq('a quote in the path is spliced', body(CL.buildExistenceProbeCmd(["/a/';id"])).indexOf("'/a/'\\'';id'") >= 0, true)
})

group('parseExistenceProbe - index verdicts, never a silent open', () => {
  eq('one ok one missing', CL.parseExistenceProbe('0 ok\n1 missing\n', 2), { existing: [0], missing: [1] })
  eq('all ok', CL.parseExistenceProbe('0 ok\n1 ok\n', 2), { existing: [0, 1], missing: [] })
  eq('all missing', CL.parseExistenceProbe('0 missing\n1 missing\n', 2), { existing: [], missing: [0, 1] })
  // A truncated output never drops a path into the open set: an index with
  // no "ok" line lands in missing and is never executed.
  eq('a truncated line leaves the index missing', CL.parseExistenceProbe('0 ok\n', 2), { existing: [0], missing: [1] })
  eq('empty output misses everything', CL.parseExistenceProbe('', 2), { existing: [], missing: [0, 1] })
  eq('a duplicate second line does not flip the first', CL.parseExistenceProbe('0 ok\n0 missing\n', 1), { existing: [0], missing: [] })
  eq('an out-of-range index is ignored', CL.parseExistenceProbe('99 ok\n0 ok\n', 1), { existing: [0], missing: [] })
  eq('a line with no separator is ignored', CL.parseExistenceProbe('bogus\n0 ok\n', 1), { existing: [0], missing: [] })
  eq('a zero count answers empty', CL.parseExistenceProbe('0 ok\n', 0), { existing: [], missing: [] })
})

group('buildGitInfoCmd - the read-only repo probe', () => {
  const argv = CL.buildGitInfoCmd('/a')
  eq('three-element sh -c argv', [argv[0], argv[1], typeof argv[2]], ['sh', '-c', 'string'])
  const frag = body(argv)
  contains('no git means MISS, not failure', frag, 'command -v git >/dev/null 2>&1 || { echo "GIT MISS"; exit 0; }')
  contains('a failed status means MISS too', frag, 'status --porcelain=v1 -b --untracked-files=no 2>/dev/null) || { echo "GIT MISS"; exit 0; }')
  contains('the locale is pinned for every git read', frag, 'export LC_ALL=C; ')
  contains('one status call carries the branch header', frag, 'echo "head $(printf')
  for (const key of ['echo "GIT OK"', '"---STATUS---"', '"---END---"', '"---COMMIT---"', '"---ENDCOMMIT---"', 'echo "remote ']) {
    contains(`the ${key} line is emitted`, frag, key)
  }
  contains('hash, author, email, time and subject share one log read', frag, "log -1 --format='chash %h%nauthor %an%nemail %ae%nctime %ct%nsubject %s'")
  contains('status stays off the untracked walk', frag, '--untracked-files=no')
  contains('a stale lock can never hang the probe', frag, '--no-optional-locks')
  contains('branch, upstream and file list share one fork', frag, "--porcelain=v1 -b")
  contains('the path is bound once and reused by variable', frag, "p='/a'")
  eq('a nullish path still builds', Array.isArray(CL.buildGitInfoCmd(null)), true)
  const benign = skeleton(body(CL.buildGitInfoCmd('/home/u/repo')))
  for (const [label, p] of INJECTIONS) {
    const f2 = body(CL.buildGitInfoCmd(p))
    eq(`the git skeleton survives ${label}`, skeleton(f2), benign)
    notContains(`${label} does not reach unquoted text`, skeleton(f2), p.replace(/\n/g, ''))
  }
  eq('the quoted span unquotes to the path', posixUnquote(scan(body(CL.buildGitInfoCmd("/tmp/it's"))).spans[0]).value, "/tmp/it's")
})

group('parseGitInfoOutput - the probe verdict, never a throw', () => {
  const full = 'GIT OK\nhead ## main...origin/main [ahead 2, behind 1]\n---STATUS---\nR  old -> new\nUU both\nAA added\n?? new\n---END---\n---COMMIT---\nchash a1b2c3d\nauthor Ada Lovelace\nctime 1728998400\nsubject subject here\n---ENDCOMMIT---\nremote git@github.com:u/r.git\n'
  eq('a non-repo is null', CL.parseGitInfoOutput('GIT MISS\n'), null)
  eq('empty output is null', CL.parseGitInfoOutput(''), null)
  eq('a missing header is null', CL.parseGitInfoOutput('head ## main\n'), null)
  eq('a wrong header is null', CL.parseGitInfoOutput('GIT OKAY\nhead ## main\n'), null)
  const g = CL.parseGitInfoOutput(full)
  eq('branch', g.branch, 'main')
  eq('upstream', g.upstream, 'origin/main')
  eq('ahead', g.ahead, 2)
  eq('behind', g.behind, 1)
  eq('not detached', g.detached, false)
  eq('not gone', g.gone, false)
  eq('staged counts renames', g.staged, 3)
  eq('unstaged counts modifications', g.unstaged, 2)
  eq('hash', g.chash, 'a1b2c3d')
  eq('author rides verbatim', g.cauthor, 'Ada Lovelace')
  eq('no email line means empty email, not a throw', g.cemail, '')
  eq('an email line rides verbatim', CL.parseGitInfoOutput(full.replace('\nctime ', '\nemail ada@example.com\nctime ')).cemail, 'ada@example.com')
  eq('time stays numeric', g.ctime, '1728998400')
  eq('subject rides verbatim', g.csubject, 'subject here')
  eq('remote is cleaned at parse', g.remote, 'github.com/u/r')
  // Head-line shapes: the whole branch/upstream/sync story in one line.
  const plain = CL.parseGitInfoOutput('GIT OK\nhead ## main\n---STATUS---\n---END---\n')
  eq('no upstream leaves counts zero', [plain.upstream, plain.ahead, plain.behind], ['', 0, 0])
  const behind = CL.parseGitInfoOutput('GIT OK\nhead ## main...origin/main [behind 3]\n---STATUS---\n---END---\n')
  eq('behind alone', [behind.ahead, behind.behind], [0, 3])
  const det = CL.parseGitInfoOutput('GIT OK\nhead ## HEAD (no branch)\n---STATUS---\n---END---\n')
  eq('detached names no branch', det.branch, '')
  eq('and says so', det.detached, true)
  const fresh = CL.parseGitInfoOutput('GIT OK\nhead ## No commits yet on main\n---STATUS---\n---END---\n')
  eq('an unborn HEAD still names its branch', fresh.branch, 'main')
  eq('and is not detached', fresh.detached, false)
  const gone = CL.parseGitInfoOutput('GIT OK\nhead ## feat...origin/feat [gone]\n---STATUS---\n---END---\n')
  eq('a deleted upstream keeps its name', gone.upstream, 'origin/feat')
  eq('and reads as gone', gone.gone, true)
  eq('a malformed head names nothing', CL.parseGitInfoOutput('GIT OK\nhead main\n---STATUS---\n---END---\n').branch, '')
  // Absent data omits rather than fakes.
  const bare = CL.parseGitInfoOutput('GIT OK\nhead ## main\n---STATUS---\n---END---\n---COMMIT---\n---ENDCOMMIT---\nremote \n')
  eq('empty commit block stays empty', [bare.chash, bare.cauthor, bare.cemail, bare.ctime, bare.csubject], ['', '', '', '', ''])
  eq('empty remote stays empty', bare.remote, '')
  eq('a clean tree counts zero', [bare.staged, bare.unstaged], [0, 0])
  // Unknown keys are ignored, truncated sections do not throw.
  noThrow('unknown keys', () => CL.parseGitInfoOutput('GIT OK\nfrobnicate 1\ncounts 1 2\n'))
  eq('a counts line no longer moves anything', CL.parseGitInfoOutput('GIT OK\nhead ## main\ncounts 9 9\n---STATUS---\n---END---\n').ahead, 0)
  // A short line is not a verdict.
  const short = CL.parseGitInfoOutput('GIT OK\n---STATUS---\nM\n---END---\n')
  eq('a one-character status line counts nothing', [short.staged, short.unstaged], [0, 0])
  eq('no status section counts nothing', CL.parseGitInfoOutput('GIT OK\nhead ## main\n').staged, 0)
  eq('nullish input is null, not a throw', CL.parseGitInfoOutput(null), null)
})

group('cleanGitRemote - a URL reduced to host/path', () => {
  eq('scp syntax', CL.cleanGitRemote('git@github.com:user/repo.git'), 'github.com/user/repo')
  eq('scp without a user', CL.cleanGitRemote('github.com:user/repo.git'), 'github.com/user/repo')
  eq('https', CL.cleanGitRemote('https://github.com/user/repo.git'), 'github.com/user/repo')
  eq('https with credentials', CL.cleanGitRemote('https://user@github.com/user/repo'), 'github.com/user/repo')
  eq('ssh scheme', CL.cleanGitRemote('ssh://git@github.com/user/repo.git'), 'github.com/user/repo')
  eq('a local path passes through', CL.cleanGitRemote('/srv/git/repo.git'), '/srv/git/repo')
  eq('a trailing slash goes', CL.cleanGitRemote('https://h/u/r/'), 'h/u/r')
  eq('empty stays empty', CL.cleanGitRemote(''), '')
  eq('nullish stays empty', CL.cleanGitRemote(null), '')
  eq('whitespace is trimmed', CL.cleanGitRemote('  https://h/u/r.git  '), 'h/u/r')
})

group('gitInfoRows - the repo card in folder vocabulary', () => {
  eq('a non-repo renders nothing', CL.gitInfoRows(null), [])
  eq('an empty object renders nothing', CL.gitInfoRows({}), [])
  eq('a branchless non-detached renders nothing', CL.gitInfoRows({ branch: '', staged: 3 }), [])
  const rows = CL.gitInfoRows({ branch: 'main', upstream: 'origin/main', ahead: 2, behind: 1, staged: 1, unstaged: 0, chash: 'a1b2c3d', csubject: 'subject', cauthor: 'Ada Lovelace', ctime: '1728998400', remote: 'github.com/u/r' })
  eq('seven rows in vocabulary order', rows, [
    { icon: 'git', label: 'Branch', value: 'main \u2192 origin/main' },
    { icon: 'git', label: 'Status', value: '1 staged' },
    { icon: 'git', label: 'Sync', value: 'ahead 2, behind 1' },
    { icon: 'git', label: 'Commit', value: 'a1b2c3d - subject' },
    { icon: 'git', label: 'Date', value: CL.formatGitTime('1728998400') },
    { icon: 'git', label: 'Author', value: 'Ada Lovelace' },
    { icon: 'git', label: 'Remote', value: 'github.com/u/r' },
  ])
  eq('every row rides the git icon', rows.every((r) => r.icon === 'git'), true)
  const clean = CL.gitInfoRows({ branch: 'main', upstream: 'origin/main', ahead: 0, behind: 0, staged: 0, unstaged: 0, chash: 'abc', csubject: '', cauthor: '', ctime: '', remote: '' })
  eq('a clean tree says clean', clean[1], { icon: 'git', label: 'Status', value: 'clean' })
  eq('a synced upstream says up to date', clean[2], { icon: 'git', label: 'Sync', value: 'up to date' })
  eq('no author means no row', clean.some((r) => r.label === 'Author'), false)
  eq('an author with an email rides in parentheses', CL.gitInfoRows({ branch: 'main', cauthor: 'Ada Lovelace', cemail: 'ada@example.com' }).find((r) => r.label === 'Author'), { icon: 'git', label: 'Author', value: 'Ada Lovelace (ada@example.com)' })
  eq('an author without an email reads as before', CL.gitInfoRows({ branch: 'main', cauthor: 'Ada Lovelace', cemail: '' }).find((r) => r.label === 'Author'), { icon: 'git', label: 'Author', value: 'Ada Lovelace' })
  eq('an email without an author still renders', CL.gitInfoRows({ branch: 'main', cauthor: '', cemail: 'ada@example.com' }).find((r) => r.label === 'Author'), { icon: 'git', label: 'Author', value: 'ada@example.com' })
  eq('no time means no row', clean.some((r) => r.label === 'Committed'), false)
  eq('no remote means no row', clean.some((r) => r.label === 'Remote'), false)
  const detached = CL.gitInfoRows({ branch: '', detached: true, upstream: '', ahead: 0, behind: 0, staged: 0, unstaged: 2, chash: '', csubject: '', cauthor: '', ctime: '', remote: '' })
  eq('an empty branch reads detached', detached[0], { icon: 'git', label: 'Branch', value: '(detached)' })
  eq('no upstream means no sync row', detached.some((r) => r.label === 'Sync'), false)
  eq('no commit means no commit row', detached.some((r) => r.label === 'Commit'), false)
  const behind = CL.gitInfoRows({ branch: 'f', upstream: 'o/f', ahead: 0, behind: 3, staged: 0, unstaged: 0, chash: '', csubject: '', cauthor: '', ctime: '', remote: '' })
  eq('behind alone', behind[2], { icon: 'git', label: 'Sync', value: 'behind 3' })
  const hashOnly = CL.gitInfoRows({ branch: 'f', upstream: '', ahead: 0, behind: 0, staged: 0, unstaged: 0, chash: 'abc1234', csubject: '', cauthor: '', ctime: '', remote: '' })
  eq('a subject-less commit is just the hash', hashOnly[2], { icon: 'git', label: 'Commit', value: 'abc1234' })
  const gone = CL.gitInfoRows({ branch: 'feat', detached: false, upstream: 'origin/feat', ahead: 0, behind: 0, gone: true, staged: 0, unstaged: 0, chash: '', csubject: '', cauthor: '', ctime: '', remote: '' })
  eq('a deleted upstream is not up to date', gone[2], { icon: 'git', label: 'Sync', value: 'upstream gone' })
  const long = CL.gitInfoRows({ branch: 'f', upstream: '', ahead: 0, behind: 0, staged: 0, unstaged: 0, chash: 'abc', csubject: 'x'.repeat(300), cauthor: '', ctime: '', remote: '' })
  eq('a pathological subject is capped with an ellipsis', long[2].value, 'abc - ' + 'x'.repeat(200) + '\u2026')
})

group('formatGitTime - numeric timestamp to local YYYY-MM-DD HH:MM', () => {
  // Numeric fields only, so the output is identical under every locale.
  // Shape-pinned rather than value-pinned: the local zone is the host's.
  is('shape', CL.formatGitTime('1728998400'), (v) => /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(v), 'YYYY-MM-DD HH:MM')
  eq('zero is not a time', CL.formatGitTime('0'), '')
  eq('negative is not a time', CL.formatGitTime('-5'), '')
  eq('non-numeric is not a time', CL.formatGitTime('yesterday'), '')
  eq('empty is not a time', CL.formatGitTime(''), '')
  eq('nullish is not a time', CL.formatGitTime(null), '')
  eq('surrounding whitespace is tolerated', CL.formatGitTime('  1728998400  ') === '', false)
})

group('buildOpenCmd - xdg-open inside app2unit, like the launcher', () => {
  eq('exact argv', CL.buildOpenCmd('/tmp/a.png'), ['app2unit', '-S', 'both', '-s', 'app-graphical.slice', '--', 'xdg-open', '/tmp/a.png'])
  eq('a path with a space stays one argv element', CL.buildOpenCmd('/tmp/my pic.png'), ['app2unit', '-S', 'both', '-s', 'app-graphical.slice', '--', 'xdg-open', '/tmp/my pic.png'])
  // Direct argv (no sh): an injection-shaped path is inert because there is
  // no shell to interpret it.
  eq('a semicolon in a path is inert in argv', CL.buildOpenCmd('/tmp/a;rm -rf /')[7], '/tmp/a;rm -rf /')
  eq('a quote in a path is inert in argv', CL.buildOpenCmd("/tmp/it's.png")[7], "/tmp/it's.png")
  is('never invokes a shell', CL.buildOpenCmd('/a'), (a) => a.indexOf('sh') === -1, 'no sh in argv')
})

group('openPathsFor - what Enter opens instead of re-copying', () => {
  eq('a file yields its path', CL.openPathsFor({ type: 'file', filePaths: ['/tmp/a.txt'] }), ['/tmp/a.txt'])
  eq('a folder yields its path', CL.openPathsFor({ type: 'folder', filePaths: ['/tmp/d'] }), ['/tmp/d'])
  eq('an archive yields its path', CL.openPathsFor({ type: 'archive', filePaths: ['/tmp/a.zip'] }), ['/tmp/a.zip'])
  eq('an image file prefers imageFile', CL.openPathsFor({ type: 'image', imageFile: '/tmp/a.png', imageDataFile: '/c/t1.png', filePaths: ['/tmp/a.png'] }), ['/tmp/a.png'])
  eq('an image snapshot falls back to imageDataFile', CL.openPathsFor({ type: 'image', imageFile: '', imageDataFile: '/c/t1.png', filePaths: [] }), ['/c/t1.png'])
  eq('an image with only filePaths uses it', CL.openPathsFor({ type: 'image', imageFile: '', imageDataFile: '', filePaths: ['/tmp/a.png'] }), ['/tmp/a.png'])
  eq('files yield every absolute path', CL.openPathsFor({ type: 'files', filePaths: ['/a', '/b'] }), ['/a', '/b'])
  eq('folders yield every absolute path', CL.openPathsFor({ type: 'folders', filePaths: ['/a', '/b'] }), ['/a', '/b'])
  eq('a relative file path yields nothing', CL.openPathsFor({ type: 'file', filePaths: ['rel/a.txt'] }), [])
  eq('an empty filePaths yields nothing', CL.openPathsFor({ type: 'file', filePaths: [] }), [])
  eq('text never opens', CL.openPathsFor({ type: 'text', filePaths: [], raw: '/tmp/a.txt' }), [])
  eq('a url never opens as a file', CL.openPathsFor({ type: 'url', filePaths: [], raw: 'https://x.dev' }), [])
  eq('network never opens as a file', CL.openPathsFor({ type: 'network', filePaths: ['smb://h/x'], raw: 'smb://h/x' }), [])
  eq('a secret never opens', CL.openPathsFor({ type: 'secret', filePaths: [] }), [])
  eq('null yields nothing', CL.openPathsFor(null), [])
  eq('undefined yields nothing', CL.openPathsFor(undefined), [])
})

group('folderInfoRows - the folder card, free off the probe fields', () => {
  eq('a probed folder yields three rows', CL.folderInfoRows({ type: 'folder', filePaths: ['/home/u/docs'], folderCount: 4, fileSize: 1024 }), [
    { icon: 'file-folder', label: 'Folder', value: 'docs' },
    { icon: 'files', label: 'Files', value: '4 files' },
    { icon: 'save', label: 'Size', value: '1 KB' },
  ])
  eq('a singular file count reads file', CL.folderInfoRows({ type: 'folder', filePaths: ['/a'], folderCount: 1 })[1], { icon: 'files', label: 'Files', value: '1 file' })
  eq('a zero count still prints', CL.folderInfoRows({ type: 'folder', filePaths: ['/a'], folderCount: 0 })[1], { icon: 'files', label: 'Files', value: '0 files' })
  // Absent means pending: the probe has not landed, so the row is
  // omitted rather than faked - but the path is known at capture.
  eq('a pending folder shows only its name', CL.folderInfoRows({ type: 'folder', filePaths: ['/home/u/docs'] }), [
    { icon: 'file-folder', label: 'Folder', value: 'docs' },
  ])
  eq('a null count omits the row', CL.folderInfoRows({ type: 'folder', filePaths: ['/a'], folderCount: null, fileSize: 10 }).length, 2)
  eq('a zero size omits the row, not zero', CL.folderInfoRows({ type: 'folder', filePaths: ['/a'], folderCount: 2, fileSize: 0 }).length, 2)
  eq('a root path falls back to itself', CL.folderInfoRows({ type: 'folder', filePaths: ['/'] }), [
    { icon: 'file-folder', label: 'Folder', value: '/' },
  ])
  eq('null yields nothing', CL.folderInfoRows(null), [])
  eq('undefined yields nothing', CL.folderInfoRows(undefined), [])
  eq('a row with no path yields nothing', CL.folderInfoRows({ type: 'text', raw: 'x' }), [])
})

group('openMissingText - the notice copy for a failed existence probe', () => {
  eq('a single-path row names no count', CL.openMissingText(1, 1), 'File not found')
  eq('one of many names one', CL.openMissingText(1, 3), '1 file not found')
  eq('two of many name the count', CL.openMissingText(2, 3), '2 files not found')
  eq('all of many name the count', CL.openMissingText(3, 3), '3 files not found')
  eq('nothing missing is the empty string', CL.openMissingText(0, 1), '')
  eq('nothing missing of many is the empty string', CL.openMissingText(0, 3), '')
  eq('a zero total reads as a single row', CL.openMissingText(1, 0), 'File not found')
  eq('an undefined total reads as a single row', CL.openMissingText(1, undefined), 'File not found')
  eq('a non-numeric missing count is empty', CL.openMissingText('x', 3), '')
})

group('buildSubLeft - a flagged-missing row shows the notice, not metadata', () => {
  eq('a missing file replaces its size', CL.buildSubLeft({ type: 'file', fileSize: 5000, missing: true, missingText: 'File not found' }), 'File not found')
  eq('a missing image replaces dimensions and size', CL.buildSubLeft({ type: 'image', imageW: 800, imageH: 600, fileSize: 2048, missing: true, missingText: 'File not found' }), 'File not found')
  eq('a missing multi-row names the count', CL.buildSubLeft({ type: 'files', filePaths: ['/a', '/b'], missing: true, missingText: '1 file not found' }), '1 file not found')
  eq('an empty notice falls back to the single-row copy', CL.buildSubLeft({ type: 'file', missing: true, missingText: '' }), 'File not found')
  eq('a non-true flag keeps the metadata', CL.buildSubLeft({ type: 'file', fileSize: 5000, missing: 1, missingText: 'File not found' }), '4.9 KB')
  eq('an unflagged row is untouched', CL.buildSubLeft({ type: 'file', fileSize: 5000 }), '4.9 KB')
  eq('a flagged row re-derives to the notice', CL.deriveEntry(Object.assign(CL.newEntry('m', 1, 'x', 'text/uri-list', 'file', ['/a']), { fileSize: 5000, missing: true, missingText: 'File not found' })).subLeft, 'File not found')
})

group('exportEntry - a flagged-missing row keeps its flag on disk', () => {
  const flagged = Object.assign(CL.newEntry('n', 9, 'x', 'text/uri-list', 'file', ['/a']), { missing: true, missingText: 'File not found' })
  eq('the flag is persisted', CL.exportEntry(flagged).missing, true)
  eq('and the notice with it', CL.exportEntry(flagged).missingText, 'File not found')
  eq('an unflagged row persists clean', CL.exportEntry(CL.newEntry('o', 9, 'x', 'm', 'text')).missing, false)
  eq('a non-string notice is stringified away', CL.exportEntry(Object.assign(CL.newEntry('p', 9, 'x', 'm', 'text'), { missing: true, missingText: 7 })).missingText, '')
})

group('every sh -c fragment has a fixed skeleton and a recoverable payload', () => {
  // The blanket form of the per-builder checks. For each fragment: the argv
  // shape, an identical skeleton for a benign and a hostile path, and a
  // quoted slot that unquotes back to exactly the payload.
  const builders = [
    // buildCopyUrisCmd is handed a URI (its caller runs toFileUri first), so
    // the quoted word is the URI itself, not the path behind it.
    ['buildCopyUrisCmd', (p) => CL.buildCopyUrisCmd(p), (p) => p],
    ['buildImageSnapshotCmd', (p) => CL.buildImageSnapshotCmd('image/png', p), (p) => p],
    ['buildDimCmd', (p) => CL.buildDimCmd(p), (p) => p + '[0]'],
    ['buildFileInfoCmd(one)', (p) => CL.buildFileInfoCmd([p]), (p) => p],
    ['buildFileInfoCmd(multi)', (p) => CL.buildFileInfoCmd([p]), (p) => p],
    ['buildTextProbeCmd', (p) => CL.buildTextProbeCmd(p), (p) => p],
    ['buildMediaInfoCmd', (p) => CL.buildMediaInfoCmd(p), (p) => p],
    ['buildExistenceProbeCmd', (p) => CL.buildExistenceProbeCmd([p]), (p) => p],
  ]
  for (const [name, fn, want] of builders) {
    const benign = body(fn('/tmp/benign.png'))
    const attacked = body(fn(NASTY))
    eq(`${name} is a three-element sh -c argv`, fn('/tmp/benign.png').length, 3)
    eq(`${name} keeps the same executable skeleton`, skeleton(attacked), skeleton(benign))
    eq(`${name} quotes the payload exactly once per slot`, scan(attacked).spans.filter((s) => posixUnquote(s).value === want(NASTY)).length >= 1, true)
    eq(`${name} leaves no bare text at all`, scan(attacked).spans.every((s) => posixUnquote(s).bare === ''), true)
    eq(`${name} does not leak the payload into the skeleton`, skeleton(attacked).indexOf("id '.mp4"), -1)
  }
})

// ===========================================================================
section('ClipboardLib - the secret codec')
// ===========================================================================

group('hex4', () => {
  eq('a small code point pads to four', CL.hex4(0x41), '0041')
  eq('zero', CL.hex4(0), '0000')
  eq('the maximum code point', CL.hex4(0xffff), 'ffff')
  eq('a value past 16 bits keeps the low 16', CL.hex4(0x1ffff), 'ffff')
  eq('a value over four hex digits is truncated, not grown', CL.hex4(0x10000), '0000')
  eq('always four characters for a real code point', [0, 1, 255, 4096, 65535].map(CL.hex4).every((s) => s.length === 4), true)
  eq('always lowercase hex', [0xab, 0xcd, 0xef].map(CL.hex4).join(''), '00ab00cd00ef')
  eq('a value with a leading zero keeps all four digits', CL.hex4(0x000a), '000a')
  // A negative value is outside the contract (charCode ^ charCode is never
  // negative) and produces a non-hex string; pinned so it is a visible diff
  // rather than silent corruption if that ever changes.
  eq('a negative value is not hex at all', CL.hex4(-1), '00-1')
})

group('encryptSecret - four hex digits per code point', () => {
  const key = 'abc'
  eq('one code point per key position', CL.encryptSecret('ab', key), CL.hex4(0) + CL.hex4(0))
  eq('the output is four hex chars per input char', CL.encryptSecret('hunter2', 'k').length, 'hunter2'.length * 4)
  eq('the output is pure lowercase hex', /^[0-9a-f]+$/.test(CL.encryptSecret('hunter2', 'k')), true)
  eq('an empty payload encrypts to the empty string', CL.encryptSecret('', key), '')
  eq('a null payload is the empty string', CL.encryptSecret(null, key), '')
  eq('an undefined payload is the empty string', CL.encryptSecret(undefined, key), '')
  // "if (key === \"\") return s" - no key means no encryption at all, which is
  // why the history writer must always have generated one.
  eq('an empty key is the identity', CL.encryptSecret('abc', ''), 'abc')
  eq('a null key is the identity', CL.encryptSecret('abc', null), 'abc')
  eq('an undefined key is the identity', CL.encryptSecret('abc', undefined), 'abc')
  // The key repeats over the payload: 'a'^'a' = 0 at every position here.
  eq('a same-char key zeroes every code point', CL.encryptSecret('aaaa', 'a'), '0000000000000000')
  eq('a one-character key repeats across the payload', CL.encryptSecret('aaaa', 'a'), CL.encryptSecret('aaaa', 'a'))
  eq('an XOR is its own inverse per position', CL.decryptSecret(CL.encryptSecret('abc', 'k'), 'k'), 'abc')
  // The ciphertext is not any trivial transform of the plaintext.
  const ct = CL.encryptSecret('hunter2', 'key1')
  ne('the ciphertext is not the plaintext', ct, 'hunter2')
  ne('the ciphertext is not the plaintext reversed', ct, '2retnuh')
  ne('the ciphertext is not base64 of the plaintext', ct, Buffer.from('hunter2', 'utf8').toString('base64'))
  eq('the ciphertext is 4x the plaintext length here', ct.length, 'hunter2'.length * 4)
  eq('the ciphertext length is independent of the key length', CL.encryptSecret('hunter2', 'a'.repeat(64)).length, 28)
})

group('encryptSecret / decryptSecret round-trip', () => {
  const cases = [
    ['an ascii payload', 'hunter2', 'key1'],
    ['a single char', 'a', 'k'],
    ['a key longer than the payload', 'abc', 'a-very-long-install-key'],
    ['a key shorter than the payload', 'a longer payload than the key', 'k'],
    ['a payload with spaces', 'the quick brown fox', 'install-key'],
    ['a payload with punctuation', 'a;b|c&d!e?f*g#h', 'install-key'],
    ['unicode', 'héllo wörld 秘密 привет', 'install-key'],
    ['an emoji', 'h\u{1F600}i', 'install-key'],
    // The codec works on char codes, not re-encoded UTF-8 bytes, so an
    // astral code point (two UTF-16 units) survives as two units.
    ['an astral code point', '\u{1D518}', 'k'],
    ['an embedded NUL', 'a\u0000b\u001Fc', 'install-key'],
    ['a payload that is only newlines', 'a\nb\nc', 'install-key'],
    ['a payload of quotes', "'''", 'install-key'],
    ['a payload that is the key', 'key1', 'key1'],
  ]
  for (const [label, payload, key] of cases) {
    eq(`round-trips ${label}`, CL.decryptSecret(CL.encryptSecret(payload, key), key), payload)
  }
  eq('round-trips an empty payload', CL.decryptSecret(CL.encryptSecret('', 'k'), 'k'), '')
  const long = 'x'.repeat(5000) + 'ü'
  eq('round-trips a 5001-char payload', CL.decryptSecret(CL.encryptSecret(long, 'k'), 'k').length, long.length)
  eq('round-trips a 5001-char payload exactly', CL.decryptSecret(CL.encryptSecret(long, 'k'), 'k'), long)
  eq('round-trips with a 64-char install key', CL.decryptSecret(CL.encryptSecret(long, 'a'.repeat(64)), 'a'.repeat(64)), long)
  // The cipher is deterministic: the same key over the same payload produces
  // the same bytes, which is what lets an export be compared to a re-import.
  eq('encryption is deterministic', CL.encryptSecret('hunter2', 'k'), CL.encryptSecret('hunter2', 'k'))
  eq('a different key gives different bytes', CL.encryptSecret('hunter2', 'k1') !== CL.encryptSecret('hunter2', 'k2'), true)
})

group('decryptSecret - a wrong key must not return the plaintext', () => {
  const ct = CL.encryptSecret('hunter2', 'key1')
  const wrong = CL.decryptSecret(ct, 'key2')
  ne('a different key does not recover the plaintext', wrong, 'hunter2')
  ne('a different key does not recover the plaintext reversed', wrong, '2retnuh')
  eq('the wrong key still decodes to the same length', wrong.length, 'hunter2'.length)
  eq('a key differing in one character changes the output', CL.decryptSecret(ct, 'key2') !== CL.decryptSecret(ct, 'key3'), true)
  eq('a key of the wrong length changes the output', CL.decryptSecret(ct, 'key1x') !== CL.decryptSecret(ct, 'key1'), true)
  // A truncated or non-hex payload does not throw: the migration read runs on
  // whatever a file happened to contain.
  noThrow('a non-hex payload', () => CL.decryptSecret('zzzz', 'k'))
  noThrow('a short payload', () => CL.decryptSecret('ab', 'k'))
  eq('a non-hex nibble still xors with the key', CL.decryptSecret('0000zzzz', 'k'), 'kk')
  // Integrity gate: garbage that cannot be text (lone surrogates,
  // non-characters, C1 controls) returns "" so the caller marks the row
  // unavailable instead of stashing it.
  eq('a lone surrogate fails the integrity gate', CL.decryptSecret('d800', '\u0000'), '')
  eq('a C1 control fails the integrity gate', CL.decryptSecret('0080', '\u0000'), '')
  eq('a short payload yields a shorter string', CL.decryptSecret('0000', 'k').length, 1)
  // An empty key is the identity, so a file with no key beside it decodes to
  // its own hex characters rather than throwing.
  eq('an empty key is the identity', CL.decryptSecret('abcd', ''), 'abcd')
  eq('a null key is the identity', CL.decryptSecret('abcd', null), 'abcd')
  // Asymmetry worth naming: encryptSecret stringifies its first argument but
  // decryptSecret uses `hex` raw, so a non-string ciphertext throws instead of
  // returning "". The migration read always passes a string from a file, so
  // this is a totality gap rather than a live path.
  throws('a non-string ciphertext throws', () => CL.decryptSecret(undefined, 'k'), /substring/)
  throws('a null ciphertext throws', () => CL.decryptSecret(null, 'k'), /substring/)
  noThrow('a numeric ciphertext passed as a string', () => CL.decryptSecret('000000010000', 'k'))
  eq('that string decodes to one char per four hex digits', CL.decryptSecret('000000010000', 'k').length, 3)
})

group('generateKey - 32 random bytes as 64 hex characters', () => {
  const k = CL.generateKey()
  eq('64 characters', k.length, 64)
  eq('lowercase hex only', /^[0-9a-f]{64}$/.test(k), true)
  // The loop runs 32 times and appends two hex digits each, so the key is
  // 256 bits of entropy rendered as 64 characters - not the 32 characters a
  // reader might expect from the `i < 32` bound.
  ne('two calls differ', CL.generateKey(), CL.generateKey())
  const ten = new Set()
  for (let i = 0; i < 10; i++) ten.add(CL.generateKey())
  is('ten calls are all distinct', ten, (s) => s.size === 10, '10 distinct keys')
  // Every byte position reaches both nibbles, so the first hex character
  // varies - a constant prefix would be a broken generator.
  const set = new Set()
  for (let i = 0; i < 40; i++) set.add(CL.generateKey().charAt(0))
  is('the first hex character varies', set, (s) => s.size > 1, 'more than one first character')
  const tail = new Set()
  for (let i = 0; i < 40; i++) tail.add(CL.generateKey().charAt(63))
  is('the last hex character varies', tail, (s) => s.size > 1, 'more than one last character')
  eq('the key is a string', typeof k, 'string')
  // One key for both halves. The codec is a keyed XOR with an integrity gate
  // that refuses a wrong key's garbage, so decrypting with a SECOND generated
  // key returns seven bytes of noise most of the time and "" the rest - an
  // assertion that passed or failed depending on the random bytes.
  const own = CL.generateKey()
  eq('a generated key opens its own ciphertext', CL.decryptSecret(CL.encryptSecret('hunter2', own), own), 'hunter2')
  // A different key must not open it.
  ne('another key does not', CL.decryptSecret(CL.encryptSecret('hunter2', own), CL.generateKey()), 'hunter2')
  // generateKey is 32 bytes, so it is exactly as long as the history's
  // migration read expects from a beside-stored key.
  eq('the key is 32 bytes wide', CL.generateKey().length / 2, 32)
})

// ===========================================================================
section('ClipboardLib - URI handling')
// ===========================================================================

group('toFileUri - one encodeURIComponent per segment', () => {
  eq('a simple path', CL.toFileUri('/tmp/a.png'), 'file:///tmp/a.png')
  eq('a space is percent-encoded', CL.toFileUri('/tmp/a b.png'), 'file:///tmp/a%20b.png')
  eq('a # is percent-encoded', CL.toFileUri('/tmp/a#b.png'), 'file:///tmp/a%23b.png')
  eq('a ? is percent-encoded', CL.toFileUri('/tmp/a?b.png'), 'file:///tmp/a%3Fb.png')
  eq('unicode is UTF-8 percent-encoded', CL.toFileUri('/tmp/h\u00e9llo.png'), 'file:///tmp/h%C3%A9llo.png')
  eq('a percent sign is encoded', CL.toFileUri('/tmp/100%.png'), 'file:///tmp/100%25.png')
  // "Root must serialize as the canonical triple-slash form."
  eq('the root', CL.toFileUri('/'), 'file:///')
  eq('a double slash collapses to a single one', CL.toFileUri('//tmp//a.png'), 'file:///tmp/a.png')
  eq('a relative path still gets the scheme', CL.toFileUri('tmp/a.png'), 'file:///tmp/a.png')
  eq('an empty path is the root', CL.toFileUri(''), 'file:///')
  eq('every segment is encoded separately', CL.toFileUri('/a/b c/d e.png'), 'file:///a/b%20c/d%20e.png')
  // encodeURIComponent leaves "'" alone, which is why sq() has to splice it.
  eq("encodeURIComponent does not touch an apostrophe", CL.toFileUri("/tmp/it's.png"), "file:///tmp/it's.png")
  eq('undefined is stringified into a segment', CL.toFileUri(undefined), 'file:///undefined')
  eq('a null path is stringified into a segment', CL.toFileUri(null), 'file:///null')
  // encodeURIComponent runs per segment, and the empty segments of "file://"
  // are skipped, so a colon survives as %3A while the slashes collapse.
  eq('a second scheme in the path is partially encoded', CL.toFileUri('file:///a.png'), 'file:///file%3A/a.png')
})

group('parseUriList - text/uri-list to local paths', () => {
  const list = [
    'file:///tmp/a%20b.png',
    '# a comment',
    '',
    'file://localhost/tmp/c.png',
    '/tmp/d.txt',
    'http://x/y',
    'relative/path',
    'file:///tmp/e%%bad.png',
  ].join('\r\n')
  eq('a realistic CRLF list with blanks, comments and a remote uri', CL.parseUriList(list), ['/tmp/a b.png', '/tmp/c.png', '/tmp/d.txt', '/tmp/e%%bad.png'])
  eq('CRLF leaves no carriage return behind', CL.parseUriList('file:///a\r\n/b\r\n').every((p) => p.indexOf('\r') === -1), true)
  eq('blank lines are skipped', CL.parseUriList('/a\n\n\n/b'), ['/a', '/b'])
  eq('comment lines are skipped', CL.parseUriList('# c\n/a\n#d\n/b'), ['/a', '/b'])
  eq('a line with leading whitespace is trimmed', CL.parseUriList('   /tmp/spaced.png  '), ['/tmp/spaced.png'])
  eq('the localhost authority is stripped', CL.parseUriList('file://localhost/tmp/c.png'), ['/tmp/c.png'])
  eq('only a leading localhost is stripped', CL.parseUriList('file:///tmp/localhostx.png'), ['/tmp/localhostx.png'])
  eq('the scheme match is case-insensitive', CL.parseUriList('FILE:///tmp/c.png'), ['/tmp/c.png'])
  // "if (line.indexOf(\"://\") > 0) continue // ftp://... etc are not files
  // (handled as network)" - and a scheme at index 0 has already been consumed
  // by the file:// branch, so only *other* schemes reach that line.
  eq('an http uri is not a file', CL.parseUriList('http://x/y'), [])
  eq('an ftp uri is not a file', CL.parseUriList('ftp://h/a'), [])
  eq('a relative path is not a file', CL.parseUriList('relative/path'), [])
  eq('a windows-style path is not a file', CL.parseUriList('C:\\x\\y.png'), [])
  eq('an empty list', CL.parseUriList(''), [])
  eq('undefined stringifies to nothing', CL.parseUriList(undefined), [])
  // decodeURIComponent is wrapped in a try: a malformed escape leaves the
  // already-stripped path alone instead of losing the line.
  eq('a malformed escape keeps the stripped path', CL.parseUriList('file:///tmp/e%%bad.png'), ['/tmp/e%%bad.png'])
  noThrow('a lone percent never throws', () => CL.parseUriList('file:///tmp/100%.png'))
  eq('a lone percent is left as-is', CL.parseUriList('file:///tmp/100%.png'), ['/tmp/100%.png'])
  eq('a percent-encoded newline is decoded into the path', CL.parseUriList('file:///tmp/a%0Ab.png'), ['/tmp/a\nb.png'])
  eq('a fully-encoded round trip', CL.parseUriList(CL.toFileUri('/tmp/a b/c#d.png')), ['/tmp/a b/c#d.png'])
  eq('a fully-encoded round trip with unicode', CL.parseUriList(CL.toFileUri('/tmp/\u00e9\u00e0/\u4e2d.png')), ['/tmp/\u00e9\u00e0/\u4e2d.png'])
  eq('a literal question mark survives', CL.parseUriList(CL.toFileUri('/tmp/what?.png')), ['/tmp/what?.png'])
  eq('the order of the list is preserved', CL.parseUriList('/c\n/a\n/b'), ['/c', '/a', '/b'])
  eq('duplicates are NOT deduplicated', CL.parseUriList('/a\n/a'), ['/a', '/a'])
})

group('extractNetworkUris - the network half of a mixed paste', () => {
  const text = '# c\nsmb://a/b\n\n  ftp://c/d  \nhttp://e/f\n/tmp/x\nsftp://\n'
  eq('only the network uris, trimmed, comments and blanks dropped', CL.extractNetworkUris(text), ['smb://a/b', 'ftp://c/d', 'sftp://'])
  eq('a bare scheme counts (the host group is "*")', CL.extractNetworkUris('sftp://'), ['sftp://'])
  eq('a web url is not a network uri', CL.extractNetworkUris('https://x/y'), [])
  eq('a local path is not a network uri', CL.extractNetworkUris('/tmp/x'), [])
  eq('an empty string', CL.extractNetworkUris(''), [])
  eq('undefined', CL.extractNetworkUris(undefined), [])
  eq('CRLF is trimmed', CL.extractNetworkUris('smb://a/b\r\nftp://c/d\r\n'), ['smb://a/b', 'ftp://c/d'])
  eq('order is preserved', CL.extractNetworkUris('nfs://z\nsmb://a\ndav://b'), ['nfs://z', 'smb://a', 'dav://b'])
  eq('a comment that looks like a uri is dropped', CL.extractNetworkUris('# smb://commented'), [])
  eq('duplicates are NOT deduplicated', CL.extractNetworkUris('smb://a\nsmb://a'), ['smb://a', 'smb://a'])
})

group('stripFileScheme - the other direction of the scheme', () => {
  eq('a leading file:// is stripped', CL.stripFileScheme('file:///tmp/a'), '/tmp/a')
  eq('the match is case-insensitive but the tail is untouched', CL.stripFileScheme('FILE:///tmp/A'), '/tmp/A')
  eq('a path is unchanged', CL.stripFileScheme('/tmp/a'), '/tmp/a')
  eq('only a *leading* scheme is stripped', CL.stripFileScheme('xfile://a'), 'xfile://a')
  eq('a scheme mid-string is not stripped', CL.stripFileScheme('/tmp/file://a'), '/tmp/file://a')
  eq('an empty string', CL.stripFileScheme(''), '')
  eq('undefined stringifies', CL.stripFileScheme(undefined), 'undefined')
  // The two directions are not inverses: toFileUri percent-encodes, so
  // stripping does not give the path back. A title built from either side
  // shows the encoded form.
  eq('strip after encode is still encoded', CL.stripFileScheme(CL.toFileUri('/tmp/a b.png')), '/tmp/a%20b.png')
  eq('parse then strip is the identity', CL.stripFileScheme(CL.parseUriList(CL.toFileUri('/tmp/a b.png'))[0]), '/tmp/a b.png')
  eq('a newline in a path is not touched', CL.stripFileScheme('file:///a\nb'), '/a\nb')
  eq('a newline in a path is not sanitised', CL.stripFileScheme('/a\nb'), '/a\nb')
})

// ===========================================================================
section('ClipboardLib - stdout parsers')
// ===========================================================================

group('parseTypeList - wl-paste --list-types', () => {
  eq('a realistic three-type list', CL.parseTypeList('text/plain\ntext/uri-list\nimage/png\n'),
    { types: ['text/plain', 'text/uri-list', 'image/png'], hasUri: true, hasImage: true, imageType: 'image/png' })
  // "hasUri wins over an embedded image, exactly as the read path orders them."
  eq('uri-list is recorded even when an image is present', CL.parseTypeList('image/png\ntext/uri-list').hasUri, true)
  eq('the first image type is kept', CL.parseTypeList('text/plain\nimage/jpeg\nimage/png').imageType, 'image/jpeg')
  eq('a text/plain only paste', CL.parseTypeList('text/plain\n'), { types: ['text/plain'], hasUri: false, hasImage: false, imageType: '' })
  eq('an empty list', CL.parseTypeList(''), { types: [], hasUri: false, hasImage: false, imageType: '' })
  eq('whitespace-only lines are dropped', CL.parseTypeList('   \n  \n'), { types: [], hasUri: false, hasImage: false, imageType: '' })
  eq('lines are trimmed', CL.parseTypeList('  text/plain  \n text/html \n'), { types: ['text/plain', 'text/html'], hasUri: false, hasImage: false, imageType: '' })
  eq('undefined', CL.parseTypeList(undefined), { types: [], hasUri: false, hasImage: false, imageType: '' })
  // The image test lowercases but stores the ORIGINAL string, so the returned
  // imageType keeps whatever case the compositor reported.
  eq('the returned imageType keeps the original case', CL.parseTypeList('IMAGE/JPEG'), { types: ['IMAGE/JPEG'], hasUri: false, hasImage: true, imageType: 'IMAGE/JPEG' })
  eq('a uri-list substring anywhere counts', CL.parseTypeList('x-special;x-hint=text/uri-list').hasUri, true)
  eq('a text/uri-list;charset also counts', CL.parseTypeList('text/uri-list;charset=utf-8').hasUri, true)
  eq('an image/ that is not at the start of the type is not an image type', CL.parseTypeList('text/x-image/png').hasImage, false)
  eq('a mid-list image is found', CL.parseTypeList('text/plain\ntext/html\nimage/webp').imageType, 'image/webp')
  eq('the types array keeps the duplicates', CL.parseTypeList('text/plain\ntext/plain').types, ['text/plain', 'text/plain'])
})

group('parseSnapshotOutput - "<size>\\n<sha>  <path>"', () => {
  eq('a real snapshot line pair', CL.parseSnapshotOutput('1234\nda39a3ee5e6b4b0d3255bfef95601890afd80709  /tmp/x.png'), { size: 1234, sha: 'da39a3ee5e6b4b0d3255bfef95601890afd80709' })
  eq('the sha is the first whitespace-delimited field', CL.parseSnapshotOutput('1\nabc   /p\n').sha, 'abc')
  eq('leading and trailing blank lines are ignored', CL.parseSnapshotOutput('\n 99 \nabcdef  /p\n'), { size: 99, sha: 'abcdef' })
  eq('the EMPTY marker means no snapshot', CL.parseSnapshotOutput('EMPTY'), null)
  eq('empty output', CL.parseSnapshotOutput(''), null)
  eq('a zero size', CL.parseSnapshotOutput('0\nabc'), null)
  eq('a missing digest', CL.parseSnapshotOutput('12'), null)
  eq('a digest with no size', CL.parseSnapshotOutput('\nabc'), null)
  eq('a negative size', CL.parseSnapshotOutput('-5\nabc'), null)
  eq('whitespace only', CL.parseSnapshotOutput('   \n  \n'), null)
  // "A size that is not a number at all is not a non-positive one, so it
  // passes here exactly as it did when the arithmetic was inline" - the
  // entry simply never matches an existing sha+size pair.
  is('a non-numeric size still returns an object', CL.parseSnapshotOutput('big\nabc'), (v) => v !== null && v.sha === 'abc', 'returned with a NaN size')
  eq('and that size is NaN', Number.isNaN(CL.parseSnapshotOutput('big\nabc').size), true)
  noThrow('undefined', () => CL.parseSnapshotOutput(undefined))
  eq('undefined is empty', CL.parseSnapshotOutput(undefined), null)
  eq('a size with a trailing unit parses the leading number', CL.parseSnapshotOutput('4096 bytes\nabc'), { size: 4096, sha: 'abc' })
  eq('extra lines after the digest are ignored', CL.parseSnapshotOutput('10\nabc\nnoise'), { size: 10, sha: 'abc' })
})

group('parseDimOutput - identify\'s "WxH"', () => {
  eq('a real dimension', CL.parseDimOutput('1920 1080'), { w: 1920, h: 1080 })
  eq('a newline separator works too', CL.parseDimOutput('10\n20'), { w: 10, h: 20 })
  eq('tabs work', CL.parseDimOutput('640\t480'), { w: 640, h: 480 })
  eq('extra columns are ignored', CL.parseDimOutput('800 600 72'), { w: 800, h: 600 })
  eq('a leading dash is read as a number prefix', CL.parseDimOutput('-1 10'), null)
  eq('a single value is not a dimension', CL.parseDimOutput('1920'), null)
  eq('a zero width', CL.parseDimOutput('0 100'), null)
  eq('a zero height', CL.parseDimOutput('100 0'), null)
  eq('both zero', CL.parseDimOutput('0 0'), null)
  eq('non-numeric', CL.parseDimOutput('x y'), null)
  eq('empty', CL.parseDimOutput(''), null)
  eq('whitespace only', CL.parseDimOutput('   \n  '), null)
  eq('undefined', CL.parseDimOutput(undefined), null)
  // An ImageMagick error string carries no digits at the front, so it is
  // rejected rather than written as a zero.
  eq('an error message', CL.parseDimOutput('identify: unable to open image'), null)
  noThrow('a very long junk line', () => CL.parseDimOutput('x'.repeat(5000)))
  noThrow('null', () => CL.parseDimOutput(null))
  eq('null is empty', CL.parseDimOutput(null), null)
})

group('parseTextProbeOutput - "<mime>\\n__HEAD__\\n<head>"', () => {
  eq('a real probe', CL.parseTextProbeOutput('text/plain; charset=utf-8\n__HEAD__\nline1\nline2\n'), { mime: 'text/plain; charset=utf-8', body: 'line1\nline2\n' })
  eq('the body keeps its trailing newline', CL.parseTextProbeOutput('a/b\n__HEAD__\nx\n').body, 'x\n')
  eq('an empty head', CL.parseTextProbeOutput('text/plain\n__HEAD__\n'), { mime: 'text/plain', body: '' })
  // "A child that never reached the file emits the binary marker and an empty
  // head" - the marker is parsed as the mime, and the empty body is what
  // makes the caller fall back to the binary verdict.
  eq('the unreadable branch', CL.parseTextProbeOutput('binary\n__HEAD__\n'), { mime: 'binary', body: '' })
  eq('a missing separator makes the whole output the mime', CL.parseTextProbeOutput('just a mime'), { mime: 'just a mime', body: '' })
  eq('empty output', CL.parseTextProbeOutput(''), { mime: '', body: '' })
  eq('undefined is stringified', CL.parseTextProbeOutput(undefined), { mime: 'undefined', body: '' })
  // Only the FIRST separator splits, so a __HEAD__ inside the body is data.
  eq('a second separator stays in the body', CL.parseTextProbeOutput('a/b\n__HEAD__\n__HEAD__\nrest').body, '__HEAD__\nrest')
  eq('a separator spelled with a trailing space is not the separator', CL.parseTextProbeOutput('a/b\n__HEAD__ x').mime, 'a/b\n__HEAD__ x')
  eq('and that case leaves an empty body', CL.parseTextProbeOutput('a/b\n__HEAD__ x').body, '')
  eq('a body that starts with a space keeps it', CL.parseTextProbeOutput('a/b\n__HEAD__\n x').body, ' x')
  eq('a leading newline before the mime is trimmed', CL.parseTextProbeOutput('\n\ntext/plain\n__HEAD__\n').mime, 'text/plain')
  eq('a mime with a charset keeps it verbatim', CL.parseTextProbeOutput('text/plain; charset=us-ascii\n__HEAD__\n').mime, 'text/plain; charset=us-ascii')
  eq('a body with a NUL is preserved', CL.parseTextProbeOutput('a/b\n__HEAD__\nxSy').body.length, 3)
})

group('parseFileInfoReport - the current DIR/FILE/MISSING protocol', () => {
  eq('a directory chunk', CL.parseFileInfoReport('DIR /a/b\n10\n20\nENDDIR', true), { folders: 1, files: 0, innerFiles: 2, bytes: 30 })
  eq('a file chunk', CL.parseFileInfoReport('FILE /a/b\n30\nENDFILE', true), { folders: 0, files: 1, innerFiles: 0, bytes: 30 })
  eq('a file with no size line', CL.parseFileInfoReport('FILE /a/b\nENDFILE', true), { folders: 0, files: 1, innerFiles: 0, bytes: 0 })
  eq('a missing path names nothing', CL.parseFileInfoReport('MISSING /a/b\nENDMISSING', true), null)
  eq('empty output', CL.parseFileInfoReport('', true), null)
  eq('whitespace-only output', CL.parseFileInfoReport('   \n  ', true), null)
  eq('two chunks in one dump', CL.parseFileInfoReport('DIR /a\n1\nENDDIR\nFILE /b\n2\nENDFILE', true), { folders: 1, files: 1, innerFiles: 1, bytes: 3 })
  eq('a bare DIR with no path still opens a chunk', CL.parseFileInfoReport('DIR\n5\nENDDIR', true), { folders: 1, files: 0, innerFiles: 1, bytes: 5 })
  eq('an awk-summed directory chunk', CL.parseFileInfoReport('DIR /a/b\n2 30\nENDDIR', true), { folders: 1, files: 0, innerFiles: 2, bytes: 30 })
  eq('a capped walk leaves an empty directory chunk', CL.parseFileInfoReport('DIR /a/b\nTOOBIG\nENDDIR', true), { folders: 1, files: 0, innerFiles: 0, bytes: 0 })
  eq('a bare FILE with no path', CL.parseFileInfoReport('FILE\n5\nENDFILE', true), { folders: 0, files: 1, innerFiles: 0, bytes: 5 })
  eq('non-numeric lines inside a chunk are ignored', CL.parseFileInfoReport('DIR /a\n10\njunk\n20\nENDDIR', true), { folders: 1, files: 0, innerFiles: 2, bytes: 30 })
  eq('a chunk that is never closed is still flushed', CL.parseFileInfoReport('DIR /a\n10\n20', true), { folders: 1, files: 0, innerFiles: 2, bytes: 30 })
  eq('a MISSING chunk does not flush a previous one twice', CL.parseFileInfoReport('FILE /a\n1\nENDFILE\nMISSING /b\nENDMISSING', true), { folders: 0, files: 1, innerFiles: 0, bytes: 1 })
  eq('a size of 0 in a file chunk still counts the file', CL.parseFileInfoReport('FILE /a\n0\nENDFILE', true), { folders: 0, files: 1, innerFiles: 0, bytes: 0 })
  eq('a path with spaces is kept in the marker line, not the count', CL.parseFileInfoReport('DIR /a/my dir\n7\nENDDIR', true), { folders: 1, files: 0, innerFiles: 1, bytes: 7 })
})

group('parseFileInfoReport - old "d"/"f" lines are not a protocol', () => {
  eq('a d/f dump names nothing', CL.parseFileInfoReport('d 3 100\nf 20\nf 5', true), null)
  eq('an f only dump names nothing', CL.parseFileInfoReport('f 20', true), null)
})

group('parseFileInfoReport - the unlabelled single-path fallback', () => {
  // "an unlabelled single-path dump is read as a directory only when the row
  // it would patch is still in history" - entryKnown is that one piece of
  // controller state.
  eq('one size, known row -> a file', CL.parseFileInfoReport('42', true), { folders: 0, files: 1, innerFiles: 0, bytes: 42 })
  eq('one size, unknown row -> still a file', CL.parseFileInfoReport('42', false), { folders: 0, files: 1, innerFiles: 0, bytes: 42 })
  eq('several sizes, known row -> a directory', CL.parseFileInfoReport('10\n20\n30', true), { folders: 1, files: 0, innerFiles: 3, bytes: 60 })
  eq('several sizes, unknown row -> a file with the total', CL.parseFileInfoReport('10\n20\n30', false), { folders: 0, files: 1, innerFiles: 0, bytes: 60 })
  // The guard is `!body.includes("DIR") && !body.includes("FILE")`, which is
  // case-SENSITIVE, so a lowercase mention does not mark the run as labelled.
  eq('a lowercase "filename" does not block the fallback', CL.parseFileInfoReport('10\n20\nfilename', false), { folders: 0, files: 1, innerFiles: 0, bytes: 30 })
  // The bare token also opens a chunk, so the run is read as an empty chunk
  // rather than as unlabelled sizes: a labelled-but-empty report.
  eq('an uppercase FILE token opens an empty chunk', CL.parseFileInfoReport('10\n20\nFILE', true), { folders: 0, files: 1, innerFiles: 0, bytes: 0 })
  eq('an uppercase DIR token opens an empty chunk', CL.parseFileInfoReport('10\n20\nDIR', true), { folders: 1, files: 0, innerFiles: 0, bytes: 0 })
  eq('and a labelled run never falls through to the unlabelled branch', CL.parseFileInfoReport('10\n20\nFILE', false).files, 1)
  eq('a non-numeric unlabelled run names nothing', CL.parseFileInfoReport('junk', true), null)
  // Only the numeric lines count, so a partially numeric run of more than one
  // size is still "a directory" for a known row.
  eq('a partially numeric run counts only the numbers', CL.parseFileInfoReport('10\njunk\n20', true), { folders: 1, files: 0, innerFiles: 2, bytes: 30 })
  eq('a zero size is still a file', CL.parseFileInfoReport('0', true), { folders: 0, files: 1, innerFiles: 0, bytes: 0 })
  eq('a two-size run for a known row', CL.parseFileInfoReport('1\n2', true), { folders: 1, files: 0, innerFiles: 2, bytes: 3 })
  eq('entryKnown undefined behaves as false', CL.parseFileInfoReport('1\n2', undefined), { folders: 0, files: 1, innerFiles: 0, bytes: 3 })
})

group('parseHistoryDocument - file shape', () => {
  eq('an object keyed entries', CL.parseHistoryDocument('{"entries":[{"id":"a"}]}'), { entries: [{ id: 'a' }], key: '' })
  eq('an object keyed history', CL.parseHistoryDocument('{"history":[{"id":"h"}]}'), { entries: [{ id: 'h' }], key: '' })
  eq('an object keyed data', CL.parseHistoryDocument('{"data":[{"id":"d"}]}'), { entries: [{ id: 'd' }], key: '' })
  eq('an object carrying its own key', CL.parseHistoryDocument('{"entries":[{"id":"a"}],"key":"k2"}'), { entries: [{ id: 'a' }], key: 'k2' })
  eq('a key with no entries array', CL.parseHistoryDocument('{"key":"k3"}'), { entries: [], key: 'k3' })
  eq('a non-string key is ignored', CL.parseHistoryDocument('{"key":123}').key, '')
  eq('entries wins over history', CL.parseHistoryDocument('{"entries":[{"id":"e"}],"history":[{"id":"h"}]}').entries, [{ id: 'e' }])
  eq('history wins over data', CL.parseHistoryDocument('{"history":[{"id":"h"}],"data":[{"id":"d"}]}').entries, [{ id: 'h' }])
  eq('an object with no known array key', CL.parseHistoryDocument('{"other":1}'), { entries: [], key: '' })
  eq('invalid JSON', CL.parseHistoryDocument('not json'), { entries: [], key: '' })
  eq('a truncated document', CL.parseHistoryDocument('{"entries":[{"id":'), { entries: [], key: '' })
  eq('an empty document', CL.parseHistoryDocument(''), { entries: [], key: '' })
  eq('undefined', CL.parseHistoryDocument(undefined), { entries: [], key: '' })
  eq('a bare array with no key', CL.parseHistoryDocument('[]'), { entries: [], key: '' })
  eq('JSON null', CL.parseHistoryDocument('null'), { entries: [], key: '' })
  eq('a JSON scalar', CL.parseHistoryDocument('42'), { entries: [], key: '' })
  eq('an empty entries array survives', CL.parseHistoryDocument('{"entries":[]}').entries, [])
  eq('a non-array entries value is ignored', CL.parseHistoryDocument('{"entries":{"a":1}}'), { entries: [], key: '' })
  eq('whitespace around the body is tolerated', CL.parseHistoryDocument('  [ ]  ').entries, [])
  noThrow('a document with a huge array', () => CL.parseHistoryDocument(JSON.stringify(new Array(500).fill({ id: 'a' }))))
  eq('a huge array is returned whole', CL.parseHistoryDocument(JSON.stringify(new Array(500).fill({ id: 'a' }))).entries.length, 500)
  eq('a separator tail is not parsed as a key', CL.parseHistoryDocument('[{"id":"a"}]__CLIP_KEY_SEP__k1'), { entries: [], key: '' })
})

section('ClipboardLib - media info')
// ===========================================================================

group('parseMediaInfo - a real audio dump', () => {
  const mi = CL.parseMediaInfo(MI_AUDIO)
  eq('the format comes from the General section', mi.format, 'FLAC')
  eq('the duration is kept verbatim for the formatter', mi.duration, '2 min 38 s')
  eq('the audio kv block is carried whole', mi.audio, { Format: 'FLAC', 'Channel(s)': '2 channels', 'Sampling rate': '44.1 KHz', 'Bit depth': '16 bits' })
  eq('no video block for an audio file', mi.video, undefined)
  eq('Complete name is not a card field', mi.track, undefined)
  eq('File size is not a card field', mi.fileSize, undefined)
  eq('a track name is picked up when present', CL.parseMediaInfo('General\nTrack name : Song\nDuration : 1 s\n').track, 'Song')
  eq('a Movie key is the fourth-choice track source', CL.parseMediaInfo('General\nMovie : M\nDuration : 1 s\n').track, 'M')
  eq('a Movie name key', CL.parseMediaInfo('General\nMovie name : M\nDuration : 1 s\n').track, 'M')
  eq('Performer is the first artist choice', CL.parseMediaInfo('General\nPerformer : P\nArtist : A\nDuration : 1 s\n').artist, 'P')
  eq('Artist is the fallback', CL.parseMediaInfo('General\nArtist : A\nDuration : 1 s\n').artist, 'A')
  eq('an album', CL.parseMediaInfo('General\nAlbum : R\nDuration : 1 s\n').album, 'R')
  eq('a wrapped value is rejoined onto its key', CL.parseMediaInfo('General\nTitle : long\n  title here\nDuration : 1 s\n').track, 'long title here')
  eq('a value with internal runs of spaces is collapsed', CL.parseMediaInfo('General\nTitle : a   b\nDuration : 1 s\n').track, 'a b')
  eq('a continuation before any kv is ignored', CL.parseMediaInfo('General\n  orphan\nDuration : 1 s\n').duration, '1 s')
})

group('parseMediaInfo - a real video dump', () => {
  const mi = CL.parseMediaInfo(MI_VIDEO)
  eq('format', mi.format, 'Matroska')
  eq('duration', mi.duration, '1 h 2 min')
  eq('the video kv block is carried whole', mi.video, { Format: 'AVC', Width: '1 920 pixels', Height: '1 080 pixels', 'Frame rate': '23.976 FPS' })
  eq('the audio kv block is carried too', mi.audio, { Format: 'AAC', 'Channel(s)': '6 channels' })
  // mediainfo groups 1000+ values with a thin space, which is kept verbatim -
  // the card renders "1 920x1 080" and the parser does not normalise it.
  eq('mediainfo groups 1000+ values with a thin space, which is kept', mi.video.Width, '1 920 pixels')
})

group('parseMediaInfo - the validity gate and malformed shapes', () => {
  // "The one hard validity gate: a parsed media file always reports Duration."
  eq('a General section with no Duration is rejected', CL.parseMediaInfo('General\nFormat : X\nFile size : 1 KiB\n'), null)
  eq('an Audio section with no General is rejected', CL.parseMediaInfo('Audio\nFormat : FLAC\n'), null)
  eq('empty output', CL.parseMediaInfo(''), null)
  eq('whitespace only', CL.parseMediaInfo('   \n\n  '), null)
  eq('undefined', CL.parseMediaInfo(undefined), null)
  eq('a bare error message', CL.parseMediaInfo('mediainfo: cannot open the file'), null)
  // A kv line before any section header has no owner, so it is dropped and
  // the dump falls to the same null verdict.
  eq('an orphan kv line before a section is dropped', CL.parseMediaInfo('Duration : 5 s\nGeneral\nFormat : MP3\n'), null)
  eq('a duration alone is enough', CL.parseMediaInfo('General\nDuration : 10 s\n'), { duration: '10 s' })
  eq('trailing whitespace on a line is trimmed', CL.parseMediaInfo('General   \nDuration : 10 s   \n').duration, '10 s')
  // "section headers sit at column 0" - an indented one is read as a
  // continuation line, so the dump has no section and is rejected.
  eq('an indented section header is a continuation, not a section', CL.parseMediaInfo('  General  \nDuration : 1 s\n'), null)
  eq('a trailing-space header is fine when it starts at column 0', CL.parseMediaInfo('General   \nDuration : 1 s\n').duration, '1 s')
  eq('a repeated key keeps the last value', CL.parseMediaInfo('General\nDuration : 1 s\nDuration : 2 s\n').duration, '2 s')
  eq('only the first General section is used', Object.keys(CL.parseMediaInfo('General\nDuration : 1 s\n\nGeneral\nDuration : 9 s\n')).length, 1)
  eq('a second Video section is ignored', CL.parseMediaInfo(MI_VIDEO + '\n\nVideo\nFormat : VP9\nWidth : 1 pixels\nHeight : 1 pixels\n').video.Format, 'AVC')
  eq('a second Audio section is ignored', CL.parseMediaInfo(MI_VIDEO + '\n\nAudio\nFormat : FLAC\n').audio.Format, 'AAC')
  // The " : " separator is what makes a line a kv line, so a key with no
  // space before the colon becomes a section header instead and the dump
  // then has no Duration at all.
  eq('a tight colon becomes a section header, so the dump is rejected', CL.parseMediaInfo('General\nDuration:1 s\n'), null)
  noThrow('a dump with CRLF line endings', () => CL.parseMediaInfo('General\r\nDuration : 1 s\r\n'))
  eq('CRLF still parses', CL.parseMediaInfo('General\r\nDuration : 1 s\r\n').duration, '1 s')
  noThrow('a very long dump', () => CL.parseMediaInfo(new Array(5000).fill('k : v').join('\n')))
  eq('a very long dump is still rejected without a General', CL.parseMediaInfo(new Array(5000).fill('k : v').join('\n')), null)
  noThrow('null', () => CL.parseMediaInfo(null))
  eq('null is empty', CL.parseMediaInfo(null), null)
})

group('formatMediaDuration', () => {
  eq('sub-second precision survives below 10 s', CL.formatMediaDuration('2 s 38 ms'), '0:02.038')
  eq('minutes and seconds', CL.formatMediaDuration('12 min 3 s'), '12:03')
  eq('hours render as H:MM:SS', CL.formatMediaDuration('1 h 2 min'), '1:02:00')
  eq('hours plus seconds', CL.formatMediaDuration('1 h 0 min 5 s'), '1:00:05')
  eq('milliseconds only', CL.formatMediaDuration('500 ms'), '0:00.500')
  eq('milliseconds below 10 are zero-padded to three', CL.formatMediaDuration('5 ms'), '0:00.005')
  eq('milliseconds above 99 are not padded', CL.formatMediaDuration('999 ms'), '0:00.999')
  // "Sub-second precision only survives below 10 s; longer media round down."
  eq('at 10 s the fraction is dropped', CL.formatMediaDuration('10 s'), '0:10')
  eq('at 9 s the fraction survives', CL.formatMediaDuration('9 s 999 ms'), '0:09.999')
  eq('a fractional second rounds down below 10 s', CL.formatMediaDuration('59.9 s'), '0:59')
  eq('minutes only', CL.formatMediaDuration('3 min'), '3:00')
  eq('an exact minute', CL.formatMediaDuration('2 min 0 s'), '2:00')
  eq('zero seconds', CL.formatMediaDuration('0 s'), '')
  eq('a zero duration with hours', CL.formatMediaDuration('0 h 0 min 0 s'), '')
  eq('unparseable text', CL.formatMediaDuration('abc'), '')
  eq('an empty string', CL.formatMediaDuration(''), '')
  eq('undefined', CL.formatMediaDuration(undefined), '')
  eq('a bare number is not a duration', CL.formatMediaDuration('42'), '')
  // A zero millisecond tail still reports the second, so the sub-second
  // branch is only taken when there is a real fraction.
  eq('an explicit zero ms keeps the second only', CL.formatMediaDuration('1 min 0 s 0 ms'), '1:00')
  eq('a 9-hour file', CL.formatMediaDuration('9 h 59 min 59 s'), '9:59:59')
  eq('exactly one hour', CL.formatMediaDuration('1 h'), '1:00:00')
  eq('the minute is zero-padded in the hour form', CL.formatMediaDuration('2 h 3 min 4 s'), '2:03:04')
  eq('the hour is not zero-padded', CL.formatMediaDuration('2 h 3 min 4 s').indexOf('0'), 2)
  is('the seconds are always padded', [1, 2, 3, 4, 5].map(() => CL.formatMediaDuration('1 min 5 s').endsWith('05')), (v) => v.every(Boolean), 'every one ends in 05')
  // The regexes scan the WHOLE string, so an unrelated "s" earlier in it
  // would be picked up first; the real dump has one unit per number.
  eq('units may appear in any order', CL.formatMediaDuration('3 min 1 h'), '1:03:00')
  noThrow('null', () => CL.formatMediaDuration(null))
  eq('null is the empty string', CL.formatMediaDuration(null), '')
})

group('mediaInfoRows - the preview card rows', () => {
  eq('an audio file yields a duration row and an audio row', CL.mediaInfoRows(CL.parseMediaInfo(MI_AUDIO)), [
    { icon: 'hourglass', label: 'Duration', value: '2:38' },
    { icon: 'speaker', label: 'Audio', value: 'FLAC - 2 channels - 44.1 KHz' },
  ])
  eq('a video file yields a video row, not an audio row', CL.mediaInfoRows(CL.parseMediaInfo(MI_VIDEO)), [
    { icon: 'hourglass', label: 'Duration', value: '1:02:00' },
    { icon: 'recording', label: 'Video', value: 'AVC - 1 920x1 080 - 23.976 FPS' },
  ])
  eq('track/artist/album rows come first, in that order', CL.mediaInfoRows({ track: 'T', artist: 'A', album: 'B', duration: '1 min 0 s' }), [
    { icon: 'music-track', label: 'Track', value: 'T' },
    { icon: 'music-artist', label: 'Artist', value: 'A' },
    { icon: 'music-album', label: 'Album', value: 'B' },
    { icon: 'hourglass', label: 'Duration', value: '1:00' },
  ])
  // "Absent metadata omits the row, never fakes it."
  eq('no metadata means no rows but the duration', CL.mediaInfoRows({ duration: '5 s' }), [{ icon: 'hourglass', label: 'Duration', value: '0:05' }])
  eq('an unparseable duration omits the row', CL.mediaInfoRows({ duration: 'nope' }), [])
  eq('an empty payload', CL.mediaInfoRows({}), [])
  // A video row with only a codec still appears.
  // The video branch is gated on `v["Width"] !== undefined`, so a Video
  // section with only a codec produces no row at all and the audio branch is
  // not tried either.
  eq('a video block with only a format produces no row', CL.mediaInfoRows({ video: { Format: 'VP9' } }), [])
  eq('a video row with dimensions and no frame rate', CL.mediaInfoRows({ video: { Format: 'AVC', Width: '1920 pixels', Height: '1080 pixels' } })[0].value, 'AVC - 1920x1080')
  eq('a frame rate is appended after the dimensions', CL.mediaInfoRows({ video: { Format: 'AVC', Width: '1 pixel', Height: '1 pixel', 'Frame rate': '30 FPS' } })[0].value, 'AVC - 1 pixelx1 pixel - 30 FPS')
  eq('trailing zeros are trimmed from the frame rate', CL.mediaInfoRows({ video: { Format: 'AVC', Width: '1 pixel', Height: '1 pixel', 'Frame rate': '30.000 FPS' } })[0].value, 'AVC - 1 pixelx1 pixel - 30 FPS')
  eq('a frame rate with no trailing zeros is untouched', CL.mediaInfoRows({ video: { Format: 'AVC', Width: '1 pixel', Height: '1 pixel', 'Frame rate': '23.976 FPS' } })[0].value, 'AVC - 1 pixelx1 pixel - 23.976 FPS')
  eq('a frame rate without a Width is dropped with the whole row', CL.mediaInfoRows({ video: { Format: 'AVC', 'Frame rate': '30 FPS' } }), [])
  eq('the pixels suffix is stripped from both dimensions', CL.mediaInfoRows({ video: { Width: '100 pixels', Height: '50 pixels' } })[0].value, '100x50')
  // The video branch is gated on the Width KEY, not on the rendered value,
  // so a Width with no Height still takes it.
  eq('a Width with no Height still takes the video branch', CL.mediaInfoRows({ video: { Width: '10 pixels' } })[0].label, 'Video')
  // "w !== \"\" && h !== \"\"" is satisfied by String(undefined), so a Height
  // that mediainfo did not report renders as the literal "undefined". Real
  // dumps always carry both, so this only shows on a truncated section.
  eq('a missing Height renders as the word undefined', CL.mediaInfoRows({ video: { Width: '10 pixels' } })[0].value, '10xundefined')
  eq('a Height with no Width does not', CL.mediaInfoRows({ video: { Height: '10 pixels' } }), [])
  eq('an audio row with a format only', CL.mediaInfoRows({ audio: { Format: 'MP3' } }), [{ icon: 'speaker', label: 'Audio', value: 'MP3' }])
  eq('an audio row with channels and rate', CL.mediaInfoRows({ audio: { Format: 'FLAC', 'Channel(s)': '2 channels', 'Sampling rate': '48.0 KHz' } })[0].value, 'FLAC - 2 channels - 48.0 KHz')
  eq('an audio kv with no Format takes no codec row at all', CL.mediaInfoRows({ audio: { 'Channel(s)': '2 channels' } }), [])
  eq('both blocks present still yield exactly one codec row', CL.mediaInfoRows({ audio: { Format: 'AAC' }, video: { Format: 'AVC', Width: '1 pixel', Height: '1 pixel' } }).filter((r) => r.label === 'Audio' || r.label === 'Video').length, 1)
  eq('the codec row order is Video before Audio', CL.mediaInfoRows({ audio: { Format: 'AAC' }, video: { Format: 'AVC', Width: '1 pixel', Height: '1 pixel' } })[0].label, 'Video')
  eq('a channel count with no format is dropped from the row', CL.mediaInfoRows({ audio: { Format: 'MP3', 'Channel(s)': '' } })[0].value, 'MP3')
  // A null payload is not in the documented input set and throws; the empty
  // object is the floor the card actually passes.
  throws('a null payload throws', () => CL.mediaInfoRows(null), /audio/)
  throws('an undefined payload throws', () => CL.mediaInfoRows(undefined), /audio/)
})

group('isMediaPath / mediaBaseName / buildMediaSummary', () => {
  eq('an mp3', CL.isMediaPath('a.mp3'), true)
  eq('an uppercase mp3', CL.isMediaPath('a.MP3'), true)
  eq('an mp4', CL.isMediaPath('a.mp4'), true)
  eq('an xm module', CL.isMediaPath('a.xm'), true)
  eq('a woff2 is not media', CL.isMediaPath('a.woff2'), false)
  eq('a png is not media', CL.isMediaPath('a.png'), false)
  eq('a pdf is not media', CL.isMediaPath('a.pdf'), false)
  eq('no extension', CL.isMediaPath('a'), false)
  eq('undefined', CL.isMediaPath(undefined), false)
  eq('the basename', CL.mediaBaseName('/a/b/c.mp3'), 'c.mp3')
  eq('a bare name is already the basename', CL.mediaBaseName('c.mp3'), 'c.mp3')
  eq('a trailing slash yields the empty string', CL.mediaBaseName('/a/b/'), '')
  eq('the root', CL.mediaBaseName('/'), '')
  eq('undefined is stringified', CL.mediaBaseName(undefined), 'undefined')
  // "basename + extension class, same copy rules as every lib builder -
  // descriptive, never tool- or error-flavored."
  eq('a video summary', CL.buildMediaSummary('/a/b/c.MP4'), { title: 'c.MP4', icon: 'file', video: true, ext: 'mp4' })
  eq('an audio summary', CL.buildMediaSummary('/a/b/c.flac'), { title: 'c.flac', icon: 'file-music', video: false, ext: 'flac' })
  eq('the basename keeps its original case', CL.buildMediaSummary('/a/B.MP3').title, 'B.MP3')
  eq('the ext class is lowercased by extOf', CL.buildMediaSummary('/a/B.MP3').ext, 'mp3')
  eq('an unknown extension is still classed as audio', CL.buildMediaSummary('/a/b.c').video, false)
  eq('no path at all', CL.buildMediaSummary(''), { title: '', icon: 'file-music', video: false, ext: '' })
  eq('undefined is stringified into the title', CL.buildMediaSummary(undefined), { title: 'undefined', icon: 'file-music', video: false, ext: '' })
  eq('a dotfile basename is empty', CL.buildMediaSummary('/a/.mp3'), { title: '.mp3', icon: 'file-music', video: false, ext: '' })
})

// ===========================================================================
section('ClipboardLib - presentation')
// ===========================================================================

group('pad2 / trim1 / formatSize', () => {
  eq('pad 0', CL.pad2(0), '00')
  eq('pad 9', CL.pad2(9), '09')
  eq('10 is already two digits', CL.pad2(10), '10')
  eq('100 is not truncated', CL.pad2(100), '100')
  // The implementation is `(n < 10 ? "0" : "") + n`, which string-concatenates
  // rather than formatting, so a negative keeps the pad. Pinned because the
  // only caller passes a Date component, which is never negative.
  eq('a negative number keeps the pad', CL.pad2(-3), '0-3')
  eq('trim1 drops a round tenth', CL.trim1(1024), '1024')
  eq('trim1 keeps a real tenth', CL.trim1(1.5), '1.5')
  eq('trim1 rounds to one place then drops a zero tenth', CL.trim1(1.04), '1')
  eq('trim1 of 1.05 renders as 1.1', CL.trim1(1.05), '1.1')
  eq('a whole number', CL.trim1(3), '3')
  eq('bytes below 1 KiB', CL.formatSize(1), '1 B')
  eq('the last byte below 1 KiB', CL.formatSize(1023), '1023 B')
  eq('exactly 1 KiB', CL.formatSize(1024), '1 KB')
  eq('a fractional byte count stays in bytes', CL.formatSize(1023.5), '1023.5 B')
  eq('a numeric string is coerced', CL.formatSize('2048'), '2 KB')
  eq('exactly 1 MiB', CL.formatSize(1024 * 1024), '1 MB')
  eq('exactly 1 GiB', CL.formatSize(1024 * 1024 * 1024), '1 GB')
  eq('3 GiB', CL.formatSize(3 * 1024 * 1024 * 1024), '3 GB')
  eq('5000 bytes is 4.9 KB', CL.formatSize(5000), '4.9 KB')
  eq('zero has no size copy', CL.formatSize(0), '')
  eq('a negative size has no size copy', CL.formatSize(-5), '')
  eq('NaN has no size copy', CL.formatSize(NaN), '')
  eq('a non-numeric string has no size copy', CL.formatSize('abc'), '')
  eq('undefined has no size copy', CL.formatSize(undefined), '')
  eq('1.5 bytes', CL.formatSize(1.5), '1.5 B')
  eq('null has no size copy', CL.formatSize(null), '')
  // Every non-byte bucket is one decimal, which is the "1024.0 KB -> 1024 KB"
  // rule trim1 exists for.
  eq('the KB bucket is one decimal', CL.formatSize(1234567), '1.2 MB')
  eq('a 1.5 GB file', CL.formatSize(1.5 * 1024 * 1024 * 1024), '1.5 GB')
  eq('a 1.05 GB file rounds to one decimal', CL.formatSize(1.05 * 1024 * 1024 * 1024), '1.1 GB')
})

group('formatTime - same day, then the day rides along', () => {
  const ref = new Date(TS).getTime()
  const sameDay = CL.formatTime(TS - 3600 * 1000, ref)
  const otherDay = CL.formatTime(TS, ref + 400 * 24 * 3600 * 1000)
  match('a same-day copy is just the time', sameDay, /^\d{1,2}:\d{2}/)
  notMatch('a same-day copy carries no date', sameDay, /[A-Za-z]{3}/)
  match('a different-day copy carries a short month and the day', otherDay, /^[A-Za-z]{3,}\s+\d{1,2}\s/)
  // The clock time is rendered from `ts` alone - `now` only decides whether
  // the day rides along - so the same instant prints the same clock time in
  // both branches.
  eq('the time part is identical either way', otherDay.match(/\d{1,2}:\d{2}/)[0], CL.formatTime(TS, ref).match(/\d{1,2}:\d{2}/)[0])
  match('an injected now makes the result deterministic', CL.formatTime(TS, TS), /^\d{1,2}:\d{2}/)
  match('an explicit now far away still prints a clock time', otherDay, /\d{1,2}:\d{2}/)
  match('an omitted now still prints a clock time', CL.formatTime(TS), /\d{1,2}:\d{2}/)
  noThrow('a zero timestamp', () => CL.formatTime(0, TS))
  noThrow('a NaN timestamp', () => CL.formatTime(NaN, TS))
  eq('a NaN timestamp is still a string', typeof CL.formatTime(NaN, TS), 'string')
  noThrow('an invalid now', () => CL.formatTime(TS, NaN))
  eq('an invalid now is not the same day', CL.formatTime(TS, NaN) !== CL.formatTime(TS, TS), true)
  noThrow('undefined for both', () => CL.formatTime(undefined, undefined))
  // The locale call is wrapped in a try with a pad2 fallback, so the
  // deterministic form is always available even if a host lacks toLocale*.
  eq('the locale call is wrapped in a try', /try \{\s*day = d\.toLocaleDateString/.test(CLOCK_SRC), true)
  eq('and so is the date call', /try \{\s*day = d\.toLocaleDateString/.test(CLOCK_SRC), true)
  eq('the same-day branch returns the time alone', /if \(sameDay\) return time/.test(CLOCK_SRC), true)
})

group('truncateText - keep the head of a sentence', () => {
  eq('leading and trailing whitespace collapses', CL.truncateText('  a  \n b  '), 'a b')
  eq('a short string is untouched', CL.truncateText('short'), 'short')
  eq('the default cap is 80', CL.truncateText('a'.repeat(80)).length, 80)
  eq('one over the default cap is truncated', CL.truncateText('a'.repeat(81)), 'a'.repeat(77) + '...')
  eq('an explicit cap of 8', CL.truncateText('abcdefghij', 8), 'abcde...')
  eq('the result is exactly the cap long', CL.truncateText('a'.repeat(200), 20).length, 20)
  eq('a cap of zero falls back to the default', CL.truncateText('short', 0), 'short')
  eq('a nullish cap falls back to the default', CL.truncateText('short', null), 'short')
  // substring(0, max - 3) with a negative max is a negative index, which
  // substring treats as 0, so the result is the bare ellipsis.
  eq('a negative cap collapses to the ellipsis', CL.truncateText('abcdef', -2), '...')
  eq('internal tabs become spaces', CL.truncateText('a\tb'), 'a b')
  eq('internal newlines become spaces', CL.truncateText('a\nb'), 'a b')
  eq('an empty string', CL.truncateText(''), '')
  eq('whitespace only', CL.truncateText('   \n  '), '')
  // truncation is by UTF-16 code unit, so a multi-byte payload cuts mid-point
  // rather than mid-grapheme.
  eq('a unicode payload truncates by code unit', CL.truncateText('héllo wörld secret').length, 18)
  eq('a cut can split a surrogate pair into a lone unit', CL.truncateText('😀😀😀', 4).length, 4)
  // "the reader already knows how their sentence started" - the head survives.
  eq('the head survives truncation', CL.truncateText('The quick brown fox jumps', 12), 'The quick...')
  eq('the tail is always the ellipsis', CL.truncateText('x'.repeat(50), 10).endsWith('...'), true)
  eq('undefined stringifies', CL.truncateText(undefined), 'undefined')
})

group('truncatePath - cut from the FRONT so the name survives', () => {
  const long = '/a/'.repeat(20) + 'file.txt'
  const t = CL.truncatePath(long, 48)
  eq('the result is exactly the cap', t.length, 48)
  eq('it starts with the ellipsis', t.startsWith('...'), true)
  eq('the file name survives', t.endsWith('file.txt'), true)
  eq('the default cap is 48', CL.truncatePath(long).length, 48)
  eq('a short path is untouched', CL.truncatePath('/short', 48), '/short')
  eq('a path of exactly the cap is untouched', CL.truncatePath('abcdefgh', 8), 'abcdefgh')
  eq('with no slash in the tail the tail is raw', CL.truncatePath('abcdefghij', 8), '...fghij')
  // "Cuts land on a slash when one is near" - a slash at index 1..7 of the
  // tail is treated as a segment boundary, so the leading partial segment goes.
  eq('a slash near the cut is used as the boundary', CL.truncatePath('/verylongdirectoryname/other/thing/file.txt', 24), '.../other/thing/file.txt')
  eq('the boundary keeps everything from the slash', CL.truncatePath('/aaa/bbb/ccc/ddd/file.txt', 20), '.../ccc/ddd/file.txt')
  eq('a slash at tail index 0 is NOT used (slash > 0)', CL.truncatePath('/a/b/file.txt', 10), '...ile.txt')
  eq('a tail that starts with a slash keeps the doubled slash', CL.truncatePath('/a/'.repeat(20) + 'file.txt', 48).slice(0, 10), '...//a//a/')
  eq('an empty path', CL.truncatePath(''), '')
  eq('undefined is stringified', CL.truncatePath(undefined), 'undefined')
  eq('a zero cap falls back to the default', CL.truncatePath(long, 0).length, 48)
  eq('a cap below 3 cannot hold an ellipsis plus a tail', CL.truncatePath('abcdefghij', 2), '...')
  noThrow('a very long path', () => CL.truncatePath('/' + 'a'.repeat(10000), 48))
})

group('homeTilde - $HOME shrinks to ~', () => {
  CL.setHome(HOME)
  eq('home itself', CL.homeTilde(HOME), '~')
  eq('a path under home', CL.homeTilde(HOME + '/a/b'), '~/a/b')
  // The prefix test requires the trailing slash, so a sibling whose name
  // merely starts with $HOME is not folded.
  eq('a sibling directory sharing the prefix', CL.homeTilde('/home/u2/a'), '/home/u2/a')
  eq('a path outside home', CL.homeTilde('/etc/passwd'), '/etc/passwd')
  eq('a dot-dot escape under home still folds', CL.homeTilde(HOME + '/../etc'), '~/../etc')
  eq('a relative path', CL.homeTilde('a/b'), 'a/b')
  eq('an empty path', CL.homeTilde(''), '')
  eq('undefined is stringified', CL.homeTilde(undefined), 'undefined')
  // "HOME === \"\" or HOME === \"/\"" disables folding entirely - a home of
  // "/" would otherwise turn every absolute path into "~/…".
  CL.setHome('')
  eq('an unset home disables folding', CL.homeTilde(HOME + '/a'), HOME + '/a')
  CL.setHome('/')
  eq('a home of / disables folding', CL.homeTilde('/etc/passwd'), '/etc/passwd')
  CL.setHome(HOME)
  eq('the real home is restored', CL.homeTilde(HOME + '/a'), '~/a')
  // homeTilde is a display transform, not a sanitiser: a newline in a path
  // is folded but never removed, because a real file copy cannot carry one.
  eq('a newline in the path is folded, not stripped', CL.homeTilde(HOME + '/a\nb'), '~/a\nb')
  eq('a path with spaces folds normally', CL.homeTilde(HOME + '/my dir/a.txt'), '~/my dir/a.txt')
  eq('a non-string home is stringified', (CL.setHome(42), CL.homeTilde('42/a')), '~/a')
  CL.setHome(HOME)
  eq('the fixture home is the final state', CL.homeTilde(HOME + '/a'), '~/a')
})

group('safePath - the storage/hygiene cap on a title path', () => {
  const long = HOME + '/' + 'x'.repeat(300)
  eq('a long path is capped at 240', CL.safePath(long).length, 240)
  eq('the cap elides from the front', CL.safePath(long).startsWith('...'), true)
  eq('a short path is untouched', CL.safePath('/a/b.png'), '/a/b.png')
  eq('an empty path', CL.safePath(''), '')
  eq('undefined', CL.safePath(undefined), '')
  eq('null', CL.safePath(null), '')
  eq('a number is stringified', CL.safePath(42), '42')
  eq('exactly 240 is untouched', CL.safePath('a'.repeat(240)), 'a'.repeat(240))
  eq('241 is truncated', CL.safePath('a'.repeat(241)).length, 240)
  // safePath is a length cap, not a sanitiser: it never touches content, so a
  // newline or a dot-dot in a path is a caller problem, not this function's.
  eq('a newline is not removed', CL.safePath('/a\nb'), '/a\nb')
  eq('a dot-dot is not resolved', CL.safePath('/a/../../etc/passwd'), '/a/../../etc/passwd')
  eq('a path outside home is not rewritten', CL.safePath('/etc/shadow'), '/etc/shadow')
  // safePath runs before homeTilde in buildTitleSub, so folding cannot push
  // a capped path back over the limit.
  eq('a capped path stays capped after folding', CL.homeTilde(CL.safePath(HOME + '/' + 'x'.repeat(300))).length, 240)
  eq('an over-long path is still capped at 240, not 240+2', CL.safePath('/' + 'y'.repeat(1000)).length, 240)
})

group('prettyImageName - the snapshot row\'s name', () => {
  eq('the path extension wins', CL.prettyImageName({ filePaths: ['/a/b.jpeg'] }), 'JPEG')
  eq('and it is uppercased', CL.prettyImageName({ filePaths: ['/a/b.png'] }), 'PNG')
  eq('a webp path', CL.prettyImageName({ filePaths: ['/a/b.webp'] }), 'WEBP')
  // With no path, the mime decides - and the mime checks are substring scans
  // in a fixed order, so a mime naming two formats takes the first.
  eq('a png mime', CL.prettyImageName({ filePaths: [], mime: 'image/png' }), 'PNG')
  eq('a jpeg mime', CL.prettyImageName({ filePaths: [], mime: 'image/jpeg' }), 'JPEG')
  eq('a jpg mime', CL.prettyImageName({ filePaths: [], mime: 'image/jpg' }), 'JPEG')
  eq('a gif mime', CL.prettyImageName({ filePaths: [], mime: 'image/gif' }), 'GIF')
  eq('a webp mime', CL.prettyImageName({ filePaths: [], mime: 'image/webp' }), 'WEBP')
  eq('the first matching mime substring wins', CL.prettyImageName({ mime: 'image/png-x-jpeg' }), 'PNG')
  eq('an unknown mime', CL.prettyImageName({ mime: 'image/x-icon' }), 'Image')
  eq('an svg mime is not listed, so it reads as Image', CL.prettyImageName({ mime: 'image/svg+xml' }), 'Image')
  eq('no path and no mime', CL.prettyImageName({}), 'Image')
  eq('a multi-path entry has no single extension to read', CL.prettyImageName({ filePaths: ['/a.png', '/b.png'] }), 'Image')
  // A single path with no extension falls through to the mime checks.
  eq('a single extensionless path falls through to the mime', CL.prettyImageName({ filePaths: ['/a/b'], mime: 'image/gif' }), 'GIF')
  eq('a single path with no extension and no mime', CL.prettyImageName({ filePaths: ['/a/b'] }), 'Image')
  eq('a file:// path still has an extension', CL.prettyImageName({ filePaths: ['file:///a/b.png'] }), 'PNG')
  // An entry object is required: the function reads entry.filePaths directly.
  throws('a null entry throws', () => CL.prettyImageName(null), /filePaths/)
  throws('an undefined entry throws', () => CL.prettyImageName(undefined), /filePaths/)
})

group('countWords / countSymbols', () => {
  eq('two words', CL.countWords('a b'), 2)
  eq('surrounding whitespace is trimmed, runs collapse', CL.countWords('  a  b  '), 2)
  eq('one word', CL.countWords('one'), 1)
  eq('tabs and newlines separate', CL.countWords('a\tb\nc'), 3)
  eq('an empty string', CL.countWords(''), 0)
  eq('whitespace only', CL.countWords('   '), 0)
  // String(undefined) is "undefined", so a nullish payload counts as the one
  // word it stringifies to rather than as zero. Only "" trims to emptiness.
  eq('undefined counts as the word "undefined"', CL.countWords(undefined), 1)
  eq('null counts as the word "null"', CL.countWords(null), 1)
  eq('punctuation is not split on', CL.countWords('a, b.'), 2)
  eq('a hyphenated word is one token', CL.countWords('state-of-the-art'), 1)
  eq('countSymbols is the raw length', CL.countSymbols('héllo'), 5)
  eq('countSymbols counts whitespace', CL.countSymbols('a b'), 3)
  eq('countSymbols on an empty string', CL.countSymbols(''), 0)
  eq('countSymbols on a number', CL.countSymbols(42), 2)
  eq('countSymbols on undefined is the length of the word', CL.countSymbols(undefined), 9)
  eq('an emoji is two code units', CL.countSymbols('\u{1F600}'), 2)
  eq('words and symbols agree on a sentence', [CL.countWords('one two three'), CL.countSymbols('one two three')], [3, 13])
  eq('the symbol count never includes the separator', CL.countSymbols('one two three') > CL.countWords('one two three'), true)
})

// ===========================================================================
section('ClipboardLib - haystack and search')
// ===========================================================================

group('hayFor - the searchable surface of a row', () => {
  const e = { title: 'My Report', subLeft: 'File • 1 KB', preview: 'the quick brown fox', mime: 'application/pdf', type: 'file' }
  eq('title, subtext, preview, mime and type, lowercased', CL.hayFor(e), 'my report file • 1 kb the quick brown fox application/pdf')
  eq('wordsFor splits on single spaces', CL.wordsFor(CL.hayFor(e)), ['my', 'report', 'file', '•', '1', 'kb', 'the', 'quick', 'brown', 'fox', 'application/pdf'])
  eq('duplicates are removed across the whole hay', CL.hayFor({ title: 'a b a b', subLeft: 'a', preview: 'b', mime: 'a', type: 'a' }), 'a b')
  eq('a word repeated only in the preview is removed', CL.hayFor({ title: 'a', preview: 'a b' }), 'a b')
  // "Secrets contribute ONLY the generic hint - their payload never enters
  // any searchable surface." For a service-built secret the raw and the
  // preview are both "", so only the generic hints are in the hay.
  eq('a service-built secret contributes only the hint', CL.hayFor({ title: 'Sensitive content', subLeft: 'Credentials • Hidden', preview: '', mime: 'text/plain', type: 'secret', raw: '' }), 'sensitive content credentials • hidden text/plain secret password')
  notContains('and never the payload', CL.hayFor({ title: 'Sensitive content', preview: '', type: 'secret', raw: '' }), 'hunter2')
  // raw is never part of the hay for ANY type - only the derived title is.
  eq('raw is not searchable', CL.hayFor({ title: 'a', raw: 'zzz-unique-token', type: 'text' }).indexOf('zzz-unique-token'), -1)
  eq('a network row carries its protocol keywords', CL.hayFor({ title: 'a', type: 'network' }), 'a network storage ftp sftp smb nfs ssh s3')
  eq('a secret row carries its credential keywords', CL.hayFor({ title: 'a', type: 'secret' }), 'a secret credentials password')
  eq('an empty entry has an empty hay', CL.hayFor({}), '')
  eq('a title alone', CL.hayFor({ title: 'a' }), 'a')
  eq('the preview is capped at 200 characters', CL.hayFor({ title: 't', preview: 'q'.repeat(500) }).length, 202)
  eq('the cap is on the preview alone', CL.hayFor({ title: 'tt', preview: 'q'.repeat(500) }), 'tt ' + 'q'.repeat(200))
  eq('falsy fields are skipped rather than stringified', CL.hayFor({ title: 0, subLeft: '', preview: null, mime: undefined, type: '' }), '')
  eq('a numeric title is stringified', CL.hayFor({ title: 42 }), '42')
  eq('the whole hay is lowercased', CL.hayFor({ title: 'MiXeD' }), 'mixed')
  eq('a type with a space contributes one token', CL.hayFor({ title: '', type: 'a b' }), 'a b')
  eq('wordsFor on an empty hay', CL.wordsFor(''), [''])
  eq('wordsFor is a plain space split', CL.wordsFor('a  b'), ['a', '', 'b'])
  eq('wordsFor round-trips a hay', CL.wordsFor(CL.hayFor(e)).join(' '), CL.hayFor(e))
})

group('searchEntries - tokenized AND with substring-beats-prefix scoring', () => {
  const es = [mk('a', 'firefox'), mk('b', 'Firefox Nightly'), mk('c', 'my file report.txt'), mk('d', 'code'), mk('e', 'Deep Space Notes')]
  eq('a whole word matches the exact title and the longer one', ids(CL.searchEntries(es, 'firefox')), ['a', 'b'])
  // "Whole-title exact match wins outright - typing a pinned app name or a
  // file basename lands on it before longer texts that merely contain the
  // same word."
  eq('an exact title beats a longer title', ids(CL.searchEntries(es, 'code')), ['d'])
  eq('two tokens are ANDed', ids(CL.searchEntries(es, 'my report')), ['c'])
  eq('one unmatched token rejects the row', ids(CL.searchEntries(es, 'my zzz')), [])
  eq('a prefix falls back to the word-prefix chain', ids(CL.searchEntries(es, 'fire')), ['a', 'b', 'c'])
  eq('no match returns an empty array', ids(CL.searchEntries(es, 'zzzz')), [])
  eq('an empty query returns everything', ids(CL.searchEntries(es, '')), ['a', 'b', 'c', 'd', 'e'])
  eq('a whitespace-only query returns everything', ids(CL.searchEntries(es, '   ')), ['a', 'b', 'c', 'd', 'e'])
  eq('undefined returns everything', ids(CL.searchEntries(es, undefined)), ['a', 'b', 'c', 'd', 'e'])
  eq('a cap truncates the unfiltered list', ids(CL.searchEntries(es, '', 2)), ['a', 'b'])
  eq('a cap also truncates a filtered list', ids(CL.searchEntries(es, 'space', 1)), ['e'])
  eq('a cap of zero returns nothing', CL.searchEntries(es, 'firefox', 0), [])
  eq('the query is lowercased', ids(CL.searchEntries(es, 'FIREFOX')), ['a', 'b'])
  eq('the query is trimmed', ids(CL.searchEntries(es, '  firefox  ')), ['a', 'b'])
  // "substring-beats-prefix": a word-initial hit outranks the same substring
  // appearing mid-word.
  eq('a word-initial hit outranks a mid-word one', ids(CL.searchEntries([mk('sub', 'the report'), mk('word', 'report')], 'report')), ['word', 'sub'])
  eq('an exact token outranks the same offset as a substring', ids(CL.searchEntries([mk('x', 'xxab'), mk('y', 'xx ab')], 'ab')), ['y', 'x'])
  eq('an earlier offset outranks a later one', ids(CL.searchEntries([mk('late', 'zzz report'), mk('early', 'report zzz')], 'report')), ['early', 'late'])
  // The prefix chain matches across word boundaries: "fire" also reaches
  // "my file report.txt" by chaining f-i-r-e through the first word.
  eq('the prefix chain is the fallback, not a substring scan', ids(CL.searchEntries([mk('c', 'my file report.txt')], 'fil')), ['c'])
  eq('a prefix that only chains across two words', ids(CL.searchEntries([mk('c', 'deep space')], 'desp')), ['c'])
  eq('a token longer than the hay rejects the row outright', ids(CL.searchEntries(es, 'firefoxbrowser')), [])
  eq('an entry with no words is split from its own hay', ids(CL.searchEntries([{ id: 'x', hay: 'a b' }], 'a')), ['x'])
  eq('an entry with no hay and no words matches a prefix', ids(CL.searchEntries([{ id: 'x', hay: 'abc' }], 'ab')), ['x'])
  eq('an entry with no hay at all matches nothing', ids(CL.searchEntries([{ id: 'x' }], 'a')), [])
  eq('the result holds the entry objects, not copies', CL.searchEntries(es, 'code')[0] === es[3], true)
  eq('an empty entry list', CL.searchEntries([], 'a'), [])
  eq('the score order is stable for equal scores', ids(CL.searchEntries([mk('p', 'same'), mk('q', 'same')], 'same')), ['p', 'q'])
  eq('an exact title match still scores', ids(CL.searchEntries([{ id: 'z', title: 'Solo', hay: 'solo', words: ['solo'] }], 'solo')), ['z'])
  // "if (tok.length > hay.length) { ok = false; break }" runs before the
  // exact-title bonus is ever added, so the 600-point boost cannot rescue a
  // row whose haystack is empty.
  eq('an exact title with an empty hay is still rejected', CL.searchEntries([{ id: 'z', title: 'Solo', hay: '', words: [] }], 'solo'), [])
  eq('an exact title match outranks a longer one', ids(CL.searchEntries([{ id: 'a', title: 'x', hay: 'x y', words: ['x', 'y'] }, { id: 'b', title: 'x y', hay: 'x y', words: ['x', 'y'] }], 'x')), ['a', 'b'])
  // A null entry list is a caller bug, and the library does not guard it.
  throws('a null entry list throws', () => CL.searchEntries(null, 'a'), /length/)
  noThrow('a null query does not throw', () => CL.searchEntries(es, null))
  eq('a 200-row list is fully searchable', CL.searchEntries(new Array(200).fill(0).map((_, i) => mk('e' + i, 'row ' + i)), 'row 199').length, 1)
})

group('selectEntries - the mode filter and the search in one step', () => {
  const hist = [mk('a', 'one'), mk('b', 'two'), mk('c', 'three')]
  hist[1].pinned = true
  eq('the all mode excludes pinned rows', ids(CL.selectEntries(hist, 'all', '')), ['a', 'c'])
  eq('the pinned mode includes only pinned rows', ids(CL.selectEntries(hist, 'pinned', '')), ['b'])
  eq('an unknown mode behaves as "all"', ids(CL.selectEntries(hist, 'bogus', '')), ['a', 'c'])
  eq('a query filters within the mode', ids(CL.selectEntries(hist, 'all', 'th')), ['c'])
  eq('a query never reaches across the mode boundary', ids(CL.selectEntries(hist, 'pinned', 'th')), [])
  eq('a query inside the pinned mode', ids(CL.selectEntries(hist, 'pinned', 'two')), ['b'])
  eq('the query is trimmed before it is used', ids(CL.selectEntries(hist, 'all', '  th  ')), ['c'])
  eq('null history', CL.selectEntries(null, 'all', ''), [])
  eq('undefined history', CL.selectEntries(undefined, 'all', ''), [])
  eq('an empty history', CL.selectEntries([], 'all', ''), [])
  eq('undefined mode behaves as "all"', ids(CL.selectEntries(hist, undefined, '')), ['a', 'c'])
  // String(undefined) is the word "undefined", so a nullish query is a real
  // (and almost certainly fruitless) search rather than "no query".
  eq('an undefined query searches for the word "undefined"', ids(CL.selectEntries(hist, 'all', undefined)), [])
  eq('a history of only pinned rows in the all mode', CL.selectEntries([hist[1]], 'all', ''), [])
  eq('a history of only pinned rows in the pinned mode', CL.selectEntries([hist[1]], 'pinned', '').length, 1)
  // "The mode filter and the search in one step, so the list a panel binds
  // and the count it reports cannot come from two different passes."
  eq('the list and the count come from the same pass', CL.selectEntries(hist, 'all', '').length, 2)
  // The 200 cap is the `cap` argument to searchEntries, so it only reaches a
  // FILTERED list: `if (q === "") return src` hands the whole mode back
  // uncapped. Pinned because "the list a panel binds is capped at 200" is
  // only true while the user is typing.
  const many = new Array(500).fill(0).map((_, i) => mk('e' + i, 'row ' + i))
  eq('an empty query returns the whole mode uncapped', CL.selectEntries(many, 'all', '').length, 500)
  eq('a filtered list is capped at 200', CL.selectEntries(many, 'all', 'row').length, 200)
  eq('the cap applies on the pinned mode too', CL.selectEntries(new Array(500).fill(0).map((_, i) => { const e = mk('p' + i, 'row ' + i); e.pinned = true; return e }), 'pinned', 'row').length, 200)
  eq('a filtered list under the cap is untouched', CL.selectEntries(many, 'all', 'row 1').length > 0, true)
  eq('a no-match query is empty regardless of the cap', CL.selectEntries(many, 'all', 'zzzz'), [])
})

// ===========================================================================
section('ClipboardLib - the entry model and its projections')
// ===========================================================================

group('newEntry - every field a row may carry', () => {
  const e = CL.newEntry('id1', 1000, 'raw body', 'text/plain', 'text', [], 'prev')
  eq('29 fields', Object.keys(e).length, 29)
  is('every documented field is present', Object.keys(e), (k) => [
    'id', 'ts', 'raw', 'mime', 'type', 'icon', 'title', 'subLeft', 'hay', 'words', 'pinned', 'preview',
    'filePaths', 'fileSize', 'totalSize', 'folderCount', 'foldersCount', 'allFolders', 'imageW', 'imageH',
    'imageFile', 'imageDataFile', 'imageSha', 'git', 'pathLike', 'secretHandle', 'unavailable',
    'missing', 'missingText',
  ].every((n) => k.indexOf(n) >= 0), 'all 29 documented names present')
  eq('the field order matches the declaration order', Object.keys(e).join(','),
    'id,ts,raw,mime,type,icon,title,subLeft,hay,words,pinned,preview,filePaths,fileSize,totalSize,folderCount,foldersCount,allFolders,imageW,imageH,imageFile,imageDataFile,imageSha,git,pathLike,secretHandle,unavailable,missing,missingText')
  eq('raw is stringified', CL.newEntry('a', 1, 42, 'm', 't').raw, '42')
  eq('an undefined raw is the empty string', CL.newEntry('a', 1, undefined, 'm', 't').raw, '')
  // The ternary tests `raw === undefined`, so a null (or any other value)
  // goes through String() instead of being folded away.
  eq('a null raw is stringified, not folded', CL.newEntry('a', 1, null, 'm', 't').raw, 'null')
  eq('an object raw is stringified at construction', CL.newEntry('a', 1, { x: 1 }, 'm', 't').raw, '[object Object]')
  eq('a missing mime defaults to text/plain', CL.newEntry('a', 1, 'x').mime, 'text/plain')
  eq('an empty mime also defaults', CL.newEntry('a', 1, 'x', '').mime, 'text/plain')
  eq('a missing preview is the empty string', CL.newEntry('a', 1, 'x', 'm', 't').preview, '')
  eq('a numeric preview is stringified', CL.newEntry('a', 1, 'x', 'm', 't', [], 7).preview, '7')
  eq('a missing filePaths is a fresh array', CL.newEntry('a', 1, 'x').filePaths, [])
  eq('a supplied filePaths is kept', CL.newEntry('a', 1, 'x', 'm', 't', ['/p']).filePaths, ['/p'])
  is('two entries never share an array', [CL.newEntry('a', 1, 'x'), CL.newEntry('b', 1, 'x')], (v) => v[0].filePaths !== v[1].filePaths, 'distinct filePaths arrays')
  eq('pinned starts false', CL.newEntry('a', 1, 'x').pinned, false)
  eq('unavailable starts false', CL.newEntry('a', 1, 'x').unavailable, false)
  eq('missing starts false', CL.newEntry('a', 1, 'x').missing, false)
  eq('missingText starts empty', CL.newEntry('a', 1, 'x').missingText, '')
  eq('icon and title start empty', [CL.newEntry('a', 1, 'x').icon, CL.newEntry('a', 1, 'x').title], ['', ''])
  eq('subLeft and hay start empty', [CL.newEntry('a', 1, 'x').subLeft, CL.newEntry('a', 1, 'x').hay], ['', ''])
  eq('words starts as an empty array', CL.newEntry('a', 1, 'x').words, [])
  eq('pathLike starts false', CL.newEntry('a', 1, 'x').pathLike, false)
  eq('secretHandle starts empty', CL.newEntry('a', 1, 'x').secretHandle, '')
  eq('imageSha starts empty', CL.newEntry('a', 1, 'x').imageSha, '')
  eq('imageFile and imageDataFile start empty', [CL.newEntry('a', 1, 'x').imageFile, CL.newEntry('a', 1, 'x').imageDataFile], ['', ''])
  // The three size fields start *undefined*, not 0: "absent means pending,
  // never fake" is the buildSubLeft contract, and 0 would read as measured.
  eq('fileSize starts undefined', CL.newEntry('a', 1, 'x').fileSize, undefined)
  eq('totalSize starts undefined', CL.newEntry('a', 1, 'x').totalSize, undefined)
  eq('folderCount starts undefined', CL.newEntry('a', 1, 'x').folderCount, undefined)
  eq('foldersCount starts 0', CL.newEntry('a', 1, 'x').foldersCount, 0)
  eq('allFolders starts false', CL.newEntry('a', 1, 'x').allFolders, false)
  eq('imageW and imageH start 0', [CL.newEntry('a', 1, 'x').imageW, CL.newEntry('a', 1, 'x').imageH], [0, 0])
})

group('deriveEntry - recompute the display fields in place', () => {
  CL.setHome(HOME)
  // "Recompute the display fields after any mutation." The function mutates
  // its argument and returns the SAME object, which is what the patch sites
  // rely on: Clipboard.qml writes `CL.deriveEntry(e)` inside a patch callback
  // that has no assignment of its own.
  const e = CL.newEntry('a', Date.now(), 'hello world this is text', 'text/plain', 'text')
  const same = CL.deriveEntry(e)
  eq('the returned object IS the argument', same === e, true)
  eq('the title is derived', e.title, 'hello world this is text')
  eq('the icon is derived', e.icon, 'text')
  eq('the subtext is derived', e.subLeft, '5 words • 24 chars')
  eq('the hay is derived', e.hay, 'hello world this is text 5 words • 24 chars text/plain')
  eq('the words are derived from the hay', e.words, CL.wordsFor(e.hay))
  is('a time string is added', e.timeStr, (s) => typeof s === 'string' && s.length > 0, 'a non-empty time string')
  match('the time string looks like a clock time', e.timeStr, /\d{1,2}:\d{2}/)
  // Deriving twice is stable: a patch that runs deriveEntry on an already
  // derived row must not keep growing the hay.
  const before = e.hay
  CL.deriveEntry(e)
  eq('deriving twice is idempotent', e.hay, before)
  eq('deriving twice keeps the same title', e.title, 'hello world this is text')
  const p = CL.deriveEntry(CL.newEntry('b', TS, HOME + '/docs/report.pdf', 'application/pdf', 'file', [HOME + '/docs/report.pdf']))
  eq('a path row folds home', p.title, '~/docs/report.pdf')
  eq('a path row is left-elided', p.pathLike, true)
  eq('a path row gets an extension icon', p.icon, 'file-pdf')
  eq('a path row with no probe says only "File"', p.subLeft, 'File')
  // "Never logs an entry payload: titles count words, they do not carry
  // content" - the subtext is counts, not the body.
  notContains('the subtext never carries the path', p.subLeft, 'docs/report.pdf')
  eq('a text row is not path-like', CL.deriveEntry(CL.newEntry('c', TS, 'plain', 'text/plain', 'text')).pathLike, false)
  eq('a number gets the calculator icon', CL.deriveEntry(CL.newEntry('d', TS, '42', 'text/plain', 'text')).icon, 'calculator')
  eq('an expression gets the math icon', CL.deriveEntry(CL.newEntry('e', TS, '2+2', 'text/plain', 'text')).icon, 'math')
  eq('a function of x gets the math icon', CL.deriveEntry(CL.newEntry('f', TS, 'x^2', 'text/plain', 'text')).icon, 'math')
  eq('an ordinary sentence gets the text icon', CL.deriveEntry(CL.newEntry('g', TS, 'hello', 'text/plain', 'text')).icon, 'text')
  eq('a url row is not path-like', CL.deriveEntry(CL.newEntry('i', TS, 'https://x.dev', 'text/plain', 'url')).pathLike, false)
  const s = CL.deriveEntry(CL.newEntry('h', TS, '', 'text/plain', 'secret', [], ''))
  eq('a secret row is titled generically', s.title, 'Sensitive content')
  eq('a secret row is locked', s.icon, 'lock')
  eq('a secret row is not path-like', s.pathLike, false)
  eq('a secret row says so in the subtext', s.subLeft, 'Credentials • Hidden')
  eq('a secret row with an empty raw and preview has no payload in the hay', s.hay, 'sensitive content credentials • hidden text/plain secret password')
  eq('an empty text row is named, not blank', CL.deriveEntry(CL.newEntry('j', TS, '   ', 'text/plain', 'text')).title, 'Empty text')
  noThrow('deriving a row whose raw is undefined', () => CL.deriveEntry(CL.newEntry('k', TS, undefined, 'text/plain', 'text')))
  noThrow('deriving a row with a 0 timestamp', () => CL.deriveEntry(CL.newEntry('l', 0, 'x', 'text/plain', 'text')))
  noThrow('deriving a row whose filePaths is not an array, as text', () => CL.deriveEntry(CL.newEntry('m', TS, 'x', 'text/plain', 'text', 'oops')))
  // A network row filters filePaths, so a non-array there is a hard throw -
  // the service only ever builds one of these with parseUriList's output.
  throws('deriving a network row whose filePaths is not an array', () => CL.deriveEntry(CL.newEntry('m2', TS, 'x', 'text/plain', 'network', 'oops')), /filter/)
  eq('deriveEntry always returns its argument', (() => { const x = CL.newEntry('n', TS, 'x', 'm', 'text'); return CL.deriveEntry(x) === x })(), true)
})

group('buildTitleSub - the per-type title and icon', () => {
  CL.setHome(HOME)
  const one = (fields) => {
    const e = CL.newEntry('x', TS, '', '', 'text', [], '')
    Object.assign(e, fields)
    CL.buildTitleSub(e)
    return e
  }
  const t = one({ type: 'secret' })
  eq('a secret title', [t.title, t.icon, t.pathLike], ['Sensitive content', 'lock', false])
  const u = one({ type: 'url', raw: 'https://example.com/a/b' })
  eq('a url title is the raw url', [u.title, u.icon, u.pathLike], ['https://example.com/a/b', 'link', false])
  eq('a long url is capped at 64', one({ type: 'url', raw: 'https://x.dev/' + 'a'.repeat(200) }).title.length, 64)
  const tx = one({ type: 'text', raw: 'a\n b' })
  eq('whitespace collapses in a text title', tx.title, 'a b')
  eq('an empty text row is named, not blank', one({ type: 'text', raw: '   ' }).title, 'Empty text')
  eq('a file: scheme is stripped from a text title', one({ type: 'text', raw: 'file:///tmp/a.png' }).title, '/tmp/a.png')
  eq('a text title is capped at 72', one({ type: 'text', raw: 'a'.repeat(200) }).title.length, 72)
  const i1 = one({ type: 'image', filePaths: [HOME + '/pics/a.webp'] })
  eq('a copied image keeps the full folded path as its title', [i1.title, i1.icon, i1.pathLike], ['~/pics/a.webp', 'file-image', true])
  const i2 = one({ type: 'image', filePaths: [], mime: 'image/svg+xml' })
  eq('a snapshot image has no path to title', [i2.title, i2.icon, i2.pathLike], ['Image image', 'file-svg', false])
  eq('a png snapshot is named from its mime', one({ type: 'image', filePaths: [], mime: 'image/png' }).title, 'PNG image')
  eq('a single image path is extension-iconed', one({ type: 'image', filePaths: ['/a/b.jpeg'] }).icon, 'file-image')
  eq('an svg path gets the svg icon', one({ type: 'image', filePaths: ['/a/b.svg'] }).icon, 'file-svg')
  eq('an unrecognised image extension falls back to the image icon', one({ type: 'image', filePaths: ['/a/b.bin'] }).icon, 'file-image')
  eq('a two-path image row is treated as a snapshot', one({ type: 'image', filePaths: ['/a/b.png', '/c/d.png'], mime: 'image/png' }).title, 'PNG image')
  const f1 = one({ type: 'file', filePaths: [HOME + '/docs/a.pdf'] })
  eq('a file row keeps the folded path', [f1.title, f1.icon, f1.pathLike], ['~/docs/a.pdf', 'file-pdf', true])
  eq('a path outside home is not rewritten', one({ type: 'file', filePaths: ['/etc/passwd'] }).title, '/etc/passwd')
  eq('an unknown extension gets the generic file icon', one({ type: 'file', filePaths: ['/a/b.bin'] }).icon, 'file')
  const fo = one({ type: 'folder', filePaths: ['/a/b'] })
  eq('a folder row', [fo.title, fo.icon, fo.pathLike], ['/a/b', 'file-folder', true])
  const ar = one({ type: 'archive', filePaths: ['/a/b.zip'] })
  eq('an archive row ignores the extension icon', [ar.title, ar.icon], ['/a/b.zip', 'file-archive'])
  eq('a file row falls back to raw when there are no paths', one({ type: 'file', filePaths: [], raw: HOME + '/raw.txt' }).title, '~/raw.txt')
  const n1 = one({ type: 'network', filePaths: ['smb://server/share/dir'] })
  eq('a network row drops the scheme', [n1.title, n1.icon, n1.pathLike], ['server/share/dir', 'file-network', true])
  eq('a network row uses the first non-comment raw line', one({ type: 'network', filePaths: [], raw: '# hdr\nsmb://h/dir\nsmb://h/other' }).title, 'h/dir')
  eq('a comment-only network row falls back to a generic title', one({ type: 'network', filePaths: [], raw: '# only\n' }).title, 'Network storage')
  eq('an empty network row falls back too', one({ type: 'network', filePaths: [], raw: '' }).title, 'Network storage')
  eq('a bare scheme network row keeps the scheme', one({ type: 'network', filePaths: [], raw: 'dav://' }).title, 'dav://')
  eq('a network path is capped at 240', one({ type: 'network', filePaths: ['smb://' + 'h'.repeat(400)] }).title.length, 240)
  const fi = one({ type: 'files', filePaths: ['/a', '/b', '/c'] })
  eq('a files row is counted', [fi.title, fi.icon, fi.pathLike], ['3 files', 'files', false])
  const fo2 = one({ type: 'folders', filePaths: ['/a', '/b'], allFolders: true })
  eq('an all-folders row uses the folders icon', [fo2.title, fo2.icon], ['2 folders', 'file-folders'])
  // "n > 0 ? n + \" folders\" : \"Folders\"" has no singular branch, so a
  // one-item all-folders row reads "1 folders" while buildSubLeft says
  // "1 folder". Pinned because the asymmetry is invisible in review.
  const fo3 = one({ type: 'folders', filePaths: ['/a'], allFolders: true })
  eq('a single all-folder row has a plural title', fo3.title, '1 folders')
  eq('while its subtext is singular', CL.buildSubLeft(fo3), '1 folder')
  // The "files" and "folders" types share one branch, so allFolders decides
  // the copy AND the icon for either of them.
  eq('a files row with allFolders reads as folders', one({ type: 'files', filePaths: ['/a', '/b'], allFolders: true }).title, '2 folders')
  eq('and uses the folders icon too', one({ type: 'files', filePaths: ['/a', '/b'], allFolders: true }).icon, 'file-folders')
  eq('the two types are then indistinguishable', one({ type: 'files', filePaths: ['/a', '/b'], allFolders: true }).title, one({ type: 'folders', filePaths: ['/a', '/b'], allFolders: true }).title)
  eq('an empty files row is named generically', one({ type: 'files', filePaths: [] }).title, 'Files')
  eq('an empty folders row is named generically', one({ type: 'folders', filePaths: [], allFolders: true }).title, 'Folders')
  const un = one({ type: 'weirdtype', raw: 'zzz' })
  eq('an unknown type falls back to a truncated raw title', [un.title, un.icon, un.pathLike], ['zzz', 'text', false])
  eq('an unknown type has no subtext', CL.buildSubLeft(un), '')
  eq('an unknown type with no raw', one({ type: 'weirdtype', raw: '' }).title, '')
  // The path-safety chain: safePath caps, then homeTilde folds. Neither
  // sanitises content - a newline in a path cannot come from a real file
  // copy, and the row's single-line height comes from the model's elide.
  eq('a newline in a path survives to the title', one({ type: 'file', filePaths: ['/a\nb.txt'] }).title, '/a\nb.txt')
  eq('a dot-dot path is not resolved', one({ type: 'file', filePaths: ['/a/../b.txt'] }).title, '/a/../b.txt')
  eq('an over-long path is capped at 240', one({ type: 'file', filePaths: ['/x/' + 'y'.repeat(400)] }).title.length, 240)
  eq('a file:// path is stripped before the title', one({ type: 'file', filePaths: ['file:///a/b.png'] }).title, '/a/b.png')
  eq('buildTitleSub returns undefined (it mutates)', CL.buildTitleSub(CL.newEntry('z', TS, 'x', 'm', 'text')), undefined)
  noThrow('a row whose filePaths is not an array', () => CL.buildTitleSub(Object.assign(CL.newEntry('z2', TS, '', '', 'file'), { filePaths: 'oops' })))
})

group('buildSubLeft - what the thing IS, quantified', () => {
  eq('a secret', CL.buildSubLeft({ type: 'secret' }), 'Credentials • Hidden')
  eq('a url', CL.buildSubLeft({ type: 'url' }), 'Web URL')
  eq('one word', CL.buildSubLeft({ type: 'text', raw: 'hello' }), '1 word • 5 chars')
  eq('several words', CL.buildSubLeft({ type: 'text', raw: 'a b c d' }), '4 words • 7 chars')
  eq('an empty text row still counts', CL.buildSubLeft({ type: 'text', raw: '' }), '0 words • 0 chars')
  eq('a missing raw counts as the word "undefined"', CL.buildSubLeft({ type: 'text' }), '1 word • 9 chars')
  eq('an image with dimensions and a size', CL.buildSubLeft({ type: 'image', imageW: 800, imageH: 600, fileSize: 2048 }), '800x600 • 2 KB')
  eq('an image with only dimensions', CL.buildSubLeft({ type: 'image', imageW: 800, imageH: 600 }), '800x600')
  eq('an image with only a size', CL.buildSubLeft({ type: 'image', fileSize: 2048 }), '2 KB')
  eq('a pending image', CL.buildSubLeft({ type: 'image' }), 'Image')
  eq('a zero width suppresses the dimensions', CL.buildSubLeft({ type: 'image', imageW: 0, imageH: 600 }), 'Image')
  eq('a zero size is absent, not zero', CL.buildSubLeft({ type: 'image', fileSize: 0 }), 'Image')
  eq('a negative size is absent', CL.buildSubLeft({ type: 'image', fileSize: -1 }), 'Image')
  eq('an undefined size is absent', CL.buildSubLeft({ type: 'archive', fileSize: undefined }), 'Archive')
  eq('an archive with a size', CL.buildSubLeft({ type: 'archive', fileSize: 5000 }), 'Archive • 4.9 KB')
  eq('a file with a size', CL.buildSubLeft({ type: 'file', fileSize: 5000 }), '4.9 KB')
  eq('a pending file', CL.buildSubLeft({ type: 'file' }), 'File')
  eq('a folder with counts', CL.buildSubLeft({ type: 'folder', folderCount: 4, fileSize: 1024 }), '4 files • 1 KB')
  eq('a pending folder', CL.buildSubLeft({ type: 'folder' }), 'Folder')
  eq('a folder with a null count is still pending', CL.buildSubLeft({ type: 'folder', folderCount: null }), 'Folder')
  eq('a zero folder count still prints', CL.buildSubLeft({ type: 'folder', folderCount: 0 }), '0 files')
  // Network: the protocol/host pair comes from the same URI the title used.
  eq('a labelled protocol', CL.buildSubLeft({ type: 'network', filePaths: ['smb://server/share'] }), 'SMB • server')
  eq('a webdav share is labelled WebDAV', CL.buildSubLeft({ type: 'network', filePaths: ['webdav://h/x'] }), 'WebDAV • h')
  eq('a dav share is labelled WebDAV too', CL.buildSubLeft({ type: 'network', filePaths: ['dav://h/x'] }), 'WebDAV • h')
  eq('a davs share is labelled WebDAVS', CL.buildSubLeft({ type: 'network', filePaths: ['davs://h/x'] }), 'WebDAVS • h')
  // The label table only covers the 15 network schemes, so a uri whose scheme
  // is not one of them is not a network uri at all and never reaches here.
  eq('a non-network scheme is filtered out before labelling', CL.buildSubLeft({ type: 'network', filePaths: ['weird://h/x'] }), 'Network storage')
  eq('the userinfo is dropped from the host', CL.buildSubLeft({ type: 'network', filePaths: ['smb://user:pw@server/share'] }), 'SMB • server')
  eq('the port is dropped from the host', CL.buildSubLeft({ type: 'network', filePaths: ['smb://server:445/share'] }), 'SMB • server')
  eq('a bare scheme has no host', CL.buildSubLeft({ type: 'network', filePaths: ['sftp://'] }), 'SFTP location')
  eq('several locations are counted', CL.buildSubLeft({ type: 'network', filePaths: ['ftp://a/x', 'ftp://b/y'] }), '2 network locations')
  eq('raw lines are used when there are no paths', CL.buildSubLeft({ type: 'network', raw: '# c\nsftp://hostonly' }), 'SFTP • hostonly')
  eq('a comment-only raw list is a generic share', CL.buildSubLeft({ type: 'network', raw: '# c' }), 'Network storage')
  eq('non-network paths in a network row are filtered out', CL.buildSubLeft({ type: 'network', filePaths: ['/tmp/a.png'] }), 'Network storage')
  eq('an empty network row', CL.buildSubLeft({ type: 'network' }), 'Network storage')
  // Multi-selection counts.
  eq('one file', CL.buildSubLeft({ type: 'files', filePaths: ['/a'], foldersCount: 0 }), '1 file')
  eq('three files', CL.buildSubLeft({ type: 'files', filePaths: ['/a', '/b', '/c'], foldersCount: 0 }), '3 files')
  eq('a mixed selection counts items', CL.buildSubLeft({ type: 'files', filePaths: ['/a', '/b', '/c'], foldersCount: 1 }), '3 items • 1 folder')
  eq('every entry a folder', CL.buildSubLeft({ type: 'files', filePaths: ['/a', '/b'], foldersCount: 2, allFolders: true }), '2 folders')
  eq('the inner count is added', CL.buildSubLeft({ type: 'files', filePaths: ['/a', '/b', '/c'], foldersCount: 1, folderCount: 12, totalSize: 5 * 1024 * 1024 }), '3 items • 1 folder • 12 files • 5 MB')
  // "folders < n" suppresses the folder part when every entry is already one.
  eq('a full-folder mixed selection omits the folder count', CL.buildSubLeft({ type: 'files', filePaths: ['/a', '/b'], foldersCount: 2 }), '2 items')
  // "const n = entry.filePaths ? entry.filePaths.length : (entry.fileCount || 0)"
  // - an empty array is truthy, so fileCount is only consulted when the field
  // is absent entirely.
  eq('an empty filePaths array does NOT fall back to fileCount', CL.buildSubLeft({ type: 'files', filePaths: [], fileCount: 7 }), '0 files')
  eq('an absent filePaths does fall back to fileCount', CL.buildSubLeft({ type: 'files', fileCount: 7 }), '7 files')
  eq('a singular folder word', CL.buildSubLeft({ type: 'folders', filePaths: ['/a'], allFolders: true }), '1 folder')
  eq('a one-item mixed selection is singular', CL.buildSubLeft({ type: 'files', filePaths: ['/a'], foldersCount: 1 }), '1 item')
  eq('a one-item non-mixed selection is singular', CL.buildSubLeft({ type: 'files', filePaths: ['/a'], foldersCount: 0 }), '1 file')
  eq('a zero total size is absent', CL.buildSubLeft({ type: 'files', filePaths: ['/a'], totalSize: 0 }), '1 file')
  eq('a zero folderCount is absent', CL.buildSubLeft({ type: 'files', filePaths: ['/a'], folderCount: 0 }), '1 file')
  eq('an unknown type has no subtext', CL.buildSubLeft({ type: 'nope' }), '')
  eq('a missing type has no subtext', CL.buildSubLeft({}), '')
  eq('buildSubLeft is pure - it does not mutate', (() => { const e = CL.newEntry('a', TS, 'x', 'm', 'text'); CL.buildSubLeft(e); return e.subLeft })(), '')
})

group('entryPaths - every path this entry references', () => {
  eq('the snapshot, the image, then the paths, in order',
    CL.entryPaths({ imageDataFile: '/tmp/s.png', imageFile: '/tmp/i.png', filePaths: ['/tmp/c.txt'] }), ['/tmp/s.png', '/tmp/i.png', '/tmp/c.txt'])
  eq('a file:// uri-list is expanded to its local paths', CL.entryPaths({ filePaths: ['file:///tmp/a%20b.png'] }), ['/tmp/a b.png'])
  eq('a multi-line uri-list is expanded', CL.entryPaths({ filePaths: ['file:///a.png\n# c\n/b.txt'] }), ['/a.png', '/b.txt'])
  eq('a bare absolute path is taken as is', CL.entryPaths({ filePaths: ['/tmp/c.txt'] }), ['/tmp/c.txt'])
  // "a bare absolute path is taken as is" - a relative one is not something
  // the snapshot GC can unlink, so it is dropped rather than resolved.
  eq('a relative path is dropped', CL.entryPaths({ filePaths: ['relative/path'] }), [])
  eq('an http uri is dropped', CL.entryPaths({ filePaths: ['http://x/y'] }), [])
  eq('empty strings are skipped', CL.entryPaths({ filePaths: ['', '/a', ''] }), ['/a'])
  eq('nulls are skipped', CL.entryPaths({ filePaths: [null, undefined, '/a'] }), ['/a'])
  eq('a null entry', CL.entryPaths(null), [])
  eq('an undefined entry', CL.entryPaths(undefined), [])
  eq('an empty entry', CL.entryPaths({}), [])
  eq('a non-array filePaths value is ignored', CL.entryPaths({ filePaths: 'string' }), [])
  eq('an image file with a file:// scheme is expanded', CL.entryPaths({ imageFile: 'file:///tmp/i.png' }), ['/tmp/i.png'])
  eq('a snapshot with a file:// scheme is expanded', CL.entryPaths({ imageDataFile: 'file:///tmp/s.png' }), ['/tmp/s.png'])
  eq('duplicates are NOT removed', CL.entryPaths({ imageFile: '/a', filePaths: ['/a'] }), ['/a', '/a'])
  eq('a uri-list with one bad line still yields the good ones', CL.entryPaths({ filePaths: ['file:///a.png\nrelative'] }), ['/a.png'])
  eq('a file:// uri with a leading dash is still a path', CL.entryPaths({ filePaths: ['file://-rf'] }), [])
  noThrow('an entry with a 40-slot uri-list', () => CL.entryPaths({ filePaths: [new Array(40).fill('file:///a.png').join('\n')] }))
  eq('and that list yields 40 paths', CL.entryPaths({ filePaths: [new Array(40).fill('file:///a.png').join('\n')] }).length, 40)
})

group('exportEntry - a credential is written only as a tombstone', () => {
  // "A credential is written only as a tombstone: a live one has a payload in
  // memory that no key can protect on disk, and an unavailable one is kept so
  // the row stays visible in the list."
  const liveSecret = CL.newEntry('a', 1, 'SECRET', 'text/plain', 'secret', [], 'PREV')
  eq('a live secret is not persisted at all', CL.exportEntry(liveSecret), null)
  const un = CL.newEntry('b', 2, 'SECRET', 'text/plain', 'secret', [], 'PREV')
  un.unavailable = true
  const o = CL.exportEntry(un)
  is('an unavailable secret is persisted as a tombstone', o, (v) => v !== null && v.unavailable === true, 'unavailable true')
  eq('with an empty raw', o.raw, '')
  eq('and an empty preview', o.preview, '')
  eq('and the type kept', o.type, 'secret')
  eq('and the id kept', o.id, 'b')
  eq('and the mime kept', o.mime, 'text/plain')
  // A non-secret row keeps its payload: that is what a text row and a
  // preview are made of.
  const t = CL.newEntry('c', 3, 'body', 'text/plain', 'text', [], 'prev')
  t.pinned = true
  t.imageW = 10
  eq('a text row keeps its raw', CL.exportEntry(t).raw, 'body')
  eq('a text row keeps its preview', CL.exportEntry(t).preview, 'prev')
  eq('a text row keeps its pin', CL.exportEntry(t).pinned, true)
  eq('a text row keeps its measured width', CL.exportEntry(t).imageW, 10)
  eq('a fresh row exports a null git payload', CL.exportEntry(t).git, null)
  const gfold = CL.newEntry('g', 4, '', 'text/uri-list', 'folder', ['/r'], '')
  gfold.git = { branch: 'main' }
  eq('a folder keeps its git verdict', CL.exportEntry(gfold).git, { branch: 'main' })
  const gbad = CL.newEntry('h', 5, '', 'text/uri-list', 'folder', ['/r'], '')
  gbad.git = 'main'
  eq('a non-object git exports null', CL.exportEntry(gbad).git, null)
  is('a text row carries no unavailable flag', CL.exportEntry(t), (v) => v.unavailable === undefined, 'no unavailable key')
  // The projection is a fixed field list, not a dump: no title, no icon, no
  // hay, no words, no secretHandle, no pathLike, no timeStr.
  eq('the projection is exactly the persisted field list', Object.keys(CL.exportEntry(t)).sort(), [
    'allFolders', 'filePaths', 'fileSize', 'folderCount', 'folderItems', 'foldersCount', 'git', 'id', 'imageDataFile',
    'imageFile', 'imageH', 'imageSha', 'imageW', 'mime', 'missing', 'missingText', 'pinned', 'preview', 'raw', 'totalSize', 'ts', 'type',
  ])
  eq('22 fields in the projection', Object.keys(CL.exportEntry(t)).length, 22)
  notContains('the projection never carries the title', JSON.stringify(CL.exportEntry(t)), '"title"')
  notContains('the projection never carries the haystack', JSON.stringify(CL.exportEntry(t)), '"hay"')
  notContains('the projection never carries the words', JSON.stringify(CL.exportEntry(t)), '"words"')
  notContains('the projection never carries the secret handle', JSON.stringify(CL.exportEntry(t)), 'secretHandle')
  notContains('the projection never carries pathLike', JSON.stringify(CL.exportEntry(t)), 'pathLike')
  notContains('the projection never carries timeStr', JSON.stringify(CL.exportEntry(t)), 'timeStr')
  // The object-raw guard is only reachable on an entry that did not come
  // through newEntry (which stringifies at construction).
  eq('an object raw is blanked on a hand-built entry', CL.exportEntry({ id: 'd', ts: 4, type: 'text', mime: 'm', pinned: false, filePaths: [], imageFile: '', imageDataFile: '', imageSha: '', foldersCount: 0, allFolders: false, imageW: 0, imageH: 0, preview: '', raw: { a: 1 } }).raw, '')
  eq('and a non-string raw is passed through', CL.exportEntry({ id: 'd2', ts: 4, type: 'text', mime: 'm', pinned: false, filePaths: [], imageFile: '', imageDataFile: '', imageSha: '', foldersCount: 0, allFolders: false, imageW: 0, imageH: 0, preview: '', raw: 42 }).raw, 42)
  eq('a missing filePaths becomes an empty array', CL.exportEntry(CL.newEntry('e', 5, 'x', 'm', 'text')).filePaths, [])
  eq('foldersCount defaults to 0', CL.exportEntry(CL.newEntry('f', 6, 'x', 'm', 'text')).foldersCount, 0)
  eq('allFolders is a strict boolean', CL.exportEntry(CL.newEntry('g', 7, 'x', 'm', 'text')).allFolders, false)
  eq('imageW defaults to 0', CL.exportEntry(CL.newEntry('h', 8, 'x', 'm', 'text')).imageW, 0)
  eq('imageSha defaults to the empty string', CL.exportEntry(CL.newEntry('h2', 8, 'x', 'm', 'text')).imageSha, '')
  eq('a secret row with a numeric raw still blanks it', CL.exportEntry(Object.assign(CL.newEntry('i', 9, 42, 'm', 'secret'), { unavailable: true })).raw, '')
  eq('a secret row with an object preview still blanks it', CL.exportEntry(Object.assign(CL.newEntry('j', 10, 'x', 'm', 'secret'), { unavailable: true, preview: { a: 1 } })).preview, '')
  eq('folderItems is carried when present', CL.exportEntry(Object.assign(CL.newEntry('k', 11, 'x', 'm', 'folder'), { folderItems: ['/a'] })).folderItems, ['/a'])
  eq('folderItems is undefined when absent', CL.exportEntry(CL.newEntry('l', 12, 'x', 'm', 'folder')).folderItems, undefined)
  eq('an unavailable non-secret row also carries the flag', CL.exportEntry(Object.assign(CL.newEntry('l2', 12, 'x', 'm', 'text'), { unavailable: true })).unavailable, true)
  eq('unavailable must be exactly true, not truthy', CL.exportEntry(Object.assign(CL.newEntry('l3', 12, 'x', 'm', 'text'), { unavailable: 1 })).unavailable, undefined)
})

group('exportEntries - the whole list', () => {
  const a = CL.newEntry('a', 1, 'S', 'text/plain', 'secret')
  const b = CL.newEntry('b', 2, 'body', 'text/plain', 'text')
  const c = CL.newEntry('c', 3, 'S', 'text/plain', 'secret')
  c.unavailable = true
  const d = CL.newEntry('d', 4, 'x', 'text/plain', 'text')
  eq('a live secret is dropped, the tombstone stays', CL.exportEntries([a, b, c, d]).map((o) => o.id), ['b', 'c', 'd'])
  eq('the order of the survivors is preserved', CL.exportEntries([d, c, b, a]).map((o) => o.id), ['d', 'c', 'b'])
  eq('null history', CL.exportEntries(null), [])
  eq('undefined history', CL.exportEntries(undefined), [])
  eq('an empty history', CL.exportEntries([]), [])
  eq('a history of only live secrets', CL.exportEntries([a, CL.newEntry('z', 9, 'S', 'm', 'secret')]), [])
  eq('the result is a fresh array', (() => { const h = [b]; const r = CL.exportEntries(h); r.push(1); return h.length })(), 1)
  eq('a large history keeps every non-secret row', CL.exportEntries(new Array(200).fill(0).map((_, i) => CL.newEntry('e' + i, i, 'x', 'm', 'text'))).length, 200)
  // The list projection is what `clipboard list` answers with, so no element
  // may carry a field the row itself would not show.
  const blob = JSON.stringify(CL.exportEntries([b, c]))
  notContains('the list carries no title', blob, '"title"')
  notContains('the list carries no icon', blob, '"icon"')
  notContains('the list carries no hay', blob, '"hay"')
  notContains('the list carries no secretHandle', blob, 'secretHandle')
  notContains('no element carries a live secret payload', blob, '"raw":"S"')
  contains('but the tombstone is there', blob, '"unavailable":true')
})

group('projectFileInfo - the anatomy a file info report lands on', () => {
  // "A single folder is the real verdict, so the plain-file guess the
  // uri-list read made is corrected."
  const f = CL.newEntry('a', 1, '', 'text/uri-list', 'file', ['/a/b'])
  const r = CL.projectFileInfo(f, { folders: 1, files: 0, innerFiles: 7, bytes: 1234 })
  eq('the entry is returned', r === f, true)
  eq('the type is corrected to folder', f.type, 'folder')
  eq('the inner file count lands', f.folderCount, 7)
  eq('the byte total lands', f.fileSize, 1234)
  eq('folderItems is initialised to an array', f.folderItems, [])
  const f2 = CL.newEntry('b', 1, '', 'text/uri-list', 'file', ['/a/b'])
  CL.projectFileInfo(f2, { folders: 0, files: 1, innerFiles: 0, bytes: 99 })
  eq('a plain file keeps its type', f2.type, 'file')
  eq('and takes the byte total', f2.fileSize, 99)
  eq('and takes no folder count', f2.folderCount, undefined)
  // "bytes > 0 ? bytes : undefined" - a zero-byte folder is "absent means
  // pending, never fake" rather than "0 B".
  eq('a zero-byte folder has no size', CL.projectFileInfo(CL.newEntry('c', 1, '', 'x', 'file', ['/a']), { folders: 1, files: 0, innerFiles: 0, bytes: 0 }).fileSize, undefined)
  eq('a zero-byte plain file also has no size', CL.projectFileInfo(CL.newEntry('c2', 1, '', 'x', 'file', ['/a']), { folders: 0, files: 1, innerFiles: 0, bytes: 0 }).fileSize, 0)
  const f4 = CL.newEntry('d', 1, '', 'x', 'file', ['/a'])
  eq('an existing folderItems is kept', CL.projectFileInfo(f4, { folders: 1, files: 0, innerFiles: 0, bytes: 1, folderItems: undefined }).folderItems, [])
  // A multi-selection "keeps its shape and gains the counts".
  const m = CL.newEntry('e', 1, '', 'text/uri-list', 'files', ['/a', '/b', '/c'])
  CL.projectFileInfo(m, { folders: 3, files: 0, innerFiles: 5, bytes: 300 })
  eq('an all-folder selection is flagged', m.allFolders, true)
  eq('the folder count lands', m.foldersCount, 3)
  eq('the inner count lands', m.folderCount, 5)
  eq('the total size lands', m.totalSize, 300)
  eq('the type stays files', m.type, 'files')
  const m2 = CL.newEntry('f', 1, '', 'x', 'files', ['/a', '/b', '/c'])
  CL.projectFileInfo(m2, { folders: 1, files: 2, innerFiles: 2, bytes: 10 })
  eq('a mixed selection is not all folders', m2.allFolders, false)
  // "if (entry.type !== \"image\" && entry.type !== \"archive\")" - an image or
  // an archive keeps its own type even inside a multi-selection.
  const m3 = CL.newEntry('g', 1, '', 'image', 'image', ['/a.png', '/b.png'])
  CL.projectFileInfo(m3, { folders: 1, files: 1, innerFiles: 2, bytes: 10 })
  eq('an image multi-selection keeps its type', m3.type, 'image')
  const m4 = CL.newEntry('h', 1, '', 'archive', 'archive', ['/a.zip', '/b'])
  CL.projectFileInfo(m4, { folders: 1, files: 1, innerFiles: 2, bytes: 10 })
  eq('an archive multi-selection keeps its type', m4.type, 'archive')
  const m5 = CL.newEntry('i', 1, '', 'folder', 'folder', ['/a', '/b'])
  CL.projectFileInfo(m5, { folders: 1, files: 1, innerFiles: 2, bytes: 10 })
  eq('a folder multi-selection is retyped to files', m5.type, 'files')
  const m6 = CL.newEntry('j', 1, '', 'secret', 'secret', ['/a', '/b'])
  CL.projectFileInfo(m6, { folders: 1, files: 1, innerFiles: 2, bytes: 10 })
  eq('a secret multi-selection is retyped to files too', m6.type, 'files')
  eq('a one-path entry does not gain foldersCount', CL.projectFileInfo(CL.newEntry('k', 1, '', 'x', 'file', ['/a']), { folders: 0, files: 1, innerFiles: 0, bytes: 1 }).foldersCount, 0)
  eq('a one-path entry does not gain totalSize', CL.projectFileInfo(CL.newEntry('l', 1, '', 'x', 'file', ['/a']), { folders: 0, files: 1, innerFiles: 0, bytes: 1 }).totalSize, undefined)
  eq('a one-path entry does not gain allFolders', CL.projectFileInfo(CL.newEntry('l2', 1, '', 'x', 'file', ['/a']), { folders: 0, files: 1, innerFiles: 0, bytes: 1 }).allFolders, false)
  noThrow('a two-path entry with an empty report', () => CL.projectFileInfo(CL.newEntry('m', 1, '', 'x', 'files', ['/a', '/b']), { folders: 0, files: 0, innerFiles: 0, bytes: 0 }))
  eq('an empty report on a multi-selection flags nothing', CL.projectFileInfo(CL.newEntry('n', 1, '', 'x', 'files', ['/a', '/b']), { folders: 0, files: 0, innerFiles: 0, bytes: 0 }).allFolders, false)
  eq('an empty report still zeroes foldersCount', CL.projectFileInfo(CL.newEntry('n2', 1, '', 'x', 'files', ['/a', '/b']), { folders: 0, files: 0, innerFiles: 0, bytes: 0 }).foldersCount, 0)
  eq('projectFileInfo always returns the entry', (() => { const x = CL.newEntry('o', 1, '', 'x', 'files', ['/a']); return CL.projectFileInfo(x, { folders: 0, files: 1, innerFiles: 0, bytes: 1 }) === x })(), true)
})

group('the derived row and the exported row cannot disagree about a secret', () => {
  // The end-to-end statement of the credential contract: a row built the way
  // Clipboard.qml builds one (raw "", preview "") has a generic title, a
  // generic subtext, a haystack with no payload, and no persisted form.
  CL.setHome(HOME)
  const secret = CL.newEntry('s', TS, '', 'application/x-keepassxc', 'secret', [], '')
  const d = CL.deriveEntry(secret)
  eq('the type stays secret through deriveEntry', d.type, 'secret')
  eq('the title is generic', d.title, 'Sensitive content')
  eq('the subtext says hidden', d.subLeft, 'Credentials • Hidden')
  eq('the icon is the lock', d.icon, 'lock')
  notContains('the haystack has no payload', d.hay, 'hunter2')
  eq('the haystack is only the generic hints', d.hay, 'sensitive content credentials • hidden application/x-keepassxc secret password')
  eq('the raw is still empty, as the service built it', d.raw, '')
  eq('the preview is still empty', d.preview, '')
  eq('there is no persisted form at all', CL.exportEntry(d), null)
  eq('and none from the list projection either', CL.exportEntries([d]), [])
  // A text row is the only type whose title is derived from its content, so
  // it is also the only one that can look like a credential on screen.
  const text = CL.deriveEntry(CL.newEntry('t', TS, 'my password is 1234', 'text/plain', 'text'))
  eq('a text row does title its content', text.title, 'my password is 1234')
  eq('but it is not a secret row', text.type, 'text')
  eq('and it is exported with its content', CL.exportEntry(text).raw, 'my password is 1234')
  // hayFor is a pure function of the fields it is given: it excludes `raw`
  // for every type, and the only field that could carry a secret into the
  // index is `preview` - which the service never sets on a secret row.
  eq('raw is excluded from the hay for a secret row too', CL.hayFor({ title: 't', type: 'secret', raw: 'hunter2' }).indexOf('hunter2'), -1)
  // The credential transport is the only copy path, and its argv is fixed.
  eq('the only credential copy command is the sensitive stdin job', CL.buildCopySecretCmd(), ['wl-copy', '-n', '--sensitive', '--type', 'text/plain'])
})

// ===========================================================================
section('ClipboardLib - the contracts it upholds on its own')
// ===========================================================================

group('the library reads no host global and no clock of its own', () => {
  // The header states it: "No Qt imports - unit-drivable" and "Nothing in
  // here may read Quickshell globals or singleton state." The loader gives
  // the lib its own vm context with only `console` and `Quickshell`, so a
  // load that already succeeded proves the no-host-global half; these calls
  // prove the functions are pure of anything ambient.
  const before = Object.keys(CL).length
  CL.detectType(['text/plain'], 'x', [])
  eq('calling the clipboard lib adds no names to its namespace', Object.keys(CL).length, before)
  eq('the same derived value twice', CL.buildSubLeft(CL.newEntry('a', 0, 'x y', 'm', 'text')), CL.buildSubLeft(CL.newEntry('b', 0, 'x y', 'm', 'text')))
  // This pair is a load-time namespace-leak guard, not an API pin: it fails if
  // evaluating the lib leaves anything behind on its own namespace. It also
  // fails if a function is legitimately added, which is the price.
  eq('a fresh load of the clipboard lib has 99 names', Object.keys(loadLib(path.join(SHELL_DIR, 'features/clipboard/ClipboardLib.js'))).length, 99)
  eq('a fresh load of the clipboard lib has 99 names', Object.keys(loadLib(path.join(SHELL_DIR, 'features/clipboard/ClipboardLib.js'))).length, 99)
  // The clipboard lib never calls Math.random outside generateKey.
  eq('and the clipboard lib only has it in generateKey', (SRC.match(/Math\.random/g) || []).length, 1)
})

group('setHome is the one piece of ambient state the library has', () => {
  // "HOME is injected by the service at boot" - so it is a setter, not a read
  // of the environment, and a suite can pin the folded copy.
  CL.setHome('/home/zz')
  eq('the new home folds', CL.homeTilde('/home/zz/a'), '~/a')
  eq('the old home no longer folds', CL.homeTilde('/home/u/a'), '/home/u/a')
  CL.setHome(HOME)
  eq('setting it back works', CL.homeTilde('/home/u/a'), '~/a')
  const e = CL.newEntry('a', 0, '', '', 'file', [])
  e.filePaths = [HOME + '/a.txt']
  CL.buildTitleSub(e)
  eq('a title picks the folded path up', e.title, '~/a.txt')
  CL.setHome(42)
  eq('a non-string home is stringified', CL.homeTilde('42/a'), '~/a')
  CL.setHome(HOME)
  eq('the final state is the fixture home', CL.homeTilde(HOME + '/a'), '~/a')
  eq('setHome returns undefined', CL.setHome(HOME), undefined)
})

group('no builder ever hands a payload on to another command', () => {
  // The clipboard lib produces argv only from names and paths. A credential is
  // the one value that must never appear in any of it, so this is a
  // whole-surface scan of the builders' output rather than a spot check.
  const argvSets = [
    CL.buildCopyTextCmd(), CL.buildCopySecretCmd(), CL.buildCopyUriListCmd(), CL.buildClearCmd(),
    CL.buildWatchCmd(), CL.buildOrphanReapCmd(), CL.buildListTypesCmd(), CL.buildPasteUriListCmd(),
    CL.buildPasteTextCmd(), CL.buildCopyUrisCmd('file:///a.png'), CL.buildImageSnapshotCmd('image/png', '/a.png'),
    CL.buildDimCmd('/a.png'), CL.buildFileInfoCmd(['/a']), CL.buildFileInfoCmd(['/a', '/b']),
    CL.buildTextProbeCmd('/a'), CL.buildMediaInfoCmd('/a.mp3'), CL.buildMkdirCmd('/a', '/b'),
    CL.buildEnsurePrivateDirsCmd('/a', '/b'), CL.buildHistoryModeCmd('/a/h'),
    CL.buildRmPathCmd('/a'), CL.buildRmPathsCmd(['/a', '/b']),
    CL.buildExistenceProbeCmd(['/a']), CL.buildOpenCmd('/a'),
  ]
  eq('no builder argv carries the credential', argvSets.filter((a) => JSON.stringify(a).indexOf('hunter2') >= 0).length, 0)
  eq('every argv is a flat array of strings', argvSets.every((a) => Array.isArray(a) && a.every((s) => typeof s === 'string')), true)
  eq('every argv has a program as its first element', argvSets.every((a) => typeof a[0] === 'string' && a[0] !== ''), true)
  // The whole set of programs is the reviewable surface the lib header claims
  // it is: "what moves here is the command line alone - the reviewable
  // statement of which binaries this feature can run".
  eq('the whole set of programs is small and reviewable', Array.from(new Set(argvSets.map((a) => a[0]))).sort().join(','), 'app2unit,chmod,install,mkdir,rm,sh,wl-copy,wl-paste')
  // The only shell in the set is `sh -c`, and every one of those fragments has
  // a fixed skeleton for a benign and a hostile path.
  const shells = argvSets.filter((a) => a[0] === 'sh')
  eq('the sh fragments are the URI copy, the five probes, the no-op and the reap', shells.length, 9)
  eq('every sh fragment is argv[0..1] = sh -c', shells.every((a) => a[1] === '-c' && a.length === 3), true)
  eq('wl-copy and wl-paste are the only wayland binaries', argvSets.filter((a) => a[0].indexOf('wl-') === 0).every((a) => a[0] === 'wl-copy' || a[0] === 'wl-paste'), true)
  eq('no builder ever names a shell interpreter other than sh', argvSets.flat().filter((s) => s === 'bash' || s === 'zsh' || s === 'python' || s === 'eval').length, 0)
})

group('snapshotPath - a unique destination per capture', () => {
  // "Unique destination per capture: history previews never mutate under an
  // existing entry, and the sequence keeps two snapshots inside the same
  // millisecond apart."
  eq('a webp snapshot', CL.snapshotPath('/tmp/imgs', 1727000000123, 4, 'image/webp'), '/tmp/imgs/t1727000000123-4.webp')
  eq('a png snapshot', CL.snapshotPath('/tmp/imgs', 1, 2, 'image/png'), '/tmp/imgs/t1-2.png')
  // The extension is the mime's subtype, so a malformed mime silently becomes
  // a .png rather than a file with no extension.
  eq('a mime with no subtype falls back to png', CL.snapshotPath('/tmp/imgs', 1, 2, 'weird'), '/tmp/imgs/t1-2.png')
  eq('an empty mime falls back to png', CL.snapshotPath('/tmp/imgs', 1, 2, ''), '/tmp/imgs/t1-2.png')
  eq('a subtype with a plus sign maps to its base extension', CL.snapshotPath('/tmp/imgs', 1, 2, 'image/svg+xml'), '/tmp/imgs/t1-2.svg')
  eq('only the first slash of the mime is used', CL.snapshotPath('/tmp/imgs', 1, 2, 'a/b/c'), '/tmp/imgs/t1-2.b')
  // The sequence is what keeps two captures in the same millisecond apart.
  ne('two sequences in the same millisecond differ', CL.snapshotPath('/tmp/imgs', 5, 1, 'image/png'), CL.snapshotPath('/tmp/imgs', 5, 2, 'image/png'))
  ne('two timestamps in the same sequence differ', CL.snapshotPath('/tmp/imgs', 5, 1, 'image/png'), CL.snapshotPath('/tmp/imgs', 6, 1, 'image/png'))
  eq('the timestamp and sequence are joined with a dash', CL.snapshotPath('/d', 12, 34, 'image/png'), '/d/t12-34.png')
  eq('the directory is concatenated verbatim', CL.snapshotPath('/d', 1, 2, 'image/png'), '/d/t1-2.png')
  eq('a directory without a trailing slash joins with one', CL.snapshotPath('/d', 1, 2, 'image/png').indexOf('//'), -1)
  eq('a directory WITH a trailing slash doubles it', CL.snapshotPath('/a/b/', 1, 2, 'image/png'), '/a/b//t1-2.png')
  eq('an undefined mime has no subtype, so it falls back to png', CL.snapshotPath('/d', 1, 2, undefined), '/d/t1-2.png')
  eq('a null mime is the same', CL.snapshotPath('/d', 1, 2, null), '/d/t1-2.png')
  eq('a zero timestamp and sequence', CL.snapshotPath('/d', 0, 0, 'image/png'), '/d/t0-0.png')
})

group('every snapshot extension the library can mint is a real image mime', () => {
  // snapshotPath derives the file extension from the mime the snapshot was
  // taken with, and the image branch of buildTitleSub reads it back through
  // prettyImageName/extIconName - so a subtype outside the table would produce
  // a file the row could not describe.
  for (const mime of ['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/bmp', 'image/tiff', 'image/avif', 'image/heic', 'image/heif']) {
    const path = CL.snapshotPath('/tmp/imgs', 1, 1, mime)
    const ext = CL.extOf(path)
    eq(`${mime} mints .${ext}`, ext, mime.split('/')[1])
    eq(`${mime} is a previewable image extension`, CL.isImageExt(path), true)
    eq(`${mime} resolves back to its mime`, CL.mimeForExt(path), mime)
  }
  // FIXED: image/svg+xml maps to "svg" through MIME_EXT, so every minted
  // extension is previewable and resolves back through the image tables.
  const svg = CL.snapshotPath('/tmp/imgs', 1, 1, 'image/svg+xml')
  eq('image/svg+xml mints a plain svg extension', CL.extOf(svg), 'svg')
  eq('and that extension is a previewable image', CL.isImageExt(svg), true)
  eq('so mimeForExt resolves back to svg', CL.mimeForExt(svg), 'image/svg+xml')
  eq('and extIconName has the svg icon for it', CL.extIconName(svg), 'file-svg')
  eq('while the row itself still gets the svg icon', (() => {
    const e = CL.newEntry('x', 1, '', 'image/svg+xml', 'image', [])
    e.imageDataFile = svg
    CL.buildTitleSub(e)
    return e.icon
  })(), 'file-svg')
  eq('and prettyImageName shows the base subtype', CL.prettyImageName({ filePaths: [svg], mime: 'image/svg+xml' }), 'SVG')
})

group('the published extension tables, read from the source', () => {
  // The tables are `const`, so they are not part of the library's exported
  // namespace (a .pragma library's public surface is its top-level var/function
  // declarations). They are read from the source text instead, which is the
  // sanctioned way to pin a declared contract the namespace does not export.
  const counts = {
    ICONS: 20, ARCHIVE_EXTS: 11, IMAGE_EXTS: 12, VIDEO_EXTS: 6, MUSIC_EXTS: 13,
    SHEET_EXTS: 5, DB_EXTS: 6, FONT_EXTS: 7, PDF_EXTS: 1, IMAGE_MIMES: 12,
    NETWORK_SCHEMES: 15, NETWORK_PROTO_LABELS: 15,
  }
  for (const [name, n] of Object.entries(counts)) {
    eq(`${name} has ${n} keys`, tableKeys(name).length, n)
  }
  eq('CODE_EXTS is large', tableKeys('CODE_EXTS').length, 90)
  for (const name of Object.keys(counts).concat(['CODE_EXTS'])) {
    const keys = tableKeys(name)
    is(`${name} has no empty key`, keys, (k) => k.indexOf('') === -1, 'no empty key')
    is(`${name} keys are lowercase`, keys, (k) => k.every((x) => x === x.toLowerCase()), 'all lowercase')
    is(`${name} has no duplicate keys`, keys, (k) => new Set(k).size === k.length, 'no duplicates')
  }
  // IMAGE_MIMES keys are the image extensions, so mimeForExt covers exactly
  // what isImageExt accepts.
  eq('IMAGE_MIMES and IMAGE_EXTS are the same key set', tableKeys('IMAGE_MIMES').slice().sort(), tableKeys('IMAGE_EXTS').slice().sort())
  eq('every image mime is served as an image/* value', tableKeys('IMAGE_MIMES').every((k) => /^image\//.test(CL.mimeForExt('x.' + k))), true)
  eq('and the twelve keys map to at least eight distinct values', new Set(tableKeys('IMAGE_MIMES').map((k) => CL.mimeForExt('x.' + k))).size >= 8, true)
  eq('NETWORK_PROTO_LABELS covers every network scheme', tableKeys('NETWORK_PROTO_LABELS').slice().sort(), tableKeys('NETWORK_SCHEMES').slice().sort())
  // The image and video tables must not overlap, or one icon would shadow the
  // other in extIconName's if-chain.
  eq('the image table has no overlap with the video table', tableKeys('IMAGE_EXTS').filter((k) => tableKeys('VIDEO_EXTS').indexOf(k) >= 0).length, 0)
  eq('the music table has no overlap with the video table', tableKeys('MUSIC_EXTS').filter((k) => tableKeys('VIDEO_EXTS').indexOf(k) >= 0).length, 0)
  eq('the music table has no overlap with the image table', tableKeys('MUSIC_EXTS').filter((k) => tableKeys('IMAGE_EXTS').indexOf(k) >= 0).length, 0)
  eq('every code extension is distinct from the media tables', tableKeys('CODE_EXTS').filter((k) => tableKeys('MUSIC_EXTS').indexOf(k) >= 0 || tableKeys('VIDEO_EXTS').indexOf(k) >= 0).length, 0)
  // The buildMediaInfoCmd case arm has to agree with the two media tables, or
  // the JS gate and the shell gate disagree about the same file.
  const arm = body(CL.buildMediaInfoCmd('/a.mp3'))
  const armExts = (arm.match(/\*\.[a-z0-9]+/g) || []).map((t) => t.substring(2))
  eq('the case arm lists exactly the media tables, in order', armExts, tableKeys('MUSIC_EXTS').concat(tableKeys('VIDEO_EXTS')))
  eq('and the arm is closed with a catch-all exit', /\*\) exit 1;; esac;/.test(arm), true)
})

group('the totality gaps that are pinned rather than papered over', () => {
  // A handful of functions read a field or a string method off their argument
  // without a guard, so a nullish argument throws. The callers always pass a
  // real object, so these are named here rather than left to fail somewhere
  // else. If any of them starts throwing for a value the pipeline can
  // produce, the line below is the one that fails.
  const gaps = [
    ['ClipboardLib.prettyImageName(undefined)', () => CL.prettyImageName(undefined), /filePaths/],
    ['ClipboardLib.mediaInfoRows(undefined)', () => CL.mediaInfoRows(undefined), /audio/],
    ['ClipboardLib.searchEntries(null, q)', () => CL.searchEntries(null, 'a'), /length/],
  ]
  for (const [label, fn, pattern] of gaps) {
    throws(label, fn, pattern)
  }
  // The empty-object forms DO work, which is what the pipeline actually holds.
  noThrow('mediaInfoRows on {}', () => CL.mediaInfoRows({}))
  noThrow('prettyImageName on {}', () => CL.prettyImageName({}))
  noThrow('searchEntries on []', () => CL.searchEntries([], 'a'))
})

finish()