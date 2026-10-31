#!/usr/bin/env node
// Suite: common/text/DropPayload.js - one drag payload reduced to the single
// uri a wallpaper drop can act on.
//
// The contract that matters is that hover and drop agree. A drop target binds
// its drag feedback to `supported()` and its handling to `resolve()`, so any
// payload where those two disagree is a drag that lights up and is then
// refused. The wallhaven case that motivated this module is the regression
// test: a linked image is one image plus one page, not two images.

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, noThrow, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const DP = loadLib(path.join(SHELL, 'common/text/DropPayload.js'))

suite('common/text', 'DropPayload - one drag payload to one wallpaper uri')

// A drop payload shaped the way Qt hands one to a DropArea.
const urlDrop = (...urls) => ({ hasUrls: true, urls, hasText: false, text: '', formats: ['text/uri-list'] })
const textDrop = (text) => ({ hasUrls: false, urls: [], hasText: true, text, formats: ['text/plain'] })
const rawDrop = (data) => ({
  hasUrls: false, urls: [], hasText: false, text: '', formats: ['application/x-moz-moz-link'],
  getDataAsString: (fmt) => (fmt === 'text/uri-list' ? data : ''),
})
const ok = (d) => DP.resolve(d).ok === true
const uriOf = (d) => DP.resolve(d).uri

const IMG = 'https://w.wallhaven.cc/full/po/wallhaven-pomle9.jpg'
const PAGE = 'https://wallhaven.cc/w/pomle9'

section('resolve() - the motivating case: an image dragged out of a link')
group('an image plus the page holding it is one image', () => {
  // The browser offers both because the <img> sits inside an <a>. Only the
  // first names an image, so only the first is a wallpaper candidate.
  eq('two urls, one of them an image', uriOf(urlDrop(IMG, PAGE)), IMG)
  eq('page first - the image still wins', uriOf(urlDrop(PAGE, IMG)), IMG)
  eq('and it is supported at hover', DP.supported(urlDrop(IMG, PAGE)), true)
})

group('a genuine multi-image drag is still refused', () => {
  // The reduction is not a licence to take the first of five.
  const five = urlDrop('/a.png', '/b.jpg', '/c.webp', '/d.bmp', '/e.tiff')
  eq('five images are not one', ok(five), false)
  eq('and say so', DP.resolve(five).error, DP.ERR_MULTI)
  eq('two images are not one either', ok(urlDrop('/a.png', '/b.jpg')), false)
})

section('resolve() - query and fragment metadata on the link')
group('an extension query parameter is not a file extension', () => {
  // `?format=webp` configures the output; it does not make the path an image.
  // Reading it as an extension would accept every URL that names its format.
  eq('render?format=webp is not an image', ok(urlDrop('https://ex.com/render?format=webp')), true)
  eq('but it is still a remote wallpaper candidate', uriOf(urlDrop('https://ex.com/render?format=webp')), 'https://ex.com/render?format=webp')
  eq('a query naming a real extension is the same url', uriOf(urlDrop('https://ex.com/render?format=webp&v=1.2.3')), 'https://ex.com/render?format=webp&v=1.2.3')
})

group('an image extension before the query still names an image', () => {
  eq('photo.jpg?w=1920', uriOf(urlDrop('https://ex.com/photo.jpg?w=1920&q=80')), 'https://ex.com/photo.jpg?w=1920&q=80')
  eq('photo.png?a=1', uriOf(urlDrop('https://ex.com/photo.png?a=1')), 'https://ex.com/photo.png?a=1')
  eq('a fragment does not hide it either', uriOf(urlDrop('https://ex.com/photo.png#top')), 'https://ex.com/photo.png#top')
})

section('resolve() - local paths')
group('a local image is accepted as its own path', () => {
  eq('absolute png', uriOf(urlDrop('/home/u/Pics/wall.png')), '/home/u/Pics/wall.png')
  eq('uppercase extension', uriOf(urlDrop('/home/u/WALL.PNG')), '/home/u/WALL.PNG')
  eq('a file:// uri is accepted verbatim for the service to decode', uriOf(urlDrop('file:///home/u/a.png')), 'file:///home/u/a.png')
  eq('a percent-encoded file:// uri', uriOf(urlDrop('file:///home/u/my%20wall.png')), 'file:///home/u/my%20wall.png')
})

group('a local non-image is refused', () => {
  eq('a text file', ok(urlDrop('/home/u/notes.txt')), false)
  eq('a document', ok(urlDrop('/home/u/report.pdf')), false)
  eq('a directory-looking path with no extension', ok(urlDrop('/home/u/Pictures')), false)
})

section('resolve() - the transport gate')
group('http and credentialed urls are refused, and refused for one reason', () => {
  eq('plain http', ok(urlDrop('http://ex.com/a.png')), false)
  eq('http says unsupported type', DP.resolve(urlDrop('http://ex.com/a.png')).error, DP.ERR_UNSUPPORTED)
  eq('userinfo in the authority', ok(urlDrop('https://user:pw@ex.com/a.png')), false)
  // The authority stops at the first /, ?, or #, so an @ further along is
  // data in a path or a query and must not be read as credentials.
  eq('an @ in a query is not a credential', ok(urlDrop('https://ex.com/a.png?u=a@b.com')), true)
  eq('an @ in a path is not a credential', ok(urlDrop('https://ex.com/u@v/a.png')), true)
})

section('resolve() - text and raw uri-list payloads')
group('a multi-line text payload is split, not refused for its line count', () => {
  // A title line alongside the url is one image, not a multi-file drag.
  eq('title then url', uriOf(textDrop(`wallhaven\n${IMG}`)), IMG)
  eq('url then title', uriOf(textDrop(`${IMG}\nsome caption`)), IMG)
  eq('comment lines are dropped', uriOf(textDrop(`# a comment\n${IMG}`)), IMG)
  eq('a trailing newline is not a second entry', uriOf(textDrop(`${IMG}\n`)), IMG)
})

group('a browser that repeats the url describes one drag', () => {
  eq('the same url twice', uriOf(urlDrop(IMG, IMG)), IMG)
  eq('the same url twice in text', uriOf(textDrop(`${IMG}\n${IMG}`)), IMG)
})

group('a payload with no url format falls back to text/uri-list', () => {
  eq('raw uri-list', uriOf(rawDrop(`${IMG}\r\n${PAGE}`)), IMG)
  eq('raw uri-list with comments', uriOf(rawDrop(`# comment\r\n${IMG}\r\n`)), IMG)
})

section('supported() is resolve(), so hover cannot promise a refused drop')
group('every payload agrees across both entry points', () => {
  const payloads = [
    urlDrop(IMG), urlDrop(IMG, PAGE), urlDrop(PAGE, IMG), urlDrop('/a.png', '/b.jpg'),
    urlDrop('/a.png'), urlDrop('/a.txt'), urlDrop('http://ex.com/a.png'),
    urlDrop('https://u@ex.com/a.png'), urlDrop('https://ex.com/render?format=webp'),
    textDrop(IMG), textDrop(`x\n${IMG}`), textDrop('just some prose'), textDrop(''),
    rawDrop(IMG), urlDrop(), textDrop('# only a comment'),
  ]
  for (const p of payloads) {
    const label = JSON.stringify([p.urls, p.text, p.formats && p.formats[0]]).slice(0, 60)
    eq(`agree: ${label}`, DP.supported(p), DP.resolve(p).ok)
  }
})

section('totality - no payload shape throws')
group('degenerate inputs are refused, not fatal', () => {
  for (const v of [undefined, null, {}, { hasUrls: false }, { hasUrls: true, urls: null },
    { hasUrls: true, urls: [] }, { hasText: true }, { hasText: true, text: null },
    { formats: [] }, { formats: null }, { formats: ['x'], getDataAsString: null }]) {
    noThrow(JSON.stringify(v ?? null), () => DP.resolve(v))
  }
  eq('null resolves to unsupported', DP.resolve(null).error, DP.ERR_UNSUPPORTED)
  eq('undefined is refused', ok(undefined), false)
  eq('a getDataAsString returning empty is refused', ok(rawDrop('   ')), false)
})

group('resolve() always reports one of the two published messages', () => {
  const r = DP.resolve(urlDrop('/a.png', '/b.jpg'))
  is('an ok verdict carries a uri and no error', DP.resolve(urlDrop('/a.png')), (v) => v.ok === true && typeof v.uri === 'string' && v.error === undefined, 'uri only')
  is('a refusal carries a message and no uri', r, (v) => v.ok === false && v.error === DP.ERR_MULTI && v.uri === undefined, 'error only')
})

finish()
