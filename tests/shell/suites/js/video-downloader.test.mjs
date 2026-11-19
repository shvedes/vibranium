#!/usr/bin/env node
import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const DL = loadLib(path.join(SHELL, 'features/bar/modules/Downloader/DownloadsLib.js'))
const TS = loadLib(path.join(SHELL, 'common/collections/TableSort.js'))

suite('video-downloader', 'yt-dlp info and download history parsers')

// Shapes below are copied from `yt-dlp --list-formats` 2026.10.26: the HLS
// rows leave FILESIZE blank (so their first section token is the PROTO), the
// DASH rows mark themselves "audio only"/"video only", and a progressive row
// names both codecs.
const info = [
  '[youtube] Extracting URL: https://youtu.be/x',
  'ID      EXT   RESOLUTION FPS CH |   FILESIZE    TBR PROTO | VCODEC           VBR ACODEC      ABR ASR MORE INFO',
  '---------------------------------------------------------------------------------------------------------------------------',
  'sb3     mhtml 48x27        0    |                   mhtml | images                                   storyboard',
  '233     mp4   audio only        |                   m3u8  | audio only           unknown             Default, low',
  '140     m4a   audio only      2 |    3.69MiB    49k https | audio only           mp4a.40.5   49k 22k low, m4a_dash',
  '602     mp4   256x144     15    | ~  7.06MiB    93k m3u8  | vp09.00.10.08    93k video only',
  '160     mp4   256x144     30    |    4.12MiB    55k https | avc1.4D400C      55k video only          144p, mp4_dash',
  '18      mp4   640x360     30    |    9.24MiB  1500k https | avc1.42001E  96k mp4a.40.2  96k 44k medium'
].join('\n')

section('format table')
group('parseInfo', () => {
  const rows = DL.parseInfo(info)
  eq('skips header and separator', rows.length, 6)
  eq('first id', rows[0].id, 'sb3')
  eq('second ext', rows[1].ext, 'mp4')
  eq('audio resolution', rows[1].resolution, 'audio')
  eq('an HLS row has no size, not the proto', rows[1].size, '')
  eq('dash size', rows[2].size, '3.69MiB')
  eq('approximate size drops the tilde', rows[3].size, '7.06MiB')
  eq('video resolution', rows[4].resolution, '256x144')
})
group('format kind', () => {
  const rows = DL.parseInfo(info)
  eq('audio only', rows[1].kind, 'audio')
  eq('video only', rows[4].kind, 'video')
  eq('progressive names both codecs', rows[5].kind, 'both')
})
group('parseInfo fps', () => {
  const rows = DL.parseInfo(info)
  eq('video fps', rows[4].fps, 30)
  eq('a 15fps HLS row', rows[3].fps, 15)
  eq('an audio row has none', rows[1].fps, 0)
})
group('pickableFormats', () => {
  const rows = DL.pickableFormats(info)
  eq('drops storyboards', rows.length, 5)
  // The fetch keeps yt-dlp's order; the table's header sorting owns what is
  // shown first (see the sorting section).
  eq('fetch order is untouched', rows[0].id, '233')
  eq('and its last row', rows[4].id, '18')
})

const history = [
  '2026-11-16 21:30\tFirst Clip\t40943092\t/home/u/First Clip.mp4\thttps://youtu.be/a',
  '2026-11-16 21:32\tSecond Clip\t879341\t/home/u/Second Clip.mp4\thttps://youtu.be/b'
].join('\n')

section('preview')
group('parsePreview', () => {
  const p = DL.parsePreview('ONBOARD CAM! SpaceX Starship 42 Catch\nhttps://i.ytimg.com/vi/bmrEA_jmtEg/mqdefault.jpg\n')
  eq('title', p.title, 'ONBOARD CAM! SpaceX Starship 42 Catch')
  eq('thumbnail', p.thumbnail, 'https://i.ytimg.com/vi/bmrEA_jmtEg/mqdefault.jpg')
  const empty = DL.parsePreview('')
  eq('empty title', empty.title, '')
  eq('empty thumbnail', empty.thumbnail, '')
})

section('history TSV')
group('parseHistory', () => {
  const rows = DL.parseHistory(history)
  eq('two rows', rows.length, 2)
  eq('first title', rows[0].title, 'First Clip')
  eq('first size', rows[0].size, '40943092')
  eq('second path', rows[1].path, '/home/u/Second Clip.mp4')
  eq('second url', rows[1].url, 'https://youtu.be/b')
  eq('blank ignored', DL.parseHistory(history + '\n\n').length, 2)
  eq('the format column is read',
    DL.parseHistory('t\ttitle\t1\t/p\tu\t137')[0].format, '137')
  eq('an older line has no format', rows[0].format, '')
})

group('playlist history', () => {
  const row = { title: 'Album', size: '16', path: '/d/Album',
    url: 'https://www.youtube.com/playlist?list=PL1', format: 'playlist:Best' }
  eq('a batch row is a playlist row', DL.isPlaylistHistory(row), true)
  eq('a tagless batch row is a playlist row',
    DL.isPlaylistHistory({ format: 'playlist' }), true)
  eq('a file row is not a batch', DL.isPlaylistHistory({ format: 'wget' }), false)
  eq('a format row is not a batch', DL.isPlaylistHistory({ format: '137' }), false)

  const ledger = DL.parsePlaylistLedger([
    '/d/Album\thttps://youtu.be/a\t/d/Album/A.mp4',
    '/d/Album\thttps://youtu.be/b\t/d/Album/B.mp4'
  ].join('\n'))
  eq('the entry index reads both files', ledger.length, 2)
  eq('the entry index names the folder', ledger[0].folder, '/d/Album')
  eq('the entry index names the URL', ledger[1].url, 'https://youtu.be/b')

  const rows = DL.attachPlaylistEntries([row], ledger)
  eq('the batch row owns its entries', rows[0].entries.length, 2)
  eq('the batch row is not a format',
    DL.downloadedFormats(rows, row.url, []).join(','), '')
  eq('the batch row is not a file to open',
    DL.downloadedPath(rows, row.url, 'playlist:Best'), '')
  eq('live entries are held',
    DL.downloadedKeys(rows, []).join(','), 'yt:a,yt:b')
  eq('a deleted entry is not held',
    DL.downloadedKeys(rows, ['/d/Album/A.mp4']).join(','), 'yt:b')
})

group('urlKey', () => {
  eq('a watch link keys by id',
    DL.urlKey('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3'), 'yt:dQw4w9WgXcQ')
  eq('a short link agrees with it',
    DL.urlKey('https://youtu.be/dQw4w9WgXcQ?si=x'), 'yt:dQw4w9WgXcQ')
  eq('a shorts link too', DL.urlKey('https://youtube.com/shorts/dQw4w9WgXcQ'), 'yt:dQw4w9WgXcQ')
  eq('a plain host keeps its path', DL.urlKey('https://Vimeo.com/123/'), 'vimeo.com/123')
  eq('a query is not part of the key', DL.urlKey('https://vimeo.com/123?x=1'), 'vimeo.com/123')
  eq('empty stays empty', DL.urlKey('   '), '')
})
group('playlist URLs', () => {
  eq('a playlist path',
    DL.isPlaylistUrl('https://www.youtube.com/playlist?list=PL1'), true)
  eq('a watch link carrying a list',
    DL.isPlaylistUrl('https://www.youtube.com/watch?v=abc&list=PL1'), true)
  eq('a short link carrying a list',
    DL.isPlaylistUrl('https://youtu.be/abc?list=PL1'), true)
  eq('a plain video is not one',
    DL.isPlaylistUrl('https://www.youtube.com/watch?v=abc'), false)
  eq('an empty field is not one', DL.isPlaylistUrl('   '), false)
})
group('primaryRoute', () => {
  // Regression: this is a watch URL, not /playlist. YouTube's share sheet
  // produces this shape, and it must take the queue path, not one video.
  const album = 'https://www.youtube.com/watch?v=MhsUKjwH1dE&list=OLAK5uy_mwmTuYXssTxaUL-GIAQ_5gOS2fQk9O6Mg'
  eq('the reported album link is a playlist', DL.isPlaylistUrl(album), true)
  eq('the reported album link queues every entry', DL.primaryRoute(album), 'playlist')
  eq('a /playlist page queues every entry',
    DL.primaryRoute('https://www.youtube.com/playlist?list=PL1'), 'playlist')
  eq('a short share link with list queues every entry',
    DL.primaryRoute('https://youtu.be/abc?list=PL1'), 'playlist')
  eq('a plain video is one download',
    DL.primaryRoute('https://youtu.be/abc'), 'download')
  eq('a direct file is one download',
    DL.primaryRoute('https://example.com/report.pdf'), 'download')
  eq('empty is one download', DL.primaryRoute(''), 'download')
})
group('playlistEntries', () => {
  const text = [
    'Krautrock\t1\tFirst video\t3:41\thttps://www.youtube.com/watch?v=a',
    'Krautrock\t2\tSecond\ttabbed\ttitle\t4:02\thttps://www.youtube.com/watch?v=b',
    'Krautrock\t3\tUnknown length\tNA\thttps://www.youtube.com/watch?v=c'
  ].join('\n')
  const rows = DL.playlistEntries(text)
  eq('one row per line', rows.length, 3)
  eq('the index follows the name', rows[0].index, '1')
  eq('the playlist name leads every row', rows[0].playlist, 'Krautrock')
  eq('the url ends', rows[0].url, 'https://www.youtube.com/watch?v=a')
  eq('the duration sits before it', rows[0].duration, '3:41')
  eq('a tabbed title is rejoined', rows[1].title, 'Second tabbed title')
  eq('an unknown length stays as reported', rows[2].duration, 'NA')
  eq('blank lines are skipped', DL.playlistEntries('\n\n').length, 0)
  eq('a line without a url is skipped',
    DL.playlistEntries('1\tTitle\t3:41\t').length, 0)
  const legacy = DL.playlistEntries('4\tOld row\t5:00\thttps://x/watch?v=d')
  eq('an older four-field line still reads', legacy[0].title, 'Old row')
  eq('and it names no playlist', legacy[0].playlist, '')
})
group('playlistTitle', () => {
  eq('the name leads the first line',
    DL.playlistTitle('Album\t1\tSong\t3:00\thttps://x/a'), 'Album')
  eq('an unknown name is empty',
    DL.playlistTitle('NA\t1\tSong\t3:00\thttps://x/a'), '')
  eq('an older listing has no name',
    DL.playlistTitle('1\tSong\t3:00\thttps://x/a'), '')
  eq('an empty listing has no name', DL.playlistTitle(''), '')
})
group('folderName', () => {
  eq('a plain name survives', DL.folderName("the world doesn't care"),
    "the world doesn't care")
  eq('separators cannot fork the path', DL.folderName('AC/DC: Live?'),
    'AC DC Live')
  eq('edges lose the dots a path drops', DL.folderName('  .hidden album. '),
    'hidden album')
  eq('an empty name falls back', DL.folderName(''), 'Playlist')
  eq('a dots-only name falls back', DL.folderName('..'), 'Playlist')
  eq('a long name is bounded', DL.folderName('x'.repeat(120)).length, 80)
})
group('playlist qualities', () => {
  const opts = DL.qualityOptions()
  eq('the batch offers a choice, best included', opts.length, 6)
  eq('best is the default', DL.qualitySelector('best'),
    'bestvideo+bestaudio/best')
  eq('4K is a 2160 cap', DL.qualitySelector('2160'),
    'bestvideo[height<=2160]+bestaudio/best[height<=2160]')
  eq('2K is a 1440 cap', DL.qualitySelector('1440'),
    'bestvideo[height<=1440]+bestaudio/best[height<=1440]')
  eq('a cap names the height', DL.qualitySelector('720'),
    'bestvideo[height<=720]+bestaudio/best[height<=720]')
  eq('every chip names a palette leaf',
    opts.every(o => String(o.color || '') !== ''), true)
  eq('audio stays audio', DL.qualitySelector('audio'), 'bestaudio/best')
  eq('a chip label names the preset', DL.qualityLabel('720'), '720p')
  eq('best is labelled', DL.qualityLabel('best'), 'Best')
  eq('an unknown label falls back with the selector',
    DL.qualityLabel('nope'), 'Best')
  eq('an unknown key falls back to best', DL.qualitySelector('nope'),
    'bestvideo+bestaudio/best')
  eq('a missing key falls back to best', DL.qualitySelector(''),
    'bestvideo+bestaudio/best')
  eq('the options cannot be mutated from outside',
    opts !== DL.qualityOptions(), true)
})
group('downloadedFormats', () => {
  const hist = [
    { url: 'https://www.youtube.com/watch?v=a', format: '137' },
    { url: 'https://youtu.be/b', format: '22' }
  ]
  eq('the normalized spelling matches',
    DL.downloadedFormats(hist, 'https://youtu.be/a').join(','), '137')
  eq('another video names nothing',
    DL.downloadedFormats(hist, 'https://youtu.be/c').length, 0)
  eq('a line without a format marks nothing',
    DL.downloadedFormats([{ url: 'https://youtu.be/a' }], 'https://youtu.be/a').length, 0)
  eq('duplicates collapse', DL.downloadedFormats(hist.concat([hist[0]]),
    'https://www.youtube.com/watch?v=a').length, 1)
  eq('an empty field matches nothing', DL.downloadedFormats(hist, '').length, 0)
  eq('a merged pick marks its plain row',
    DL.downloadedFormats([{ url: 'https://youtu.be/a', format: '137+bestaudio/137',
      path: '/videos/a.mp4' }], 'https://youtu.be/a').join(','), '137')
  const gone = [{ url: 'https://youtu.be/a', format: '137', path: '/videos/a.mp4' }]
  eq('a file that is gone marks nothing',
    DL.downloadedFormats(gone, 'https://youtu.be/a', ['/videos/a.mp4']).length, 0)
  eq('a file that is there still marks its row',
    DL.downloadedFormats(gone, 'https://youtu.be/a', ['/videos/b.mp4']).join(','), '137')
  eq('a gone entry does not shadow a live one', DL.downloadedFormats(
    gone.concat([{ url: 'https://youtu.be/a', format: '18', path: '/videos/a2.mp4' }]),
    'https://youtu.be/a', ['/videos/a.mp4']).join(','), '18')
})
group('downloadedPath', () => {
  const hist = [
    { url: 'https://youtu.be/a', format: '137+bestaudio', path: '/videos/a.mp4' },
    { url: 'https://www.youtube.com/watch?v=b', format: '22', path: '/videos/b.mp4' }
  ]
  eq('the file of the picked format',
    DL.downloadedPath(hist, 'https://www.youtube.com/watch?v=a', '137'),
    '/videos/a.mp4')
  eq('the normalized spelling matches both ways',
    DL.downloadedPath(hist, 'https://youtu.be/b', '22'), '/videos/b.mp4')
  eq('another video names no file',
    DL.downloadedPath(hist, 'https://youtu.be/c', '137'), '')
  eq('another format names no file',
    DL.downloadedPath(hist, 'https://youtu.be/a', '18'), '')
  eq('a line without a path names no file',
    DL.downloadedPath([{ url: 'https://youtu.be/a', format: '137' }],
      'https://youtu.be/a', '137'), '')
  eq('a file that is gone names no file',
    DL.downloadedPath(hist, 'https://youtu.be/a', '137', ['/videos/a.mp4']), '')
  eq('an empty field names no file', DL.downloadedPath(hist, '', '137'), '')
  eq('nothing to match is not an error', DL.downloadedPath(null, null, null), '')
})
group('sizeLabel', () => {
  eq('bytes', DL.sizeLabel('512'), '512 B')
  eq('kib', DL.sizeLabel('2048'), '2 KiB')
  eq('mib', DL.sizeLabel(String(2 * 1048576)), '2.0 MiB')
  eq('pass through', DL.sizeLabel('39.02MiB'), '39.02MiB')
})

section('format table projection')
group('rowWindow', () => {
  const padded = DL.rowWindow([{ id: '401' }], 3)
  eq('pads to the window', padded.length, 3)
  eq('keeps the live row first', padded[0].id, '401')
  eq('the pad is a filler', DL.isFiller(padded[2]), true)
  eq('a long set is returned whole', DL.rowWindow([1, 2, 3, 4], 3).length, 4)
  eq('an empty set pads from zero', DL.rowWindow(undefined, 2).length, 2)
  eq('a non-array pads too', DL.rowWindow('nope', 1).length, 1)
})
group('formatLabel', () => {
  eq('a video row shows its resolution', DL.formatLabel({ resolution: '1920x1080', kind: 'video' }), '1920x1080')
  eq('an audio row reads as absent', DL.formatLabel({ resolution: 'audio', kind: 'audio' }), '-')
  eq('a filler says nothing', DL.formatLabel({ filler: true }), '')
})
group('cellLabel', () => {
  eq('a value is itself', DL.cellLabel('mp4'), 'mp4')
  eq('nothing is a dash', DL.cellLabel(''), '-')
  eq('whitespace is a dash', DL.cellLabel('   '), '-')
  eq('null is a dash', DL.cellLabel(null), '-')
  eq('zero is a value', DL.cellLabel(0), '0')
})
group('fpsLabel', () => {
  eq('a rate is a bare number', DL.fpsLabel({ fps: 60 }), '60')
  eq('no rate is a dash', DL.fpsLabel({ fps: 0 }), '-')
  eq('an audio row has no rate', DL.fpsLabel({ kind: 'audio' }), '-')
  eq('a filler says nothing', DL.fpsLabel({ filler: true }), '')
})
group('extLabel and filetype colors', () => {
  eq('the container', DL.extLabel({ ext: 'webm' }), 'webm')
  eq('no container is a dash', DL.extLabel({ ext: '' }), '-')
  eq('mp4 is blue', DL.filetypeKey('mp4'), 'blue')
  eq('webm is green', DL.filetypeKey('WEBM'), 'green')
  eq('m4a is orange', DL.filetypeKey('m4a'), 'orange')
  eq('an unknown type is plain', DL.filetypeKey('xyz'), 'foreground_1')
  eq('no type is plain', DL.filetypeKey(''), 'foreground_1')
  eq('a prototype name is not a color', DL.filetypeKey('constructor'), 'foreground_1')
})
group('kindLabel', () => {
  eq('audio is the bare letter', DL.kindLabel({ kind: 'audio' }), 'a')
  eq('a video-only row is merged with audio, so it says so',
    DL.kindLabel({ kind: 'video' }), 'v+a')
  eq('a stream that already carries both', DL.kindLabel({ kind: 'both' }), 'a+v')
  eq('the two combined states stay apart',
    DL.kindLabel({ kind: 'video' }) !== DL.kindLabel({ kind: 'both' }), true)
  eq('the three states read apart',
    [DL.kindLabel({ kind: 'audio' }), DL.kindLabel({ kind: 'video' }),
      DL.kindLabel({ kind: 'both' })].join('|'), 'a|v+a|a+v')
  eq('unknown is silent', DL.kindLabel({}), '')
  eq('a filler says nothing', DL.kindLabel({ filler: true }), '')
  eq('the three states are color-coded apart',
    [DL.kindKey({ kind: 'audio' }), DL.kindKey({ kind: 'video' }),
      DL.kindKey({ kind: 'both' })].join(','), 'orange,blue,green')
  eq('an unknown kind stays plain', DL.kindKey({}), 'foreground_1')
  eq('a filler stays plain', DL.kindKey({ filler: true }), 'foreground_1')
})
group('downloadSelector', () => {
  eq('a video-only row merges the best audio',
    DL.downloadSelector({ id: '137', kind: 'video' }), '137+bestaudio/137')
  eq('the row itself is the fallback',
    DL.downloadSelector({ id: '137', kind: 'video' }).indexOf('/137') > 0, true)
  eq('a row that already has sound needs nothing added',
    DL.downloadSelector({ id: '18', kind: 'both' }), '18')
  eq('an audio row stays itself', DL.downloadSelector({ id: '140', kind: 'audio' }), '140')
  eq('no row is no selector', DL.downloadSelector(null), '')
  eq('a filler is not a pick', DL.downloadSelector({ filler: true }), '')
})
group('formatColumns', () => {
  const caps = { minKind: 32, minSize: 46, sizeCap: 96 }
  eq('a long size clamps to the cap', DL.formatColumns(24, 400, 352, 34, caps).size, 96)
  eq('a small kind keeps its floor', DL.formatColumns(10, 50, 352, 34, caps).kind, 32)
  eq('a measured kind keeps its width plus padding', DL.formatColumns(40, 50, 352, 34, caps).kind, 42)
})

section('sorting')
group('sortFormats', () => {
  const rows = [
    { id: 'a', ext: 'mp4', resolution: '640x360', fps: 30, kind: 'both', size: '9.24MiB' },
    { id: 'b', ext: 'webm', resolution: '1920x1080', fps: 15, kind: 'video', size: '5MiB' },
    { id: 'c', ext: 'mp4', resolution: '1920x1080', fps: 60, kind: 'video', size: '78.41MiB' },
    { id: 'd', ext: 'm4a', resolution: 'audio', kind: 'audio', size: '3MiB' },
    { id: 'e', ext: 'mp4', resolution: '256x144', kind: 'video', size: '' }
  ]
  eq('resolution descending puts the 1080p pair first',
    DL.sortFormats(rows, 'resolution', 'desc').slice(0, 2).map(r => r.id), ['b', 'c'])
  eq('resolution ascending puts 360p last of the ranked',
    DL.sortFormats(rows, 'resolution', 'asc')[0].id, 'e')
  eq('an audio row has no resolution and sorts last descending',
    DL.sortFormats(rows, 'resolution', 'desc').slice(-1)[0].id, 'd')
  eq('and last ascending too (absent is not smallest)',
    DL.sortFormats(rows, 'resolution', 'asc').slice(-1)[0].id, 'd')
  eq('fps ascending', DL.sortFormats(rows, 'fps', 'asc')[0].id, 'b')
  eq('size descending', DL.sortFormats(rows, 'size', 'desc')[0].id, 'c')
  eq('an unknown size sorts last descending',
    DL.sortFormats(rows, 'size', 'desc').slice(-1)[0].id, 'e')
  eq('format ascending groups by container',
    DL.sortFormats(rows, 'format', 'asc').map(r => r.id), ['d', 'a', 'c', 'e', 'b'])
  eq('kind ascending ranks audio then video then both',
    DL.sortFormats(rows, 'kind', 'asc').map(r => r.id), ['d', 'b', 'c', 'e', 'a'])
  eq('a tie keeps fetch order', DL.sortFormats(rows, 'resolution', 'desc').slice(0, 2).map(r => r.id)[0], 'b')
  eq('the input is not mutated', rows[0].id, 'a')
  eq('a non-array sorts to nothing', DL.sortFormats(undefined, 'size', 'asc').length, 0)
})
group('TableSort', () => {
  eq('a new column starts ascending', TS.nextDirection('size', 'desc', 'fps'), 'asc')
  eq('the sorted column flips', TS.nextDirection('size', 'asc', 'size'), 'desc')
  eq('and flips back', TS.nextDirection('size', 'desc', 'size'), 'asc')
  eq('nothing sorted starts ascending', TS.nextDirection('', 'asc', 'size'), 'asc')
  eq('versions read as numbers', TS.naturalCompare('9.2', '10.1') < 0, true)
  eq('equal versions', TS.naturalCompare('1.2', '1.2'), 0)
  eq('a suffix still orders', TS.naturalCompare('1.2p1', '1.2p2') < 0, true)
  eq('numbers before words', TS.naturalCompare('2', 'beta') < 0, true)
  eq('descending flips a nonzero result', TS.applyDirection(1, 'desc'), -1)
  eq('descending keeps a tie zero', TS.applyDirection(0, 'desc'), 0)
})

section('clipboard')
group('clipboardUrl', () => {
  eq('youtube', DL.clipboardUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), 'https://www.youtube.com/watch?v=dQw4w9WgXcQ')
  eq('short link', DL.clipboardUrl('https://youtu.be/dQw4w9WgXcQ'), 'https://youtu.be/dQw4w9WgXcQ')
  eq('a subdomain matches', DL.clipboardUrl('https://music.youtube.com/watch?v=x'), 'https://music.youtube.com/watch?v=x')
  eq('x', DL.clipboardUrl('https://x.com/user/status/1'), 'https://x.com/user/status/1')
  eq('twitter', DL.clipboardUrl('twitter.com/user/status/1'), 'twitter.com/user/status/1')
  eq('reddit', DL.clipboardUrl('https://www.reddit.com/r/x/comments/y'), 'https://www.reddit.com/r/x/comments/y')
  eq('bluesky', DL.clipboardUrl('https://bsky.app/profile/x/post/y'), 'https://bsky.app/profile/x/post/y')
  eq('an unknown host is left alone', DL.clipboardUrl('https://example.com/watch?v=1'), '')
  eq('a suffix is not a host', DL.clipboardUrl('https://notyoutube.com/watch?v=1'), '')
  eq('a link inside a copied line is found',
    DL.clipboardUrl('watch this https://youtu.be/x'), 'https://youtu.be/x')
  eq('a title and a share link yield the link',
    DL.clipboardUrl('Great clip \u2014 https://youtu.be/abc?si=1'), 'https://youtu.be/abc?si=1')
  eq('a line with no link stays empty', DL.clipboardUrl('nothing to paste here'), '')
  eq('empty', DL.clipboardUrl('   '), '')
})
group('primaryLink', () => {
  eq('a whole link is accepted', DL.primaryLink('https://youtu.be/x'), 'https://youtu.be/x')
  eq('surrounding whitespace is trimmed', DL.primaryLink('\n https://youtu.be/x \t'), 'https://youtu.be/x')
  eq('a direct file is accepted', DL.primaryLink('https://example.com/report.pdf'), 'https://example.com/report.pdf')
  eq('a random word is refused', DL.primaryLink('hello'), '')
  eq('random prose is refused', DL.primaryLink('nothing to paste here'), '')
  eq('a sentence around a link is refused',
    DL.primaryLink('watch this https://youtu.be/x'), '')
  eq('a link followed by prose is refused',
    DL.primaryLink('https://youtu.be/x because I said so'), '')
  eq('two links are refused',
    DL.primaryLink('https://youtu.be/a https://youtu.be/b'), '')
  eq('a newline makes it prose',
    DL.primaryLink('https://youtu.be/a\nhttps://youtu.be/b'), '')
  eq('empty is refused', DL.primaryLink('   '), '')
  eq('null is refused', DL.primaryLink(null), '')
  // The explicit paste path keeps its broader scan; only middle-click is strict.
  eq('the paste pane still finds a link in a sentence',
    DL.clipboardLink('watch this https://youtu.be/x'), 'https://youtu.be/x')
})

finish()
