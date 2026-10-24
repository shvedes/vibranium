#!/usr/bin/env node
// Suite: common/text/ - the three small shared helpers plus the two
// extension tables. Small files, but they sit on the per-keystroke path and
// every one of them has a documented contract that is easy to get subtly
// wrong (JSONC is not JSON, markup is not HTML escaping, a tilde path is not
// a path).

import path from 'node:path'
import { loadLib } from '../../lib/qmlloader.mjs'
import { suite, section, group, eq, is, match, notMatch, contains, notContains, noThrow, finish } from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const SU = loadLib(path.join(SHELL, 'common/text/StringUtils.js'))
const EU = loadLib(path.join(SHELL, 'common/text/EditUtils.js'))
const IE = loadLib(path.join(SHELL, 'common/text/ImageExts.js'))

suite('common/text', 'StringUtils, EditUtils, ImageExts')

section('StringUtils.stripJsonc - comments and trailing commas')
group('removes a comment that occupies its own line', () => {
  eq('comment only', SU.stripJsonc('// hi'), '')
  eq('indented comment before a value', SU.stripJsonc('  // hi\n{"a":1}'), '{"a":1}')
  eq('tab-indented comment', SU.stripJsonc('\t// hi\n{}'), '{}')
  eq('two comment lines collapse entirely', SU.stripJsonc('// a\n// b\n{}'), '{}')
  eq('a comment between two values takes its newline with it', SU.stripJsonc('{"a":1,\n// note\n"b":2}'), '{"a":1,\n"b":2}')
})

group('keeps // that is not a comment', () => {
  eq('inside a string value', SU.stripJsonc('{"url":"http://x"}'), '{"url":"http://x"}')
  eq('inside a string with no colon', SU.stripJsonc('{"a":"//"}'), '{"a":"//"}')
  eq('protocol-relative url', SU.stripJsonc('{"u":"//cdn/x"}'), '{"u":"//cdn/x"}')
})

group('leaves a trailing // alone - the pattern is line-anchored', () => {
  // The comment regex is anchored to the start of a line, so a comment that
  // follows a value on the same line survives. That is what keeps a URL
  // value intact, and it is the same reason a genuinely trailing comment is
  // not stripped: the two cases are indistinguishable without a real parser.
  eq('trailing comment after a value', SU.stripJsonc('{"a":1} // hi'), '{"a":1} // hi')
})

group('removes trailing commas before a closer', () => {
  eq('object', SU.stripJsonc('{"a":1,}'), '{"a":1}')
  eq('array', SU.stripJsonc('[1,2,]'), '[1,2]')
  eq('nested', SU.stripJsonc('{"a":[1,2,],"b":3,}'), '{"a":[1,2],"b":3}')
  eq('only the comma goes, the whitespace stays', SU.stripJsonc('{"a":1 , }'), '{"a":1  }')
  eq('comma before a newline then the closer', SU.stripJsonc('{"a":1,\n}'), '{"a":1\n}')
  eq('a comma before a non-closer is untouched', SU.stripJsonc('{"a":1,"b":2}'), '{"a":1,"b":2}')
})

group('tolerates the degenerate inputs', () => {
  noThrow('undefined', () => SU.stripJsonc(undefined))
  eq('undefined reads as empty', SU.stripJsonc(undefined), '')
  eq('null reads as empty', SU.stripJsonc(null), '')
  eq('empty string', SU.stripJsonc(''), '')
  // `raw || ""` is a deliberate falsy fold, so 0 and "" land in the same
  // place. Pinned because a settings file whose value is 0 is the case that
  // would notice a change here.
  eq('0 folds with the falsy values', SU.stripJsonc(0), '')
  eq('42 is a number, not falsy, and reads as text', SU.stripJsonc(42), '42')
  eq('an already-valid document is unchanged', SU.stripJsonc('{"a":[1,2]}'), '{"a":[1,2]}')
})

group('leaves block comments alone, as the regex documents', () => {
  // The implementation is line-oriented; /* */ is not stripped. Pinned so a
  // future "improvement" is a deliberate change rather than a surprise.
  eq('block comment is not removed', SU.stripJsonc('{/* c */"a":1}'), '{/* c */"a":1}')
  notMatch('no stray marker introduced', SU.stripJsonc('{/* c */"a":1}'), /comment/)
})

section('StringUtils.shellQuote - POSIX single-quote escaping')
group('always produces a single quoted word', () => {
  eq('plain word', SU.shellQuote('abc'), "'abc'")
  eq('empty string', SU.shellQuote(''), "''")
  eq('word with spaces', SU.shellQuote('a b'), "'a b'")
})

group("escapes an embedded single quote as '\\\\''", () => {
  eq("it's", SU.shellQuote("it's"), "'it'\\''s'")
  eq('leading quote', SU.shellQuote("'x"), "''\\''x'")
  eq('trailing quote', SU.shellQuote("x'"), "'x'\\'''")
  eq('lone quote', SU.shellQuote("'"), "''\\'''")
  eq('two adjacent quotes each get their own escape', SU.shellQuote("''"), "''\\'''\\'''")
})

group('leaves every other shell metacharacter inert', () => {
  eq('dollar', SU.shellQuote('$HOME'), "'$HOME'")
  eq('backtick', SU.shellQuote('`id`'), "'`id`'")
  eq('double quotes', SU.shellQuote('"x"'), '\'"x"\'')
  eq('backslash', SU.shellQuote('a\\b'), "'a\\b'")
  eq('newline', SU.shellQuote('a\nb'), "'a\nb'")
  eq('semicolon', SU.shellQuote('a;b'), "'a;b'")
})

group('the result is a balanced, reopenable quote', () => {
  const nasty = `a'b'c"d$e\`f\\g h; i&j|k`
  const q = SU.shellQuote(nasty)
  // A correctly formed word starts and ends with a quote and has an even
  // number of interior single quotes, each closing and reopening one.
  is('starts with a quote', q, (s) => s.startsWith("'"), 'starts with a quote')
  is('ends with a quote', q, (s) => s.endsWith("'"), 'ends with a quote')
  is('interior quote count is even', q, (s) => (s.slice(1, -1).match(/'/g) || []).length % 2 === 0, 'even interior quotes')
})

section('StringUtils.styledMarkup - escape, then re-admit a bold/italic tag')
group('escapes the three HTML-significant characters', () => {
  eq('ampersand first, so entities are not double-produced', SU.styledMarkup('a & b'), 'a &amp; b')
  eq('less than', SU.styledMarkup('a < b'), 'a &lt; b')
  eq('greater than', SU.styledMarkup('a > b'), 'a &gt; b')
  eq('all three together', SU.styledMarkup('<a href="x">&'), '&lt;a href="x"&gt;&amp;')
})

group('re-admits only the emphasis tags it supports', () => {
  eq('bold', SU.styledMarkup('<b>x</b>'), '<b>x</b>')
  eq('italic', SU.styledMarkup('<i>x</i>'), '<i>x</i>')
  eq('underline', SU.styledMarkup('<u>x</u>'), '<u>x</u>')
  eq('uppercase tag', SU.styledMarkup('<B>x</B>'), '<B>x</B>')
  eq('mixed case', SU.styledMarkup('<I>x</I>'), '<I>x</I>')
})

group('an escaped tag never comes back to life', () => {
  // The re-admit pass matches &lt;b&gt; specifically, so a literal "<b>" the
  // user typed is escaped and then re-admitted: it renders as bold. That is
  // the intended reading of a notification that carries markup.
  eq('a typed tag is admitted, not escaped', SU.styledMarkup('<b>x</b>'), '<b>x</b>')
  // Anything outside b/i/u stays escaped.
  eq('a script tag is not admitted', SU.styledMarkup('<script>x</script>'), '&lt;script&gt;x&lt;/script&gt;')
  eq('an anchor is not admitted', SU.styledMarkup('<a href=x>y</a>'), '&lt;a href=x&gt;y&lt;/a&gt;')
  eq('a self-closing br is not admitted', SU.styledMarkup('<br/>'), '&lt;br/&gt;')
  // The re-admit pattern matches the whole tag, so a tag carrying an
  // attribute is not re-admitted as an opening tag. Its *closing* tag still
  // is, which leaves an unbalanced `</b>` in the output. Pinned because the
  // asymmetry is invisible in review and would be read as a defect later.
  eq('an attributed tag is not re-admitted, but its closer is', SU.styledMarkup('<b class="c">x</b>'), '&lt;b class="c"&gt;x</b>')
})

group('newline handling', () => {
  eq('a newline becomes a break', SU.styledMarkup('a\nb'), 'a<br>b')
  eq('two newlines', SU.styledMarkup('a\n\nb'), 'a<br><br>b')
  eq('a carriage return survives as text', SU.styledMarkup('a\r\nb'), 'a\r<br>b')
})

group('empty and nullish inputs return empty, not "undefined"', () => {
  eq('empty string', SU.styledMarkup(''), '')
  eq('null', SU.styledMarkup(null), '')
  eq('undefined', SU.styledMarkup(undefined), '')
  eq('zero is text, not emptiness', SU.styledMarkup(0), '0')
  eq('false is text, not emptiness', SU.styledMarkup(false), 'false')
})

group('the escape ordering cannot be undone by its own output', () => {
  // "&" is escaped first, so a literal "&lt;" in the input becomes
  // "&amp;lt;" and is not re-admitted as a tag by the later pass.
  eq('pre-escaped text survives intact', SU.styledMarkup('&lt;b&gt;'), '&amp;lt;b&amp;gt;')
  notMatch('no double-unescaping', SU.styledMarkup('&lt;b&gt;'), /<b>/)
})

section('EditUtils - word boundaries for the inline text fields')
group('boundaryBackward walks to the start of the previous word', () => {
  eq('inside a word', EU.boundaryBackward('hello world', 8), 6)
  eq('at the end of a word', EU.boundaryBackward('hello world', 11), 6)
  eq('at a boundary, it crosses the space too', EU.boundaryBackward('hello world', 6), 0)
  eq('at the start of the string', EU.boundaryBackward('hello', 0), 0)
  eq('empty string', EU.boundaryBackward('', 0), 0)
  // Leading whitespace is not itself a word to back over: the caret sits
  // after "ab", so the boundary is the start of "ab".
  eq('caret after a word that follows leading spaces', EU.boundaryBackward('  ab', 4), 2)
})

group('boundaryBackward stops at the first whitespace it meets', () => {
  eq('several spaces between words', EU.boundaryBackward('a     b', 7), 6)
  eq('tab between words', EU.boundaryBackward('a\tb', 3), 2)
  eq('newline between words', EU.boundaryBackward('a\nb', 3), 2)
  eq('whitespace-only string', EU.boundaryBackward('   ', 3), 0)
})

group('boundaryForward walks past the word and its trailing space', () => {
  eq('inside a word', EU.boundaryForward('hello world', 2), 6)
  eq('at the end', EU.boundaryForward('hello world', 11), 11)
  eq('at a boundary', EU.boundaryForward('hello world', 6), 11)
  eq('empty string', EU.boundaryForward('', 0), 0)
  eq('whitespace-only string', EU.boundaryForward('   ', 0), 3)
  // From inside the run of spaces the first loop does not advance, so the
  // answer is the start of the next word rather than its end.
  eq('from inside a space run', EU.boundaryForward('a     b', 1), 6)
  eq('from a tab', EU.boundaryForward('a\tb', 1), 2)
})

group('eraseWord returns a replacement {text, pos} for the field to apply', () => {
  // The signature is an object, not a string: the caller needs the new caret
  // position as well as the new text, and returning both keeps the panels
  // from recomputing the boundary.
  eq('removes the word and the space before it', EU.eraseWord('hello world', 11), { text: 'hello ', pos: 6 })
  // At a boundary the backspace consumes the separator too, so the space in
  // " world" goes with the word it belonged to.
  eq('at a boundary it removes the separator as well', EU.eraseWord('hello world', 6), { text: 'world', pos: 0 })
  eq('mid-word caret', EU.eraseWord('hello world', 8), { text: 'hello rld', pos: 6 })
  eq('third word', EU.eraseWord('one two three', 8), { text: 'one three', pos: 4 })
  eq('whole string when the caret is at the end', EU.eraseWord('word', 4), { text: '', pos: 0 })
  eq('empty input', EU.eraseWord('', 0), { text: '', pos: 0 })
  eq('nothing before the caret is an exact no-op', EU.eraseWord('abc', 0), { text: 'abc', pos: 0 })
})

group('eraseWord is boundaryBackward composed with a splice', () => {
  // The invariant the inline fields rely on: eraseWord(text, pos) must be
  // exactly text with [boundaryBackward(text, pos), pos) removed and the
  // caret moved to the cut. Verified across the shapes the panels hit.
  for (const [text, pos] of [
    ['hello world', 11],
    ['hello world', 6],
    ['hello world', 8],
    ['one two three', 8],
    ['  leading', 9],
    ['trailing  ', 8],
    ['tabs\there', 6],
    ['a', 1],
  ]) {
    const cut = EU.boundaryBackward(text, pos)
    eq(
      `eraseWord == splice at boundaryBackward for ${JSON.stringify(text)}@${pos}`,
      EU.eraseWord(text, pos),
      { text: text.slice(0, cut) + text.slice(pos), pos: cut },
    )
  }
})

group('none of them throw on a caret past the end', () => {
  noThrow('boundaryBackward past end', () => EU.boundaryBackward('abc', 99))
  noThrow('boundaryForward past end', () => EU.boundaryForward('abc', 99))
  noThrow('eraseWord past end', () => EU.eraseWord('abc', 99))
  noThrow('boundaryBackward at a negative offset', () => EU.boundaryBackward('abc', -5))
  noThrow('boundaryForward at a negative offset', () => EU.boundaryForward('abc', -5))
})

group('an out-of-range caret is clamped, not crashed on', () => {
  eq('boundaryBackward clamps to 0', EU.boundaryBackward('abc', 99), 0)
  eq('boundaryForward clamps to the length', EU.boundaryForward('abc', 99), 3)
  eq('a negative offset clamps to 0', EU.boundaryBackward('abc', -5), 0)
  eq('boundaryForward from a negative offset', EU.boundaryForward('abc', -5), 3)
  // The caret position of a returned value is always inside the new text, so
  // a field that applies it cannot put its cursor out of range.
  for (const [text, pos] of [['hello world', 11], ['abc', 99], ['a b c', 4], ['  ', 2]]) {
    const r = EU.eraseWord(text, pos)
    is(
      `caret inside the new text for ${JSON.stringify(text)}@${pos}`,
      r,
      (v) => v.pos >= 0 && v.pos <= v.text.length,
      'pos within [0, text.length]',
    )
  }
})

section('ImageExts - the wallpaper image extension table')
group('EXTS is the published table', () => {
  is('EXTS is a non-empty object', IE.EXTS, (v) => v && typeof v === 'object' && Object.keys(v).length > 0, 'non-empty object')
  // The source comment describes the shared literal as "21-entry"; the table
  // holds 22 (pnm, pgm, pbm, ppm are all separate keys). The count is pinned
  // to the table, not the prose, so adding an extension is a visible diff
  // here and stale wording in the comment does not fail the suite.
  eq('exactly 22 entries', Object.keys(IE.EXTS).length, 22)
  is('every entry is truthy', IE.EXTS, (v) => Object.values(v).every(Boolean), 'all values truthy')
})

group('ok() takes a filename and reads the extension after the last dot', () => {
  eq('a png file', IE.ok('wall.png'), true)
  eq('a jpg file', IE.ok('wall.jpg'), true)
  eq('a bare extension with no dot is not a file', IE.ok('png'), false)
  eq('two dots uses the last one', IE.ok('my.png.txt'), false)
  eq('two dots, image last', IE.ok('my.txt.png'), true)
  eq('a dotfile named .png', IE.ok('.png'), true)
  eq('no extension at all', IE.ok('wallpaper'), false)
  eq('a trailing dot', IE.ok('wall.'), false)
})

group('the extension match is case-insensitive', () => {
  eq('uppercase', IE.ok('WALL.PNG'), true)
  eq('mixed case', IE.ok('Wall.Png'), true)
  eq('uppercase on a dotfile', IE.ok('.PNG'), true)
})

group('excludes the animated formats on purpose', () => {
  // The library header is explicit: gif and mng are excluded because Qt
  // caches every decoded frame as RGBA, so a small gif costs gigabytes of
  // RAM. A regression here is a memory defect, not a cosmetic one.
  eq('gif is excluded', IE.ok('anim.gif'), false)
  eq('mng is excluded', IE.ok('anim.mng'), false)
  eq('webp is kept, animated or not', IE.ok('anim.webp'), true)
})

group('rejects non-image extensions', () => {
  for (const f of ['a.txt', 'a.pdf', 'a.zip', 'a.mp4', 'a.qml', 'a.js', 'a.qml.js']) {
    eq(`rejects ${f}`, IE.ok(f), false)
  }
})

group('ok() is total - no input shape throws', () => {
  noThrow('undefined', () => IE.ok(undefined))
  noThrow('null', () => IE.ok(null))
  noThrow('number', () => IE.ok(7))
  noThrow('object', () => IE.ok({}))
  noThrow('array', () => IE.ok(['a.png']))
  eq('a number is stringified and has no dot', IE.ok(7), false)
})

group('the table has no empty key and is keyed by extension only', () => {
  const keys = Object.keys(IE.EXTS)
  is('no empty key', keys.filter((k) => k === ''), (v) => v.length === 0, 'no empty key')
  is('no keys carry a dot', keys.filter((k) => k.includes('.')), (v) => v.length === 0, 'no dotted keys')
  is('all keys are lowercase', keys, (v) => v.every((k) => k === k.toLowerCase()), 'lowercase keys')
})

section('StringUtils.decodeEntities - the entities a markup can carry')
group('the named entities', () => {
  eq('ampersand', SU.decodeEntities('a&amp;b'), 'a&b')
  eq('less than', SU.decodeEntities('a&lt;b'), 'a<b')
  eq('greater than', SU.decodeEntities('a&gt;b'), 'a>b')
  eq('quote', SU.decodeEntities('a&quot;b'), 'a"b')
  eq('apostrophe', SU.decodeEntities('a&apos;b'), "a'b")
  eq('non-breaking space', SU.decodeEntities('a&nbsp;b'), 'a\u00a0b')
})

group('the numeric forms', () => {
  eq('decimal', SU.decodeEntities('&#65;'), 'A')
  eq('hexadecimal', SU.decodeEntities('&#x41;'), 'A')
  eq('uppercase hex', SU.decodeEntities('&#X41;'), 'A')
  eq('a code point above the ASCII range', SU.decodeEntities('&#x2192;'), '→')
})

group('an entity it does not know is left alone', () => {
  // The text reports the href of the anchor under the pointer already
  // decoded, so a markup carrying an entity outside the table cannot be
  // matched to the pointer. Decoding it by some other rule would make the
  // two disagree; leaving it is the honest answer.
  eq('an unknown name', SU.decodeEntities('a&nope;b'), 'a&nope;b')
  eq('a name without its semicolon', SU.decodeEntities('a&amp b'), 'a&amp b')
  eq('a number that is not a character', SU.decodeEntities('&#1114112;'), '&#1114112;')
  eq('a negative number', SU.decodeEntities('&#-1;'), '&#-1;')
})

group('the nullish inputs read as empty', () => {
  eq('undefined', SU.decodeEntities(undefined), '')
  eq('null', SU.decodeEntities(null), '')
  eq('empty string', SU.decodeEntities(''), '')
  eq('zero is text', SU.decodeEntities(0), '0')
})

section('StringUtils.anchorHref - which anchor points where')
group('reads the href out of the tag', () => {
  eq('double quotes', SU.anchorHref('<a href="https://example.com">'), 'https://example.com')
  eq('single quotes', SU.anchorHref("<a href='https://example.com'>"), 'https://example.com')
  eq('unquoted', SU.anchorHref('<a href=https://example.com>'), 'https://example.com')
  eq('spaces around the equals sign', SU.anchorHref('<a href = "https://example.com">'), 'https://example.com')
  eq('an uppercase attribute name', SU.anchorHref('<a HREF="https://example.com">'), 'https://example.com')
  eq('beside other attributes', SU.anchorHref('<a class="x" href="https://example.com" title="y">'), 'https://example.com')
})

group('an anchor that points at nothing', () => {
  eq('no href at all', SU.anchorHref('<a>'), '')
  eq('an empty href', SU.anchorHref('<a href="">'), '')
  eq('an attribute that only ends in href', SU.anchorHref('<a xhref="https://example.com">'), '')
})

group('the href is decoded, because the text reports it decoded', () => {
  eq('an ampersand entity', SU.anchorHref('<a href="https://example.com/?a=1&amp;b=2">'), 'https://example.com/?a=1&b=2')
  eq('a numeric entity', SU.anchorHref('<a href="https://example.com/?a=&#49;">'), 'https://example.com/?a=1')
})

section('StringUtils.underlineAnchor - the link under the pointer')
group('the matching anchor is underlined', () => {
  eq('one anchor', SU.underlineAnchor('<a href="x">link</a>', 'x'), '<a href="x"><u>link</u></a>')
  eq('the sender\'s attributes are kept', SU.underlineAnchor('<a class="c" href="x">link</a>', 'x'), '<a class="c" href="x"><u>link</u></a>')
  eq('the text around it is kept', SU.underlineAnchor('see <a href="x">link</a> here', 'x'), 'see <a href="x"><u>link</u></a> here')
})

group('the other anchors are left alone', () => {
  eq('a different href', SU.underlineAnchor('<a href="x">one</a> <a href="y">two</a>', 'y'), '<a href="x">one</a> <a href="y"><u>two</u></a>')
  eq('no anchor at all', SU.underlineAnchor('plain text', 'x'), 'plain text')
  eq('an href that is not in the markup', SU.underlineAnchor('<a href="x">one</a>', 'z'), '<a href="x">one</a>')
  eq('nothing to underline', SU.underlineAnchor('<a href="x">one</a>', ''), '<a href="x">one</a>')
})

group('the href is matched the way the text reports it', () => {
  // The text resolves the entity before it stores the anchor, so the
  // markup's &amp; and the pointer's & have to meet.
  eq('an ampersand entity matches the decoded href', SU.underlineAnchor('<a href="https://example.com/?a=1&amp;b=2">link</a>', 'https://example.com/?a=1&b=2'), '<a href="https://example.com/?a=1&amp;b=2"><u>link</u></a>')
  eq('the raw markup does not match the decoded href', SU.underlineAnchor('<a href="https://example.com/?a=1&amp;b=2">link</a>', 'https://example.com/?a=1&amp;b=2'), '<a href="https://example.com/?a=1&amp;b=2">link</a>')
})

group('every anchor with that href is underlined', () => {
  // The href alone does not say which of two anchors the pointer is on, so
  // underlining the first one would mark the wrong one as often as not.
  eq('two anchors, one href', SU.underlineAnchor('<a href="x">one</a> and <a href="x">two</a>', 'x'), '<a href="x"><u>one</u></a> and <a href="x"><u>two</u></a>')
})

group('the degenerate inputs', () => {
  eq('an anchor with no text of its own', SU.underlineAnchor('<a href="x"></a>', 'x'), '<a href="x"></a>')
  eq('empty markup', SU.underlineAnchor('', 'x'), '')
  eq('undefined markup', SU.underlineAnchor(undefined, 'x'), '')
  eq('an unclosed anchor is left alone', SU.underlineAnchor('<a href="x">link', 'x'), '<a href="x">link')
  eq('a tag that only starts with a is not an anchor', SU.underlineAnchor('<abbr href="x">link</abbr>', 'x'), '<abbr href="x">link</abbr>')
})

section('StringUtils.linkMarkup - the body as it is drawn')
group('the stylesheet comes first, so it reaches the anchors', () => {
  eq('the sheet is in front of the markup', SU.linkMarkup('body', '#cba6f7', '').indexOf('<style>') < SU.linkMarkup('body', '#cba6f7', '').indexOf('body'), true)
  eq('the anchors carry no underline of their own', SU.linkMarkup('body', '#cba6f7', ''), '<style>a { text-decoration: none; } a { color: #cba6f7; }</style>body')
  eq('the anchors are painted in the given colour', SU.linkMarkup('body', '#cba6f7', '').includes('a { color: #cba6f7; }'), true)
})

group('the hovered link is underlined, and only it', () => {
  eq('the hovered anchor', SU.linkMarkup('<a href="x">link</a>', '#fff', 'x'), '<style>a { text-decoration: none; } a { color: #fff; }</style><a href="x"><u>link</u></a>')
  eq('another anchor is left plain', SU.linkMarkup('<a href="x">one</a> <a href="y">two</a>', '#fff', 'y'), '<style>a { text-decoration: none; } a { color: #fff; }</style><a href="x">one</a> <a href="y"><u>two</u></a>')
  eq('no hovered link underlines nothing', SU.linkMarkup('<a href="x">link</a>', '#fff', ''), '<style>a { text-decoration: none; } a { color: #fff; }</style><a href="x">link</a>')
})

group('the text is not moved by the treatment', () => {
  // The underline is a decoration on the run, so the plain text and the
  // underlined one are the same text - which is what keeps the body from
  // re-wrapping under the pointer.
  const body = 'Body with <b>bold</b> and a <a href="https://example.com">hyperlink</a> here.'
  const plain = SU.linkMarkup(body, '#fff', '')
  const hovered = SU.linkMarkup(body, '#fff', 'https://example.com')
  eq('the body text is the same', plain.replace(/<style>.*<\/style>/, ''), hovered.replace(/<style>.*<\/style>/, '').replace('<u>', '').replace('</u>', ''))
})

group('a colour that is not there is simply not written', () => {
  eq('no colour', SU.linkMarkup('body', '', ''), '<style>a { text-decoration: none; }</style>body')
  eq('undefined colour', SU.linkMarkup('body', undefined, ''), '<style>a { text-decoration: none; }</style>body')
  eq('a blank colour', SU.linkMarkup('body', '   ', ''), '<style>a { text-decoration: none; }</style>body')
})

finish()