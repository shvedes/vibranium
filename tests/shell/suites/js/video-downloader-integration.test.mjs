#!/usr/bin/env node
// Suite: video-downloader-integration - the downloader's data contract.
//
// The committed suite pins the shapes the island reads. This one is the
// unforgiving complement: boundary arithmetic, hostile-but-real yt-dlp output,
// sort invariants under fuzz, and the round trip from a listed table through
// the selector the wrapper records back into the already-downloaded marks.
//
// A failure here is a behaviour the island depends on, not a formatting
// preference: absent values must stay absent under both sort directions,
// fillers must never become picks, and a URL spelling must key the same thing
// on both sides of the CLI.
import path from 'node:path'
import fs from 'node:fs'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, ne, is, noThrow, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const DL = loadLib(path.join(SHELL, 'features/bar/modules/Downloader/DownloadsLib.js'))
const TS = loadLib(path.join(SHELL, 'common/collections/TableSort.js'))

suite('video-downloader-integration', 'boundaries, fuzz and the cross-component round trip')

const info = [
  '[youtube] Extracting URL: https://youtu.be/x',
  'ID      EXT   RESOLUTION FPS CH |   FILESIZE    TBR PROTO | VCODEC           VBR ACODEC      ABR ASR MORE INFO',
  '---------------------------------------------------------------------------------------------------------------------------',
  'sb3     mhtml 48x27        0    |                   mhtml | images                                   storyboard',
  '233     mp4   audio only        |                   m3u8  | audio only           unknown             Default, low',
  '140     m4a   audio only      2 |    3.69MiB    49k https | audio only           mp4a.40.5   49k 22k low, m4a_dash',
  '602     mp4   256x144     15    | ~  7.06MiB    93k m3u8  | vp09.00.10.08    93k video only',
  '160     mp4   256x144     30    |    4.12MiB    55k https | avc1.4D400C      55k video only          144p, mp4_dash',
  '18      mp4   640x360     30    |    9.24MiB  1500k https | avc1.42001E  96k mp4a.40.2  96k 44k medium',
  '137     mp4   1920x1080   30    |   78.41MiB  1500k https | avc1.640028  1500k video only          1080p, mp4_dash',
  '22      mp4   1280x720    30    |   39.02MiB  1500k https | avc1.64001F  96k mp4a.40.2  96k 44k medium'
].join('\n')

section('yt-dlp table shapes')
group('real rows beyond the committed fixture', () => {
  const rows = DL.parseInfo(info)
  eq('eight format rows, storyboard included', rows.length, 8)
  eq('a GiB-class size', DL.parseInfo(
    '1  mp4  7680x4320  60 | 1.21GiB 1k https | avc1 video only')[0].size, '1.21GiB')
  eq('an Unknown size is not a size', DL.parseInfo(
    '2  webm 1920x1080  60 | Unknown 1k https | vp9 video only')[0].size, '')
  eq('a size without a unit is not a size', DL.parseInfo(
    '3  webm 1920x1080  60 | 78.41 1k https | vp9 video only')[0].size, '')
  eq('CRLF output parses', DL.parseInfo(
    'ID EXT RESOLUTION\r\n18 mp4 640x360 30 | 9.24MiB https | avc1 mp4a\r\n')
    .map(r => r.id).join(','), '18')
  eq('CRLF leaves no carriage return in the id', DL.parseInfo(
    '18 mp4 640x360 30 | 9.24MiB https | avc1 mp4a\r\n')[0].id, '18')
  eq('CRLF leaves no carriage return in the note', DL.parseInfo(
    '18 mp4 640x360 30 | 9.24MiB https | avc1 mp4a\r\n')[0].note, 'avc1 mp4a')
  eq('a leading tab is whitespace', DL.parseInfo(
    '\t18\tmp4\t640x360\t30\t|\t9.24MiB\thttps\t|\tavc1')[0].id, '18')
  eq('a row with only an id still yields a row', DL.parseInfo('abc')[0].id, 'abc')
  eq('a blank line yields no row', DL.parseInfo('\n\n').length, 0)
  eq('progress lines are skipped', DL.parseInfo(
    '[download] 10% of 3.69MiB at 1MiB/s\n[youtube] x').length, 0)
  eq('a separator is skipped', DL.parseInfo('---').length, 0)
})

group('every pickable row is a real pick', () => {
  const rows = DL.pickableFormats(info)
  is('all rows have an id', rows, list => list.every(r => String(r.id) !== ''), 'nonempty ids')
  is('all rows have an ext', rows, list => list.every(r => String(r.ext) !== ''), 'nonempty ext')
  is('no storyboard survives', rows, list => list.every(r => !String(r.id).startsWith('sb')), 'no sb')
  is('no mhtml survives', rows, list => list.every(r => r.ext !== 'mhtml'), 'no mhtml')
  is('sizes are unit-bearing or empty', rows, list => list.every(r =>
    r.size === '' || /^\d+(?:\.\d+)?(?:B|KiB|MiB|GiB|TiB)$/.test(r.size)), 'size grammar')
  is('kinds are one of three', rows, list => list.every(r =>
    ['audio', 'video', 'both'].includes(r.kind)), 'kind set')
  eq('the fetch order is yt-dlp\'s', rows.map(r => r.id).join(','), '233,140,602,160,18,137,22')
})

section('comparison arithmetic')
group('resolutionPixels', () => {
  eq('1080p pixels', DL.resolutionPixels({ resolution: '1920x1080' }), 1920 * 1080)
  eq('a square', DL.resolutionPixels({ resolution: '100x100' }), 10000)
  eq('audio is not geometry', DL.resolutionPixels({ resolution: 'audio' }), 0)
  eq('a bare height is not geometry', DL.resolutionPixels({ resolution: '1080p' }), 0)
  eq('an empty resolution', DL.resolutionPixels({}), 0)
  eq('no row', DL.resolutionPixels(null), 0)
})
group('sizeBytes', () => {
  eq('bytes', DL.sizeBytes('512B'), 512)
  eq('kib', DL.sizeBytes('2KiB'), 2048)
  eq('mib', DL.sizeBytes('1.5MiB'), 1.5 * 1048576)
  eq('gib', DL.sizeBytes('2GiB'), 2 * 1073741824)
  eq('tib', DL.sizeBytes('1TiB'), 1099511627776)
  eq('zero is a real size', DL.sizeBytes('0B'), 0)
  eq('a missing unit is unknown', DL.sizeBytes('78.41'), -1)
  eq('the tilde is not part of the size', DL.sizeBytes('~7MiB'), -1)
  eq('nothing is unknown', DL.sizeBytes(''), -1)
  eq('no row is unknown', DL.sizeBytes(null), -1)
})

section('sort contract')
// sort_value is the same function the comparator uses, so the invariant below
// checks the actual projection rather than re-implementing it.
const KEYS = ['resolution', 'fps', 'format', 'kind', 'size']

function rowsForFuzz() {
  let seed = 0x5eed1234
  const rand = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0
    return seed / 0x100000000
  }
  const pick = (a) => a[Math.floor(rand() * a.length)]
  const out = []
  for (let i = 0; i < 240; i++) {
    const kind = pick(['audio', 'video', 'both', 'other'])
    const res = kind === 'audio' ? 'audio' : pick(['256x144', '640x360', '1280x720',
      '1920x1080', '3840x2160', ''])
    out.push({
      id: 'f' + i,
      ext: pick(['mp4', 'webm', 'm4a', 'opus', '']),
      resolution: res,
      fps: pick([0, 15, 24, 30, 60]),
      kind: kind,
      size: pick(['', '1MiB', '3.69MiB', '78.41MiB', '1.21GiB', '0B', '512KiB'])
    })
  }
  return out
}

group('ascending and descending are permutations with a known prefix', () => {
  const rows = rowsForFuzz()
  for (const key of KEYS) {
    for (const dir of ['asc', 'desc']) {
      const label = key + ' ' + dir
      const sorted = DL.sortFormats(rows, key, dir)
      eq(label + ': nothing is lost', sorted.length, rows.length)
      eq(label + ': ids are a permutation',
        sorted.map(r => r.id).slice().sort().join(','),
        rows.map(r => r.id).slice().sort().join(','))
      const values = sorted.map(r => DL.sortValue(r, key))
      const knownCount = values.filter(v => v !== -1 && v !== '').length
      const known = values.slice(0, knownCount)
      const unknown = values.slice(knownCount)
      is(label + ': unknowns are a tail',
        unknown, list => list.every(v => v === -1 || v === ''), 'tail is unknown')
      let monotone = true
      for (let i = 1; i < known.length; i++) {
        const a = known[i - 1]
        const b = known[i]
        const d = typeof a === 'number' && typeof b === 'number' ? a - b : (a < b ? -1 : (a > b ? 1 : 0))
        if (dir === 'asc' ? d > 0 : d < 0) monotone = false
      }
      is(label + ': the known prefix is monotone', monotone, v => v === true, 'monotone')
    }
  }
})

group('ties and idempotence', () => {
  const rows = [
    { id: 'a', resolution: '1920x1080', fps: 30, kind: 'video', size: '1MiB', ext: 'mp4' },
    { id: 'b', resolution: '1920x1080', fps: 30, kind: 'video', size: '1MiB', ext: 'mp4' },
    { id: 'c', resolution: '1920x1080', fps: 30, kind: 'video', size: '1MiB', ext: 'mp4' }
  ]
  eq('equal rows keep arrival order ascending',
    DL.sortFormats(rows, 'resolution', 'asc').map(r => r.id).join(''), 'abc')
  eq('equal rows keep arrival order descending',
    DL.sortFormats(rows, 'resolution', 'desc').map(r => r.id).join(''), 'abc')
  const unsorted = rowsForFuzz()
  for (const key of KEYS) {
    const once = DL.sortFormats(unsorted, key, 'desc')
    const twice = DL.sortFormats(once, key, 'desc')
    eq('sorting twice is sorting once (' + key + ')',
      twice.map(r => r.id).join(','), once.map(r => r.id).join(','))
  }
  eq('an unknown key changes nothing',
    DL.sortFormats(unsorted, 'nope', 'desc').map(r => r.id).join(','),
    unsorted.map(r => r.id).join(','))
  eq('the input array is not reordered',
    unsorted.map(r => r.id).join(','), rowsForFuzz().map(r => r.id).join(','))
})

group('the unknown tail never wins', () => {
  const rows = [
    { id: 'nores', kind: 'audio', resolution: 'audio' },
    { id: 'small', kind: 'video', resolution: '256x144' },
    { id: 'big', kind: 'video', resolution: '3840x2160' }
  ]
  eq('resolution asc starts with the small row',
    DL.sortFormats(rows, 'resolution', 'asc').map(r => r.id).join(','), 'small,big,nores')
  eq('resolution desc starts with the big row',
    DL.sortFormats(rows, 'resolution', 'desc').map(r => r.id).join(','), 'big,small,nores')
  const sizes = [
    { id: 'none', size: '' },
    { id: 'zero', size: '0B' },
    { id: 'mib', size: '1MiB' }
  ]
  eq('a zero-byte row is known and last ascending',
    DL.sortFormats(sizes, 'size', 'asc').map(r => r.id).join(','), 'zero,mib,none')
  eq('a zero-byte row is known and first descending',
    DL.sortFormats(sizes, 'size', 'desc').map(r => r.id).join(','), 'mib,zero,none')
})

section('row window and cells')
group('rowWindow', () => {
  const live = [{ id: 'a' }, { id: 'b' }]
  const padded = DL.rowWindow(live, 5)
  eq('pads to the window', padded.length, 5)
  eq('the live rows lead', padded.slice(0, 2).map(r => r.id).join(','), 'a,b')
  is('the whole pad is filler', padded.slice(2), list => list.every(DL.isFiller), 'filler')
  eq('the input is not mutated', live.length, 2)
  eq('a full window is returned as is', DL.rowWindow(live, 2).length, 2)
  eq('a longer set stays whole', DL.rowWindow([1, 2, 3], 2).length, 3)
  eq('a zero window still returns the rows', DL.rowWindow(live, 0).length, 2)
  eq('an empty window pads', DL.rowWindow([], 3).length, 3)
  eq('a null row is a filler', DL.isFiller(null), true)
  eq('a non-object row is a filler', DL.isFiller('x'), true)
  eq('an object without the flag is live', DL.isFiller({ id: 'x' }), false)
  eq('an explicit false is live', DL.isFiller({ filler: false }), false)
})

group('a filler is never a pick', () => {
  const filler = DL.rowWindow([], 1)[0]
  eq('no label', DL.formatLabel(filler), '')
  eq('no fps', DL.fpsLabel(filler), '')
  eq('no ext', DL.extLabel(filler), '')
  eq('no kind', DL.kindLabel(filler), '')
  eq('no size', DL.cellLabel(undefined), '-')
  eq('no selector', DL.downloadSelector(filler), '')
  eq('plain colour', DL.filetypeKey(filler.ext), 'foreground_1')
  eq('plain kind colour', DL.kindKey(filler), 'foreground_1')
})

group('labels', () => {
  eq('an audio row has no resolution cell', DL.formatLabel(
    { resolution: 'audio', kind: 'audio' }), '-')
  eq('a video row keeps its geometry', DL.formatLabel(
    { resolution: '1920x1080', kind: 'video' }), '1920x1080')
  eq('fps is a bare number', DL.fpsLabel({ fps: '60' }), '60')
  eq('a negative fps is absent', DL.fpsLabel({ fps: -30 }), '-')
  eq('NaN fps is absent', DL.fpsLabel({ fps: 'nope' }), '-')
  eq('ext is trimmed', DL.extLabel({ ext: ' mp4 ' }), 'mp4')
  eq('kind labels stay distinct', [
    DL.kindLabel({ kind: 'audio' }),
    DL.kindLabel({ kind: 'video' }),
    DL.kindLabel({ kind: 'both' })
  ].join('|'), 'a|v+a|a+v')
  eq('a video-only row gains audio in the selector', DL.downloadSelector(
    { id: ' 137 ', kind: 'video' }), '137+bestaudio/137')
  eq('a both row is plain', DL.downloadSelector({ id: '18', kind: 'both' }), '18')
  eq('an empty id has no selector', DL.downloadSelector({ id: '  ', kind: 'video' }), '')
})

section('column arithmetic')
group('formatColumns', () => {
  const caps = { minKind: 32, minSize: 46, sizeCap: 96 }
  for (const [kindW, sizeW, vp, chrome] of [
    [0, 0, 352, 34], [12, 39, 352, 34], [40, 100, 352, 34], [400, 400, 352, 34],
    [10, 50, 320, 28], [60, 20, 352, 34]
  ]) {
    const c = DL.formatColumns(kindW, sizeW, vp, chrome, caps)
    is('widths are finite numbers', c, v => Number.isFinite(v.kind) && Number.isFinite(v.size), 'finite')
    is('widths are whole pixels', c, v => Number.isInteger(v.kind) && Number.isInteger(v.size), 'integer')
    is('the size floor holds', c, v => v.size >= caps.minSize, 'size floor')
    is('the size cap holds', c, v => v.size <= caps.sizeCap, 'size cap')
    is('the kind floor holds', c, v => v.kind >= caps.minKind, 'kind floor')
    is('measured content is not truncated below its width',
      c, v => v.kind >= Math.min(kindW + 2, Math.max(caps.minKind, vp - chrome - v.size)) || kindW + 2 > vp,
      'kind fits')
  }
  eq('the two pixels of slack on a size are kept',
    DL.formatColumns(10, 40, 352, 34, caps).size, 46)
  eq('a long size clamps to the cap',
    DL.formatColumns(10, 400, 352, 34, caps).size, 96)
  eq('a wide viewport lets a measured kind through',
    DL.formatColumns(40, 50, 900, 34, caps).kind, 42)
})

section('url keys')
group('YouTube spellings agree', () => {
  const id = 'dQw4w9WgXcQ'
  for (const spelling of [
    'https://www.youtube.com/watch?v=' + id,
    'https://youtube.com/watch?v=' + id,
    'https://m.youtube.com/watch?v=' + id,
    'https://music.youtube.com/watch?v=' + id,
    'https://www.youtube.com/watch?app=desktop&v=' + id,
    'https://www.youtube.com/watch?feature=share&v=' + id,
    'https://youtu.be/' + id,
    'https://youtu.be/' + id + '/',
    'https://youtu.be/' + id + '?si=x',
    'https://www.youtube.com/shorts/' + id,
    'https://www.youtube.com/live/' + id,
    'https://www.youtube.com/embed/' + id,
    'https://www.youtube.com/v/' + id,
    'https://www.youtube-nocookie.com/embed/' + id,
    'https://www.youtube-nocookie.com/watch?v=' + id,
    'HTTPS://YOUTU.BE/' + id,
    'youtube.com/watch?v=' + id
  ]) {
    eq('keys ' + spelling, DL.urlKey(spelling), 'yt:' + id)
  }
  eq('a tracking start time is not part of the key',
    DL.urlKey('https://youtu.be/' + id + '?t=30'), 'yt:' + id)
  eq('the video id keeps its case',
    DL.urlKey('https://youtu.be/AbCdEfGhIjK'), 'yt:AbCdEfGhIjK')
  eq('two different videos never share a key',
    DL.urlKey('https://youtu.be/aaaaaaaaaaa') ===
      DL.urlKey('https://youtu.be/bbbbbbbbbbb'), false)
})

group('non-YouTube keys', () => {
  eq('the host is case-insensitive',
    DL.urlKey('https://VIMEO.com/123'), 'vimeo.com/123')
  eq('the path is case-sensitive',
    DL.urlKey('https://vimeo.com/AbC'), 'vimeo.com/AbC')
  eq('the two paths are not the same key',
    DL.urlKey('https://vimeo.com/AbC') === DL.urlKey('https://vimeo.com/abc'), false)
  eq('www is dropped', DL.urlKey('https://www.vimeo.com/123'), 'vimeo.com/123')
  eq('a trailing slash is dropped', DL.urlKey('https://vimeo.com/123///'), 'vimeo.com/123')
  eq('a query is dropped', DL.urlKey('https://vimeo.com/123?x=1'), 'vimeo.com/123')
  eq('a fragment is dropped', DL.urlKey('https://vimeo.com/123#t=3'), 'vimeo.com/123')
  eq('a bare host stays', DL.urlKey('https://vimeo.com'), 'vimeo.com')
  eq('a query with no path is not the host', DL.urlKey('https://vimeo.com?x=1'), 'vimeo.com')
  eq('a fragment with no path is not the host', DL.urlKey('https://vimeo.com#top'), 'vimeo.com')
  eq('whitespace is nothing', DL.urlKey('  \t '), '')
  eq('null is nothing', DL.urlKey(null), '')
})

section('clipboard')
group('a copied link is a link, not the sentence around it', () => {
  eq('sentence punctuation is not part of the URL',
    DL.clipboardUrl('Watch this: https://youtu.be/abc.'),
    'https://youtu.be/abc')
  eq('a comma after a link is not part of it',
    DL.clipboardUrl('see https://youtu.be/abc, then watch'),
    'https://youtu.be/abc')
  eq('a parenthesised link loses the parenthesis',
    DL.clipboardUrl('(https://youtu.be/abc)'), 'https://youtu.be/abc')
  eq('a quoted link loses the quote',
    DL.clipboardUrl('"https://youtu.be/abc"'), 'https://youtu.be/abc')
  eq('an angle-bracketed link loses the brackets',
    DL.clipboardUrl('<https://youtu.be/abc>'), 'https://youtu.be/abc')
  eq('a query survives the trailing punctuation strip',
    DL.clipboardUrl('https://youtu.be/abc?si=1&t=2.'), 'https://youtu.be/abc?si=1&t=2')
  eq('an ellipsis after a link is not part of it',
    DL.clipboardUrl('https://youtu.be/abc...'), 'https://youtu.be/abc')
  eq('only the first mainstream link is taken',
    DL.clipboardUrl('https://youtu.be/first and https://youtu.be/second'),
    'https://youtu.be/first')
  eq('a non-mainstream link is not auto-filled',
    DL.clipboardUrl('https://example.com/watch?v=1'), '')
  eq('a host suffix is not the host',
    DL.clipboardUrl('https://notyoutube.com/watch?v=1'), '')
  eq('a nested link in a query is not the token',
    DL.clipboardUrl('https://evil.example/?u=https://youtu.be/abc'), '')
  eq('a port is not a mainstream URL',
    DL.clipboardUrl('https://youtu.be:443/abc'), '')
  eq('uppercase scheme and host still match',
    DL.clipboardUrl('HTTPS://YOUTU.BE/abc'), 'HTTPS://YOUTU.BE/abc')
  eq('a tab-separated paste still finds the link',
    DL.clipboardUrl('title\thttps://youtu.be/abc'), 'https://youtu.be/abc')
  eq('an empty clipboard is empty', DL.clipboardUrl('   '), '')
})

group('the preview pane accepts any link, not only media hosts', () => {
  eq('a direct file is a paste link',
    DL.clipboardLink('https://example.com/file.pdf'), 'https://example.com/file.pdf')
  eq('a direct file inside a sentence is found',
    DL.clipboardLink('download: https://example.com/file.pdf.'), 'https://example.com/file.pdf')
  eq('an FTP file is a paste link',
    DL.clipboardLink('ftp://ftp.example.com/pub/file.iso'), 'ftp://ftp.example.com/pub/file.iso')
  eq('text with no URL is not a paste link', DL.clipboardLink('nothing here'), '')
  eq('the auto-fill filter still refuses a direct file',
    DL.clipboardUrl('https://example.com/file.pdf'), '')
})

section('middle-click PRIMARY selection')
group('only a whole link may start a background download', () => {
  eq('a bare link', DL.primaryLink('https://youtu.be/a'), 'https://youtu.be/a')
  eq('a direct file', DL.primaryLink('https://example.com/a.pdf'), 'https://example.com/a.pdf')
  eq('a bare host', DL.primaryLink('example.com/a.zip'), 'example.com/a.zip')
  eq('surrounding whitespace', DL.primaryLink('\t https://youtu.be/a \n'), 'https://youtu.be/a')
  eq('a trailing sentence mark is stripped', DL.primaryLink('https://youtu.be/a.'), 'https://youtu.be/a')
  const prose = [
    'hello world',
    'the last link was https://youtu.be/a',
    'https://youtu.be/a and then some',
    'see https://youtu.be/a',
    'https://youtu.be/a\nhttps://youtu.be/b',
    'https://youtu.be/a\tmore',
    'remember\nhttps://youtu.be/a',
    'https://youtu.be/a https://youtu.be/b',
    '   '
  ]
  is('prose never becomes a primary link', prose,
    list => list.every(t => DL.primaryLink(t) === ''), 'all empty')
  eq('the paste scan is still broader',
    DL.clipboardLink('see https://youtu.be/a'), 'https://youtu.be/a')
})

group('a middle-click verdict never aborts on unknown', () => {
  eq('an unknown verdict takes the File path',
    DL.primaryTool({ kind: 'unknown', engine: '' }), 'wget')
  eq('a missing verdict takes the File path', DL.primaryTool(null), 'wget')
  eq('a file verdict keeps aria2c',
    DL.primaryTool({ kind: 'file', engine: 'aria2c' }), 'aria2c')
  eq('a media verdict keeps yt-dlp',
    DL.primaryTool({ kind: 'media', engine: 'yt-dlp' }), 'yt-dlp')
  eq('a typed file with no engine still falls back',
    DL.primaryTool({ kind: 'file', engine: '' }), 'wget')
})

group('the QML wiring cannot fall back to the clipboard or the island', () => {
  const qml = fs.readFileSync(path.join(SHELL,
    'features/bar/modules/Downloader/Downloader.qml'), 'utf8')
  function sourceFunction(name) {
    const start = qml.indexOf('function ' + name)
    if (start < 0) return ''
    const next = qml.indexOf('\n  function ', start + 1)
    return qml.slice(start, next < 0 ? qml.length : next)
  }
  const primary = sourceFunction('downloadFromPrimary')
  const target = sourceFunction('downloadPrimaryLink')
  const playlist = sourceFunction('downloadPrimaryPlaylist')
  is('the PRIMARY reader exists', primary, s => s.includes('wl-paste'), 'wl-paste')
  is('it asks for the PRIMARY selection', primary, s => s.includes('--primary'), '--primary')
  is('it never reads the ordinary clipboard', primary,
    s => !s.includes('clipboardText') && !s.includes('clipboardLink'), 'no clipboard')
  is('the target parser is the strict one', target,
    s => s.includes('DL.primaryLink('), 'primaryLink')
  is('the middle-click target never scans prose', target,
    s => !s.includes('DL.clipboardLink('), 'no clipboardLink')
  is('an unknown verdict uses the tested File fallback', target,
    s => s.includes('DL.primaryTool('), 'primaryTool')
  is('an unknown verdict is not an abort', target,
    s => !s.includes('Not a downloadable link'), 'no abort')
  is('a playlist video is not refused', target,
    s => !s.includes('isPlaylistUrl') && !s.includes('Playlist link'),
    'no playlist refusal')
  is('every playlist shape takes the queue path', target,
    s => s.includes('DL.primaryRoute(url)') && !s.includes('isPlaylistPageUrl'),
    'primaryRoute')
  const album = 'https://www.youtube.com/watch?v=MhsUKjwH1dE&list=OLAK5uy_mwmTuYXssTxaUL-GIAQ_5gOS2fQk9O6Mg'
  eq('the reported watch+list URL is a playlist', DL.isPlaylistUrl(album), true)
  eq('the reported watch+list URL routes to the queue',
    DL.primaryRoute(album), 'playlist')
  is('a playlist page is enumerated through the CLI', playlist,
    s => s.includes('root.loadPlaylist('), 'loadPlaylist')
  is('a playlist page queues every entry through the batch path', playlist,
    s => s.includes('root.startPlaylist('), 'startPlaylist')
  const runOne = sourceFunction('runOne')
  const queue = sourceFunction('nextQueued')
  const reload = sourceFunction('reloadHistory')
  is('the playlist run records one folder row', runOne,
    s => s.includes('--playlist-history'), '--playlist-history')
  is('the queue hands the batch URL to every run', queue,
    s => s.includes('root._queueLoadUrl'), '_queueLoadUrl')
  is('history attaches the entry index', reload,
    s => s.includes('DL.attachPlaylistEntries'), 'attachPlaylistEntries')
  is('the playlist completion opens the batch folder', queue,
    s => s.includes('root.notifySaved(') && s.includes('root.lastSavedPath'),
    'lastSavedPath')
  const notify = sourceFunction('notifySaved')
  is('a missing notification target gets no action buttons', notify,
    s => s.includes('target === undefined') && s.includes('if (path === "")'),
    'plain notification')
  const island = fs.readFileSync(path.join(SHELL,
    'features/bar/modules/Downloader/DownloaderIsland.qml'), 'utf8')
  is('the Recent table is a fixed window with no scrolling', island,
    s => /id: histList[\s\S]*?contentY: 0[\s\S]*?interactive: false/.test(s)
      && !s.includes('historyScroll'),
    'recent fixed window')
  is('inert format and playlist controls show the refusal cursor', island,
    s => (s.match(/Qt\.ForbiddenCursor/g) || []).length >= 3,
    'forbidden cursors')
  is('the module keeps previews in a runtime warmer', qml,
    s => s.includes('previewWarmUrls') && s.includes('sourceSize.width: 320'),
    'runtime thumbnail warmer')
  is('the island demands and releases the preview warmer', island,
    s => s.includes('requestPreview(') && s.includes('releasePreview('),
    'preview demand')
  is('the island spinner ignores the global motion switch', island,
    s => /RotationAnimation on rotation[\s\S]*?running: root\.downloading/.test(s),
    'spinner running')
  is('the barber pole ignores the global motion switch', island,
    s => /NumberAnimation on x[\s\S]*?running: root\.downloading/.test(s),
    'pole running')
  const arch = fs.readFileSync(path.join(SHELL,
    'features/bar/modules/ArchUpdates/ArchUpdatesIsland.qml'), 'utf8')
  is('the ArchUpdates spinner ignores the global motion switch', arch,
    s => /RotationAnimation on rotation[\s\S]*?running: root\.skeleton/.test(s),
    'arch spinner running')
  is('a playlist page uses the default Best selector', playlist,
    s => s.includes('DL.qualitySelector("best")'), 'Best selector')
  is('the middle-click single-video path leaves the format to the wrapper', target,
    s => !s.includes('--format') && s.includes('startDownload(url, "", tool, true)'),
    'default format')
  const clickStart = qml.indexOf('onClicked: mouse => {')
  const click = qml.slice(clickStart, clickStart + 700)
  is('middle click branches before openIsland', click,
    s => /if \(mouse\.button === Qt\.MiddleButton\)[\s\S]*?downloadFromPrimary\(\)[\s\S]*?return/.test(s),
    'middle -> primary -> return')
})

section('video refusal detection')
group('videoUnsupported only names a link-shape refusal', () => {
  eq('an unsupported URL',
    DL.videoUnsupported('ERROR: Unsupported URL: https://example.com/file.pdf'), true)
  eq('a non-URL',
    DL.videoUnsupported('ERROR: "nope" is not a valid URL'), true)
  eq('no video formats',
    DL.videoUnsupported('ERROR: No video formats found'), true)
  eq('a plain not-a-video refusal',
    DL.videoUnsupported('That page is not a video'), true)
  eq('a network failure is not a link refusal',
    DL.videoUnsupported('ERROR: Unable to download webpage: timeout'), false)
  eq('a missing format is not a link refusal',
    DL.videoUnsupported('ERROR: Requested format is not available'), false)
  eq('nothing', DL.videoUnsupported(''), false)
  eq('null', DL.videoUnsupported(null), false)
})

section('url classification')
// The offline half of the dispatcher decision. Every row is a URL shape and
// the three values the island shows: what it is, who fetches it, and why.
function checkClassification(rows) {
  for (const [url, kind, engine, reason] of rows) {
    const label = url === '' ? '<empty>' : url
    const got = DL.classifyUrl(url)
    eq(label + ': kind', got.kind, kind)
    eq(label + ': engine', got.engine, engine)
    eq(label + ': reason', got.reason, reason)
  }
}

const MEDIA_CASES = [
  ['https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'media', 'yt-dlp', 'media host'],
  ['https://youtu.be/dQw4w9WgXcQ?si=x', 'media', 'yt-dlp', 'media host'],
  ['https://music.youtube.com/watch?v=x', 'media', 'yt-dlp', 'media host'],
  ['https://m.youtube.com/watch?v=x', 'media', 'yt-dlp', 'media host'],
  ['https://www.youtube-nocookie.com/embed/x', 'media', 'yt-dlp', 'media host'],
  ['https://youtube.com', 'media', 'yt-dlp', 'media host'],
  ['https://www.youtube.com/playlist?list=PL1', 'media', 'yt-dlp', 'media host'],
  ['https://vimeo.com/123456', 'media', 'yt-dlp', 'media host'],
  ['https://player.vimeo.com/video/123', 'media', 'yt-dlp', 'media host'],
  ['https://www.twitch.tv/videos/123', 'media', 'yt-dlp', 'media host'],
  ['https://clips.twitch.tv/abc', 'media', 'yt-dlp', 'media host'],
  ['https://soundcloud.com/a/b', 'media', 'yt-dlp', 'media host'],
  ['https://x.com/u/status/1', 'media', 'yt-dlp', 'media host'],
  ['https://twitter.com/u/status/1', 'media', 'yt-dlp', 'media host'],
  ['https://www.instagram.com/reel/abc/', 'media', 'yt-dlp', 'media host'],
  ['https://www.tiktok.com/@u/video/1', 'media', 'yt-dlp', 'media host'],
  ['https://www.reddit.com/r/a/comments/b/c/', 'media', 'yt-dlp', 'media host'],
  ['https://www.facebook.com/watch/?v=1', 'media', 'yt-dlp', 'media host'],
  ['https://fb.watch/abc/', 'media', 'yt-dlp', 'media host'],
  ['https://www.bilibili.com/video/BV1', 'media', 'yt-dlp', 'media host'],
  ['https://b23.tv/abc', 'media', 'yt-dlp', 'media host'],
  ['https://www.dailymotion.com/video/x1', 'media', 'yt-dlp', 'media host'],
  ['https://dai.ly/x1', 'media', 'yt-dlp', 'media host'],
  ['https://streamable.com/abc', 'media', 'yt-dlp', 'media host'],
  ['https://rumble.com/v1', 'media', 'yt-dlp', 'media host'],
  ['https://bsky.app/profile/u/post/1', 'media', 'yt-dlp', 'media host'],
  ['https://kick.com/u?clip=1', 'media', 'yt-dlp', 'media host'],
  ['https://www.nicovideo.jp/watch/sm1', 'media', 'yt-dlp', 'media host'],
  ['https://bandcamp.com/track/x', 'media', 'yt-dlp', 'media host'],
  ['https://www.mixcloud.com/u/x/', 'media', 'yt-dlp', 'media host'],
  ['https://odysee.com/@u:x/v', 'media', 'yt-dlp', 'media host'],
  ['https://cdn.example.com/live/index.m3u8', 'media', 'yt-dlp', 'streaming manifest'],
  ['https://cdn.example.com/movie.mpd?token=x', 'media', 'yt-dlp', 'streaming manifest'],
  ['https://cdn.example.com/LIVE.M3U8', 'media', 'yt-dlp', 'streaming manifest']
]

const FILE_CASES = [
  ['https://example.com/report.pdf', 'file', 'wget', 'direct file extension'],
  ['https://example.com/archive.tar.gz', 'file', 'wget', 'direct file extension'],
  ['https://example.com/FILE.PDF', 'file', 'wget', 'direct file extension'],
  ['https://example.com/file.pdf?token=abc', 'file', 'wget', 'direct file extension'],
  ['https://example.com/file.pdf#page=2', 'file', 'wget', 'direct file extension'],
  ['https://example.com/file.pdf;version=1', 'file', 'wget', 'direct file extension'],
  ['https://example.com/a/b/photo.JPG', 'file', 'wget', 'direct file extension'],
  ['https://example.com/app.AppImage', 'file', 'wget', 'direct file extension'],
  ['https://example.com/pkg.tar.zst', 'file', 'wget', 'direct file extension'],
  ['https://example.com/file.torrent', 'file', 'wget', 'direct file extension'],
  ['https://example.com/movie.mp4', 'file', 'wget', 'direct file extension'],
  ['https://example.com/movie.mkv', 'file', 'wget', 'direct file extension'],
  ['https://example.com/song.flac', 'file', 'wget', 'direct file extension'],
  ['https://example.com/archive.zip', 'file', 'wget', 'direct file extension'],
  ['https://example.com/pkg.deb', 'file', 'wget', 'direct file extension'],
  ['https://192.168.1.1/file.zip', 'file', 'wget', 'direct file extension'],
  ['https://user:pass@example.com/file.zip', 'file', 'wget', 'direct file extension'],
  ['https://example.com:8443/file.zip', 'file', 'wget', 'direct file extension'],
  ['example.com/file.zip', 'file', 'wget', 'direct file extension'],
  ['localhost:8080/file.zip', 'file', 'wget', 'direct file extension'],
  ['ftp://ftp.example.com/pub/file.iso', 'file', 'wget', 'ftp url'],
  ['ftps://ftp.example.com/pub/file.iso', 'file', 'aria2c', 'ftps url'],
  ['sftp://example.com/file.zip', 'file', 'aria2c', 'sftp url'],
  ['magnet:?xt=urn:btih:abc', 'file', 'aria2c', 'magnet link']
]

const UNKNOWN_CASES = [
  ['', 'unknown', '', 'empty input'],
  ['   ', 'unknown', '', 'empty input'],
  ['https://example.com/', 'unknown', '', 'needs content-type probe'],
  ['https://example.com', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/page', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/download?id=1', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/page.html', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/page?file=report.pdf', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/archive.zip/', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/.hidden', 'unknown', '', 'needs content-type probe'],
  ['https://example.com/file.', 'unknown', '', 'needs content-type probe'],
  ['https://notyoutube.com/watch?v=x', 'unknown', '', 'needs content-type probe'],
  ['https://youtube.com.evil.test/watch?v=x', 'unknown', '', 'needs content-type probe'],
  ['https://', 'unknown', '', 'missing host'],
  ['mailto:someone@example.com', 'unknown', '', 'unsupported scheme'],
  ['file:///home/u/file.zip', 'unknown', '', 'unsupported scheme'],
  ['data:text/plain,hello', 'unknown', '', 'unsupported scheme'],
  ['not a url', 'unknown', '', 'not a url'],
  ['report.pdf', 'unknown', '', 'needs content-type probe']
]

group('a known media host belongs to yt-dlp', () => checkClassification(MEDIA_CASES))
group('a named file goes straight to a file engine', () => checkClassification(FILE_CASES))
group('everything else stays unknown', () => checkClassification(UNKNOWN_CASES))

group('the decision agrees with itself', () => {
  const media = MEDIA_CASES.map(r => DL.classifyUrl(r[0]))
  const files = FILE_CASES.map(r => DL.classifyUrl(r[0]))
  is('media is always yt-dlp', media,
    list => list.every(c => c.kind === 'media' && c.engine === 'yt-dlp'),
    'media -> yt-dlp')
  is('a file never goes to yt-dlp', files,
    list => list.every(c => c.kind === 'file' && c.engine !== 'yt-dlp'),
    'file -> wget or aria2c')
  is('unknown names no engine', UNKNOWN_CASES.map(r => DL.classifyUrl(r[0])),
    list => list.every(c => c.kind === 'unknown' && c.engine === ''),
    'unknown -> no engine')
  eq('surrounding whitespace is ignored',
    DL.classifyUrl('\n https://example.com/report.pdf \t').kind, 'file')
  eq('null is empty input', DL.classifyUrl(null).reason, 'empty input')
  eq('undefined is empty input', DL.classifyUrl(undefined).reason, 'empty input')
  eq('a number is not a url', DL.classifyUrl(42).reason, 'not a url')
  eq('an object is not a url', DL.classifyUrl({}).reason, 'not a url')
})

section('file mode helpers')
group('fileName mirrors the dispatcher resolver', () => {
  const cases = [
    ['https://example.com/report.pdf', 'report.pdf'],
    ['https://example.com/Quarterly%20Report%202026.pdf', 'Quarterly Report 2026.pdf'],
    ['https://example.com/a%2Fb.pdf', 'a_b.pdf'],
    ['https://example.com/Back%5Cslash.pdf', String.raw`Back\slash.pdf`],
    ['https://example.com/file.pdf?token=abc#page=2', 'file.pdf'],
    ['https://example.com/archive.tar.gz', 'archive.tar.gz'],
    ['https://example.com/FILE.PDF', 'FILE.PDF'],
    ['https://example.com/', 'download'],
    ['https://example.com', 'download'],
    ['https://example.com/..', 'download'],
    ['ftp://ftp.example.com/pub/file.iso', 'file.iso'],
    ['example.com/file.zip', 'file.zip'],
    ['', 'download']
  ]
  for (const [url, want] of cases) eq('fileName ' + (url || '<empty>'), DL.fileName(url), want)
  eq('fileName leaves a malformed escape literal', DL.fileName('https://example.com/a%ZZb.pdf'), 'a%ZZb.pdf')
  eq('fileName caps the name at 200 chars', DL.fileName('https://example.com/' + 'x'.repeat(250)).length, 200)

  eq('savedName reads the path basename',
    DL.savedName('/home/u/Downloads/Report.pdf'), 'Report.pdf')
  eq('savedName drops a trailing slash',
    DL.savedName('/home/u/Downloads/folder/'), 'folder')
  eq('savedName does not decode a literal percent',
    DL.savedName('/home/u/Downloads/a%20b.pdf'), 'a%20b.pdf')
  eq('savedName accepts a bare filename', DL.savedName('file.zip'), 'file.zip')
  eq('savedName has no name for a root', DL.savedName('/'), '')
  eq('savedName has no name for dot-dot', DL.savedName('/tmp/..'), '')
  eq('savedName has no name for nothing', DL.savedName('   '), '')
})

group('history rows name their engine', () => {
  eq('a wget row', DL.historyEngine({ format: 'wget' }), 'wget')
  eq('an aria2c row', DL.historyEngine({ format: 'aria2c' }), 'aria2c')
  eq('a format id is the media engine', DL.historyEngine({ format: '137' }), 'yt-dlp')
  eq('an older row is the media engine', DL.historyEngine({}), 'yt-dlp')
  eq('a file row is a file', DL.isFileHistory({ format: 'wget' }), true)
  eq('a media row is not a file', DL.isFileHistory({ format: '137' }), false)
  const history = [
    { url: 'https://youtu.be/a', format: 'wget', path: '/v/a.pdf' },
    { url: 'https://youtu.be/a', format: '137', path: '/v/a.mp4' }
  ]
  eq('a file row never marks a media format',
    DL.downloadedFormats(history, 'https://youtu.be/a', []).join(','), '137')
})

section('playlists')
group('playlistEntries', () => {
  const text = [
    'Album\t1\tFirst\t3:41\thttps://x/a',
    'Album\t2\tSecond\ttabbed\ttitle\t4:02\thttps://x/b',
    'Album\t3\t\tNA\thttps://x/c',
    'Album\tNA\tUnknown index\t5:00\thttps://x/d'
  ].join('\n')
  const rows = DL.playlistEntries(text)
  eq('one row per line', rows.length, 4)
  eq('the first title', rows[0].title, 'First')
  eq('a tabbed title is rejoined', rows[1].title, 'Second tabbed title')
  eq('an empty title stays empty', rows[2].title, '')
  eq('an empty duration is reported as NA', rows[2].duration, 'NA')
  eq('an NA index falls back to the display position', rows[3].index, '4')
  eq('the url is the last field', rows[3].url, 'https://x/d')
  eq('CRLF leaves no carriage return in the url',
    DL.playlistEntries('Album\t1\tT\t1:00\thttps://x/a\r\n')[0].url, 'https://x/a')
  eq('a line with three fields is not an entry',
    DL.playlistEntries('a\tb\tc').length, 0)
  eq('a line with an empty url is not an entry',
    DL.playlistEntries('Album\t1\tT\t3:00\t').length, 0)
  eq('whitespace-only input yields nothing', DL.playlistEntries(' \n\t\n').length, 0)
  eq('null yields nothing', DL.playlistEntries(null).length, 0)
})

group('playlistTitle', () => {
  eq('the leading field names it', DL.playlistTitle('Album\t1\tT\t1:00\thttps://x/a'), 'Album')
  eq('a tab in the title does not change the name',
    DL.playlistTitle('Album\t1\tT\tab\t1:00\thttps://x/a'), 'Album')
  eq('NA is no name', DL.playlistTitle('NA\t1\tT\t1:00\thttps://x/a'), '')
  eq('a legacy listing has no name', DL.playlistTitle('1\tT\t1:00\thttps://x/a'), '')
  eq('a blank first line is skipped',
    DL.playlistTitle('\nAlbum\t1\tT\t1:00\thttps://x/a'), 'Album')
})

group('folderName', () => {
  eq('a tab becomes a space', DL.folderName('a\tb'), 'a b')
  eq('a newline becomes a space', DL.folderName('a\nb'), 'a b')
  eq('a control character becomes a space', DL.folderName('a\u0001b'), 'a b')
  eq('every path separator is gone',
    DL.folderName('a/b\\c:d*e?f"g<h>i|j'), 'a b c d e f g h i j')
  eq('a dots-only name is the fallback', DL.folderName('...'), 'Playlist')
  eq('a spaces-and-dots name is the fallback', DL.folderName(' . . '), 'Playlist')
  eq('a name of exactly 80 chars survives',
    DL.folderName('x'.repeat(80)).length, 80)
  eq('a longer name is cut to 80',
    DL.folderName('x'.repeat(80) + 'y').length, 80)
  eq('the cut never leaves a trailing dot',
    DL.folderName('x'.repeat(79) + '.y'), 'x'.repeat(79))
  eq('an apostrophe is a filename character',
    DL.folderName("the world doesn't care"), "the world doesn't care")
  eq('only whitespace is the fallback', DL.folderName('   '), 'Playlist')
})

group('quality presets', () => {
  const opts = DL.qualityOptions()
  eq('the ladder has six rungs', opts.length, 6)
  eq('the keys are the documented presets',
    opts.map(o => o.key).join(','), 'best,2160,1440,1080,720,audio')
  for (const o of opts) {
    eq('the selector of ' + o.key, DL.qualitySelector(o.key), o.selector)
    eq('the label of ' + o.key, DL.qualityLabel(o.key), o.label)
    is('the chip of ' + o.key + ' names a palette leaf',
      o.color, s => typeof s === 'string' && s !== '', 'palette leaf')
  }
  is('every cap is at or below its own height',
    opts.filter(o => /^\d+$/.test(o.key)),
    list => list.every(o => {
      const m = o.selector.match(/height<=(\d+)/)
      return m !== null && Number(m[1]) === Number(o.key)
    }), 'cap grammar')
  eq('an unknown selector falls back to best',
    DL.qualitySelector('nope'), opts[0].selector)
  eq('an unknown label falls back to best', DL.qualityLabel('nope'), opts[0].label)
  eq('the options are a fresh array', opts === DL.qualityOptions(), false)
})

section('history')
group('parseHistory', () => {
  const text = [
    '2026-11-16 21:30\tFirst\t40943092\t/home/u/First.mp4\thttps://youtu.be/a\t137',
    '2026-11-16 21:32\tSecond\t879341\t/home/u/Second.mp4\thttps://youtu.be/b',
    'short\trow',
    '',
    '2026-11-16 21:40\tThird\t1\t/home/u/Third.mp4\thttps://youtu.be/c\t18'
  ].join('\n')
  const rows = DL.parseHistory(text)
  eq('short rows are not history', rows.length, 3)
  eq('the first title', rows[0].title, 'First')
  eq('the older row has no selector', rows[1].format, '')
  eq('the third row is read', rows[2].title, 'Third')
  eq('CRLF leaves no carriage return in the path',
    DL.parseHistory('t\tTitle\t1\t/p\thttps://youtu.be/a\t137\r\n')[0].path, '/p')
  eq('CRLF leaves no carriage return in the format',
    DL.parseHistory('t\tTitle\t1\t/p\thttps://youtu.be/a\t137\r\n')[0].format, '137')
  const escaped = DL.parseHistory('t\tTabbed\\tTitle\t1\t/p\thttps://youtu.be/a\t137')[0]
  eq('an escaped tab is restored in the title', escaped.title, 'Tabbed\tTitle')
  eq('an escaped newline is restored in the title',
    DL.parseHistory('t\tLine\\nbreak\t1\t/p\thttps://youtu.be/a')[0].title,
    'Line\nbreak')
  eq('an escaped backslash is restored',
    DL.parseHistory('t\tBack\\\\slash\t1\t/p\thttps://youtu.be/a')[0].title,
    'Back\\slash')
  eq('an unknown escape stays literal',
    DL.parseHistory('t\tBack\\qslash\t1\t/p\thttps://youtu.be/a')[0].title,
    'Back\\qslash')
  eq('an empty path is still a row',
    DL.parseHistory('t\tTitle\t1\t\thttps://youtu.be/a')[0].path, '')
  eq('no text is no history', DL.parseHistory(null).length, 0)
})

group('already-downloaded marks', () => {
  const url = 'https://youtu.be/a'
  const history = [
    { url: 'https://www.youtube.com/watch?v=a', format: '137+bestaudio/137', path: '/v/a.mp4' },
    { url: 'https://youtu.be/a', format: '18', path: '/v/a18.mp4' },
    { url: 'https://youtu.be/b', format: '22', path: '/v/b.mp4' }
  ]
  eq('both spellings of the URL match', DL.downloadedFormats(history, url).join(','), '137,18')
  eq('a merged selector marks its plain row', DL.downloadedFormats(
    [history[0]], url).join(','), '137')
  eq('the latest copy of a format is the one opened',
    DL.downloadedPath(history, url, '18'), '/v/a18.mp4')
  eq('the merged selector opens its file',
    DL.downloadedPath(history, 'https://www.youtube.com/watch?v=a', '137'), '/v/a.mp4')
  eq('a gone file marks nothing for that path',
    DL.downloadedFormats(history, url, ['/v/a.mp4']).join(','), '18')
  eq('a gone file is not opened',
    DL.downloadedPath(history, url, '137', ['/v/a.mp4']), '')
  eq('a duplicate row is listed once',
    DL.downloadedFormats(history.concat([history[1]]), url).join(','), '137,18')
  eq('a row without a path is not openable',
    DL.downloadedPath([{ url: url, format: '137' }], url, '137'), '')
  eq('an empty pick is not openable', DL.downloadedPath(history, url, ''), '')
  eq('an empty URL matches nothing', DL.downloadedFormats(history, '').length, 0)
})

group('playlist held keys require a live file', () => {
  const url = 'https://youtu.be/a'
  const history = [
    { url: url, format: '137', path: '/v/a.mp4' },
    { url: 'https://youtu.be/b', format: '18', path: '/v/b.mp4' },
    { url: url, format: '137', path: '/v/a.mp4' }
  ]
  eq('a live copy is held', DL.downloadedKeys(history, []), ['yt:a', 'yt:b'])
  eq('the same video is listed once', DL.downloadedKeys(history, []).length, 2)
  eq('a deleted copy is not held',
    DL.downloadedKeys(history, ['/v/a.mp4']), ['yt:b'])
  eq('a moved copy is not held',
    DL.downloadedKeys(history, ['/v/a.mp4', '/v/b.mp4']), [])
  eq('a row without a path is not held',
    DL.downloadedKeys([{ url: url, format: '137' }], []), [])
  eq('an empty history holds nothing', DL.downloadedKeys(null, []), [])
  eq('an empty URL is not a key',
    DL.downloadedKeys([{ url: '', format: '137', path: '/v/a.mp4' }], []), [])
})

group('sizeLabel boundaries', () => {
  eq('zero bytes', DL.sizeLabel('0'), '0 B')
  eq('one byte', DL.sizeLabel('1'), '1 B')
  eq('one byte below a KiB', DL.sizeLabel('1023'), '1023 B')
  eq('exactly a KiB', DL.sizeLabel('1024'), '1 KiB')
  eq('one byte below a MiB rounds up, not to 1024 KiB',
    DL.sizeLabel('1048575'), '1.0 MiB')
  eq('exactly a MiB', DL.sizeLabel('1048576'), '1.0 MiB')
  eq('one byte below a GiB rounds up, not to 1024.0 MiB',
    DL.sizeLabel('1073741823'), '1.00 GiB')
  eq('exactly a GiB', DL.sizeLabel('1073741824'), '1.00 GiB')
  eq('a fractional raw value is passed through', DL.sizeLabel('12.5'), '12.5')
  eq('NA is passed through', DL.sizeLabel('NA'), 'NA')
  eq('yt-dlp\'s own string is passed through', DL.sizeLabel('39.02MiB'), '39.02MiB')
})

section('cross-component round trip')
group('a fetched row becomes a marked row', () => {
  const rows = DL.pickableFormats(info)
  const picked = rows.find(r => r.id === '137')
  const selector = DL.downloadSelector(picked)
  eq('the video-only pick merges its audio', selector, '137+bestaudio/137')
  const url = 'https://youtu.be/roundtrip'
  const history = [{ timestamp: 't', title: 'T', size: '1', path: '/v/out.mp4',
    url: 'https://www.youtube.com/watch?v=roundtrip', format: selector }]
  eq('the id is recovered from the recorded selector',
    DL.downloadedFormats(history, url).join(','), '137')
  eq('and the recorded file is the one opened',
    DL.downloadedPath(history, url, '137'), '/v/out.mp4')
  eq('the sorted table keeps the pick findable',
    DL.sortFormats(rows, 'size', 'asc').some(r => r.id === '137'), true)
  const audio = rows.find(r => r.id === '140')
  eq('an audio pick is recorded alone', DL.downloadSelector(audio), '140')
})

section('hostile input')
group('every parser tolerates a bad argument', () => {
  const junk = [null, undefined, '', ' ', 0, 1, 'x', [], {}, true]
  for (const v of junk) {
    noThrow('parseInfo(' + String(v) + ')', () => DL.parseInfo(v))
    noThrow('pickableFormats(' + String(v) + ')', () => DL.pickableFormats(v))
    noThrow('parseHistory(' + String(v) + ')', () => DL.parseHistory(v))
    noThrow('parsePreview(' + String(v) + ')', () => DL.parsePreview(v))
    noThrow('playlistEntries(' + String(v) + ')', () => DL.playlistEntries(v))
    noThrow('playlistTitle(' + String(v) + ')', () => DL.playlistTitle(v))
    noThrow('folderName(' + String(v) + ')', () => DL.folderName(v))
    noThrow('urlKey(' + String(v) + ')', () => DL.urlKey(v))
    noThrow('clipboardUrl(' + String(v) + ')', () => DL.clipboardUrl(v))
    noThrow('clipboardLink(' + String(v) + ')', () => DL.clipboardLink(v))
    noThrow('primaryTool(' + String(v) + ')', () => DL.primaryTool(v))
    noThrow('videoUnsupported(' + String(v) + ')', () => DL.videoUnsupported(v))
    noThrow('savedName(' + String(v) + ')', () => DL.savedName(v))
    noThrow('sizeLabel(' + String(v) + ')', () => DL.sizeLabel(v))
    noThrow('sortFormats(' + String(v) + ')', () => DL.sortFormats(v, 'size', 'asc'))
    noThrow('rowWindow(' + String(v) + ')', () => DL.rowWindow(v, 2))
    noThrow('downloadedFormats(' + String(v) + ')',
      () => DL.downloadedFormats(v, v, v))
    noThrow('downloadedKeys(' + String(v) + ')',
      () => DL.downloadedKeys(v, v))
    noThrow('downloadedPath(' + String(v) + ')', () => DL.downloadedPath(v, v, v, v))
    noThrow('formatLabel(' + String(v) + ')', () => DL.formatLabel(v))
    noThrow('fpsLabel(' + String(v) + ')', () => DL.fpsLabel(v))
    noThrow('extLabel(' + String(v) + ')', () => DL.extLabel(v))
    noThrow('kindLabel(' + String(v) + ')', () => DL.kindLabel(v))
    noThrow('kindKey(' + String(v) + ')', () => DL.kindKey(v))
    noThrow('filetypeKey(' + String(v) + ')', () => DL.filetypeKey(v))
    noThrow('downloadSelector(' + String(v) + ')', () => DL.downloadSelector(v))
  }
})

section('TableSort')
group('natural order', () => {
  eq('10 after 9', TS.naturalCompare('9', '10') < 0, true)
  eq('9.2 before 10.1', TS.naturalCompare('9.2', '10.1') < 0, true)
  eq('1.9 before 1.10', TS.naturalCompare('1.9', '1.10') < 0, true)
  eq('a suffix still orders', TS.naturalCompare('1.2p1', '1.2p2') < 0, true)
  eq('a number before a word', TS.naturalCompare('2', 'beta') < 0, true)
  eq('a prefix sorts first', TS.naturalCompare('mp4', 'mp4a') < 0, true)
  eq('equal strings', TS.naturalCompare('1.2', '1.2'), 0)
  eq('null is the empty string', TS.naturalCompare(null, ''), 0)
  eq('undefined is the empty string', TS.naturalCompare(undefined, ''), 0)
  let seed = 0xabc123
  const rand = () => {
    seed = (seed * 1103515245 + 12345) >>> 0
    return seed / 0x100000000
  }
  const words = ['1', '2', '10', '1.2', '1.10', 'a1', 'a2', 'b', 'beta', '', '01']
  let antisymmetric = true
  for (let i = 0; i < 200; i++) {
    const a = words[Math.floor(rand() * words.length)]
    const b = words[Math.floor(rand() * words.length)]
    const ab = Math.sign(TS.naturalCompare(a, b))
    const ba = Math.sign(TS.naturalCompare(b, a))
    if (ab !== 0 && ab !== -ba) antisymmetric = false
    if (ab === 0 && ba !== 0) antisymmetric = false
  }
  is('the comparator is antisymmetric', antisymmetric, v => v === true, 'antisymmetric')
})

group('direction', () => {
  eq('a new column starts ascending', TS.nextDirection('size', 'desc', 'fps'), 'asc')
  eq('the active column flips', TS.nextDirection('size', 'asc', 'size'), 'desc')
  eq('and flips back', TS.nextDirection('size', 'desc', 'size'), 'asc')
  eq('nothing active starts ascending', TS.nextDirection('', 'asc', 'size'), 'asc')
  eq('a null active key starts ascending', TS.nextDirection(null, 'desc', 'size'), 'asc')
  eq('descending flips a positive result', TS.applyDirection(1, 'desc'), -1)
  eq('descending flips a negative result', TS.applyDirection(-1, 'desc'), 1)
  eq('descending keeps a tie', TS.applyDirection(0, 'desc'), 0)
  eq('ascending keeps the sign', TS.applyDirection(-1, 'asc'), -1)
  eq('a missing direction is ascending', TS.applyDirection(1, ''), 1)
})

finish()
