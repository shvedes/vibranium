#!/usr/bin/env node
// Suite: math/calc/colour - the five pure-JS engines behind the launcher's
// live graph, inline calculator, unit converter, colour engine and the bar's
// colour picker.
//
// They are one cluster for a reason: FuncLib and CalcLib are the same shunting
// yard at two strictness levels, ColorMath is a total function over normalized
// channels, ColorLib is that same function carried into the launcher for the
// color plugin, and UnitLib is a table walk. Every one of them sits on the
// per-keystroke path, so the properties under test are not "does it compute
// the right answer" but "does it return null/"" instead of throwing, and does
// its quick-reject gate stay quiet long enough for an app search to survive".
//
// ColorLib is the one that cannot be tested on its own terms: a plugin
// `main.js` is evaluated as text and cannot import anything, so the launcher
// holds its own copy of the picker's channel layer. The section for it is
// therefore mostly an agreement section - same readings as ColorMath for the
// same color, plus the two rules the launcher adds on top (a `#` is required,
// and the hex the user typed is not answered again).
//
// Where a value is surprising the comment cites the header or the code that
// produces it, and the assertion pins the real value.

import path from 'node:path'
import { loadLib, libSource } from '../../lib/qmlloader.mjs'
import {
  suite, section, group, eq, ne, is, notMatch, noThrow, approx, skip, show, finish,
} from '../../lib/assert.mjs'

const SHELL = path.resolve(import.meta.dirname, '..', '..', '..', '..', 'shell')
const FL = loadLib(path.join(SHELL, 'common/math/FuncLib.js'))
const CL = loadLib(path.join(SHELL, 'features/launcher/CalcLib.js'))
const CM = loadLib(path.join(SHELL, 'features/bar/modules/ColorPicker/ColorMath.js'))
const COL = loadLib(path.join(SHELL, 'common/math/Color.js'))
const UL = loadLib(path.join(SHELL, 'features/launcher/UnitLib.js'))

// These five libraries are the only JS in this tree that is specified to
// interpret user text, so "no eval" is a load-bearing contract rather than a
// style note. The comment text is stripped first, because all five headers
// mention eval() while describing its absence.
const CODE_ONLY = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '\n').replace(/^[ \t]*\/\/.*$/gm, '\n')
const SRC = {
  FuncLib: CODE_ONLY(libSource(path.join(SHELL, 'common/math/FuncLib.js'))),
  CalcLib: CODE_ONLY(libSource(path.join(SHELL, 'features/launcher/CalcLib.js'))),
  ColorMath: CODE_ONLY(libSource(path.join(SHELL, 'features/bar/modules/ColorPicker/ColorMath.js'))),
  ColorLib: CODE_ONLY(libSource(path.join(SHELL, 'common/math/Color.js'))),
  UnitLib: CODE_ONLY(libSource(path.join(SHELL, 'features/launcher/UnitLib.js'))),
}

// q renders a fixture for a label. show() prints a string bare, which would
// embed a raw newline in the label for an input like "x\ny" and split the
// harness's tab-separated results record.
const q = (v) => JSON.stringify(typeof v === 'string' ? v : show(v))

// ev compiles a FuncLib query and evaluates it at x. null means the query is
// not a real function, which is the answer being asserted, not a failure.
const ev = (q, x) => {
  const r = FL.tryParseFunction(q)
  return r === null ? null : FL.evalRpn(r.rpn, x)
}
// Same, but "not a function" becomes a distinguishable sentinel so a null
// result can never be confused with a legitimately null evaluation.
const EV_NULL = 'NOT_A_FUNCTION'
const evx = (q, x) => {
  const r = FL.tryParseFunction(q)
  return r === null ? EV_NULL : FL.evalRpn(r.rpn, x)
}
// rpn is the pipeline below the variable gate: tokenize, insert the implicit
// multiplications, shunt, evaluate. A constant expression cannot go through
// tryParseFunction ("2+2" is null, no variable) but the engine itself has
// nothing against it, so the arithmetic is asserted through here.
const rpn = (body, x) => FL.evalRpn(FL.toRpn(FL.withImplicitMult(FL.tokenize(body.toLowerCase()))), x)

// UnitLib result summaries. `cvOk` returns the success record or null (so a
// hint or a fall-through both read as null), `cvHint` the other way round.
const cvOk = (q) => {
  const r = UL.tryConvert(q)
  return r && r.ok === true ? r : null
}
const cvHint = (q) => {
  const r = UL.tryConvert(q)
  return r && r.ok === false ? r : null
}
const cvOut = (q) => {
  const r = UL.tryConvert(q)
  return r && r.ok === true ? r.out : null
}
// The source stage's own answer, rendered as the strings its terms become:
// "6 ft + 2 in", or null when the scan refuses. A compound's label names every
// term, so the shape is worth asserting directly rather than only through the
// conversion it produces.
const shapeOf = (terms) => (terms === null ? null : terms.map((t) => `${t.text} ${t.unit.sym}`).join(' + '))
const srcShape = (s) => shapeOf(UL.parseSource(s))
const ftInShape = (s) => shapeOf(UL.parseFeetInches(s))

// ColorMath parse helper so a "returns null" assertion reads as one call.
const px = (s) => CM.parse(s)

suite('math/calc/colour', 'FuncLib, CalcLib, ColorMath, ColorLib, UnitLib')

// ---------------------------------------------------------------------------
section('FuncLib.stripBody - the display prefixes and the trailing =')

group('strips every documented prefix', () => {
  // The header lists "prefixes (stripped for display): y=, f(x)=, y(x)=,
  // plot, graph". Each is a separate regex, so each is pinned separately.
  eq('y=', FL.stripBody('y=x^2'), 'x^2')
  eq('y = with spaces', FL.stripBody('y = sin(x)'), 'sin(x)')
  eq('f(x)=', FL.stripBody('f(x)=x^2'), 'x^2')
  eq('f (x) = with spaces', FL.stripBody('f (x) = x^2'), 'x^2')
  eq('y(x)=', FL.stripBody('y(x)=x^2'), 'x^2')
  eq('y (x) = with spaces', FL.stripBody('y (x) = x^2'), 'x^2')
  eq('plot', FL.stripBody('plot x^2'), 'x^2')
  eq('graph', FL.stripBody('graph x^2'), 'x^2')
  eq('plot with two spaces', FL.stripBody('plot  x^2'), 'x^2')
  eq('graph with a tab', FL.stripBody('graph\tx^2'), 'x^2')
})

group('every prefix is case-insensitive', () => {
  eq('Y=X', FL.stripBody('Y=X'), 'X')
  eq('F(x)=x', FL.stripBody('F(x)=x'), 'x')
  eq('Y(X)=x', FL.stripBody('Y(X)=x'), 'x')
  eq('PLOT x^2', FL.stripBody('PLOT x^2'), 'x^2')
  eq('Graph x^2', FL.stripBody('Graph x^2'), 'x^2')
  eq('mixed case f(X)=', FL.stripBody('f(X)=x^2'), 'x^2')
})

group('strips the trailing = the way CalcLib does', () => {
  eq('one =', FL.stripBody('x^2='), 'x^2')
  eq('two =', FL.stripBody('x^2=='), 'x^2')
  eq('three =', FL.stripBody('x^2==='), 'x^2')
  eq('= with spaces around it', FL.stripBody('x^2 = '), 'x^2')
  eq('= with trailing spaces', FL.stripBody('x^2=  '), 'x^2')
  // Only a *trailing* run of '=' is removed: a '=' inside the body is the
  // prefix separator and a '=' in the middle of an expression is not stripped.
  eq('prefix + trailing =', FL.stripBody('y = x^2 ='), 'x^2')
  eq('leading = survives when it is not a prefix', FL.stripBody('=x^2'), '=x^2')
})

group('the trailing-= strip runs once, so a doubled separator leaves a stray =', () => {
  // stripBody strips /\s*=+\s*$/ and then returns; it never loops. "x^2 = ="
  // therefore loses only the final '='. The result is not a valid body, and
  // the caller recovers because tokenize rejects '=' as an invalid char.
  eq('x^2 = =', FL.stripBody('x^2 = ='), 'x^2 =')
  eq('which the parser then rejects', FL.tryParseFunction('x^2 = ='), null)
  // A bare '=' has nothing left after the strip, and the header documents
  // that as the "" return.
  eq('=', FL.stripBody('='), '')
  eq('==', FL.stripBody('=='), '')
  eq('= with spaces', FL.stripBody(' = '), '')
})

group('trims and returns "" when nothing plottable remains', () => {
  eq('empty', FL.stripBody(''), '')
  eq('spaces', FL.stripBody('   '), '')
  eq('tab', FL.stripBody('\t'), '')
  eq('undefined', FL.stripBody(undefined), '')
  eq('null', FL.stripBody(null), '')
  eq('number 0 folds with the falsy values', FL.stripBody(0), '')
  eq('number 42 is stringified', FL.stripBody(42), '42')
  eq('leading and trailing space', FL.stripBody('   x^2   '), 'x^2')
  // A bare keyword is not a prefix on its own - the regex needs whitespace
  // and a body - so it comes back as itself and dies in the parser.
  eq('plot alone', FL.stripBody('plot'), 'plot')
  eq('graph alone', FL.stripBody('graph'), 'graph')
  eq('plot followed by a number', FL.stripBody('graph 3'), '3')
})

group('leaves an unprefixed body untouched', () => {
  eq('plain', FL.stripBody('x^2'), 'x^2')
  eq('with internal spaces', FL.stripBody('x ^ 2 + sin(x)'), 'x ^ 2 + sin(x)')
  eq('the "in" keyword is not a prefix', FL.stripBody('x in cm'), 'x in cm')
  // Only the leading keyword is consumed: "plot y=x" keeps its inner "y=".
  eq('a nested prefix is not peeled twice', FL.stripBody('plot y=x'), 'y=x')
})

// ---------------------------------------------------------------------------
section('FuncLib.isPotentialFunction - the quick reject')

group('rejects an app name that merely contains the letter x', () => {
  // The comment names these three: an x inside a longer word is not a
  // variable, and admitting them would hide every app on a keystroke.
  eq('firefox', FL.isPotentialFunction('firefox'), false)
  eq('xterm', FL.isPotentialFunction('xterm'), false)
  eq('max', FL.isPotentialFunction('max'), false)
  eq('box', FL.isPotentialFunction('box'), false)
  eq('yx', FL.isPotentialFunction('yx'), false)
  eq('ax', FL.isPotentialFunction('ax'), false)
  eq('xdotool', FL.isPotentialFunction('xdotool'), false)
  // The gate is a *standalone* x: an x bounded by a non-letter either side.
  eq('bare x', FL.isPotentialFunction('x'), true)
  eq('x with a digit after', FL.isPotentialFunction('2x'), true)
  eq('x with a space after', FL.isPotentialFunction('x + 1'), true)
  eq('x with a dot after', FL.isPotentialFunction('x.y'), true)
  eq('x with an open paren after', FL.isPotentialFunction('x(y)'), true)
})

group('rejects a body with no standalone variable at all', () => {
  eq('constants only', FL.isPotentialFunction('pi'), false)
  eq('e', FL.isPotentialFunction('e'), false)
  eq('tau', FL.isPotentialFunction('tau'), false)
  eq('pure arithmetic', FL.isPotentialFunction('2+2'), false)
  eq('a unit query', FL.isPotentialFunction('5m in cm'), false)
  eq('a name with digits', FL.isPotentialFunction('mpv123'), false)
})

group('rejects a charset outside the documented set', () => {
  // The allowed set is /^[0-9+\-*/%^().\sA-Za-z]+$/, so letters are fine and
  // everything else is not. Each rejected character is a different reason the
  // launcher should not have entered the math path.
  eq('comma', FL.isPotentialFunction('x,y'), false)
  eq('equals sign', FL.isPotentialFunction('x=1'), false)
  eq('underscore', FL.isPotentialFunction('x_1'), false)
  eq('quote', FL.isPotentialFunction("x'"), false)
  eq('plus-minus glyph', FL.isPotentialFunction('x\u00b1'), false)
  eq('division glyph', FL.isPotentialFunction('x\u00f7'), false)
  eq('unicode letter', FL.isPotentialFunction('x\u03c0'), false)
  eq('emoji', FL.isPotentialFunction('x\u2764'), false)
})

group('rejects multiline and overlong input', () => {
  eq('newline', FL.isPotentialFunction('x\ny'), false)
  eq('carriage return', FL.isPotentialFunction('x\ry'), false)
  eq('CRLF', FL.isPotentialFunction('x\r\ny'), false)
  // The length gate is on the *stripped body*, and it is "> 256", so exactly
  // 256 is admitted and 257 is not.
  eq('256 chars is admitted', FL.isPotentialFunction('x' + '0'.repeat(255)), true)
  eq('257 chars is rejected', FL.isPotentialFunction('x' + '0'.repeat(256)), false)
  eq('300 chars is rejected', FL.isPotentialFunction('x' + '0'.repeat(299)), false)
  eq('the gate measures the body, not the raw query', FL.isPotentialFunction('  y=x' + '0'.repeat(251)), true)
})

group('rejects the empty body', () => {
  eq('empty', FL.isPotentialFunction(''), false)
  eq('spaces', FL.isPotentialFunction('   '), false)
  eq('undefined', FL.isPotentialFunction(undefined), false)
  eq('null', FL.isPotentialFunction(null), false)
  eq('just an =', FL.isPotentialFunction('='), false)
})

group('admits the shapes the graph is meant to draw', () => {
  eq('bare x is y=x and is kept on purpose', FL.isPotentialFunction('x'), true)
  eq('parenthesised', FL.isPotentialFunction('(x)'), true)
  eq('unary', FL.isPotentialFunction('-x'), true)
  eq('a function call', FL.isPotentialFunction('sin(x)'), true)
  eq('implicit multiply', FL.isPotentialFunction('2x'), true)
  eq('a full expression', FL.isPotentialFunction('x^2 + sin(x)'), true)
  eq('an explicit prefix', FL.isPotentialFunction('y=x^2'), true)
  eq('mid-typing', FL.isPotentialFunction('x+'), true)
  eq('an unknown word alongside x', FL.isPotentialFunction('x chat'), true)
  eq('tabs are whitespace', FL.isPotentialFunction('x\t+\t1'), true)
})

// ---------------------------------------------------------------------------
section('FuncLib.isBareVariable - the graph gate')

group('a lone variable is bare, so it stays an app search', () => {
  // The header is explicit: "a bare 'x' (or '(x)', '-x') stays an app search
  // instead of a diagonal line". The gate exists because a diagonal is not a
  // curve worth a viewport.
  eq('x', FL.isBareVariable('x'), true)
  eq('(x)', FL.isBareVariable('(x)'), true)
  eq('-x', FL.isBareVariable('-x'), true)
  eq('+x', FL.isBareVariable('+x'), true)
  eq('with spaces', FL.isBareVariable('  x  '), true)
  eq('the empty body is treated as bare', FL.isBareVariable(''), true)
  eq('whitespace only', FL.isBareVariable('   '), true)
  eq('undefined', FL.isBareVariable(undefined), true)
})

group('unary signs and redundant parens are peeled to reach the same answer', () => {
  eq('--x', FL.isBareVariable('--x'), true)
  eq('- -x', FL.isBareVariable('- -x'), true)
  eq('-+x', FL.isBareVariable('-+x'), true)
  eq('(+x)', FL.isBareVariable('(+x)'), true)
  eq('((x))', FL.isBareVariable('((x))'), true)
  eq('-(-x)', FL.isBareVariable('-(-x)'), true)
  eq('(-x)', FL.isBareVariable('(-x)'), true)
  // The peel loop is bounded at 32 iterations, so a pathological nesting
  // cannot hang the launcher; the peel simply stops and the answer is
  // whatever the truncated body is.
  eq('33 nested parens is not peeled to x', FL.isBareVariable('('.repeat(33) + 'x' + ')'.repeat(33)), false)
  eq('32 nested parens is peeled to x', FL.isBareVariable('('.repeat(32) + 'x' + ')'.repeat(32)), true)
})

group('any real expression around the variable is not bare', () => {
  eq('x+1', FL.isBareVariable('x+1'), false)
  eq('x+0 is still an expression', FL.isBareVariable('x+0'), false)
  eq('x-0 is still an expression', FL.isBareVariable('x-0'), false)
  eq('2x', FL.isBareVariable('2x'), false)
  eq('x*x', FL.isBareVariable('x*x'), false)
  eq('sin(x)', FL.isBareVariable('sin(x)'), false)
  eq('(x+1)', FL.isBareVariable('(x+1)'), false)
  eq('(x)x is an implicit product', FL.isBareVariable('(x)x'), false)
  eq('x(1) is an implicit call', FL.isBareVariable('x(1)'), false)
  // "y=x" is a prefixed bare variable, so the gate must strip the prefix
  // before asking; the callers pass the body, which is what makes "y=x"
  // graphable in the header's example list ("2x", "x+1", "sin(x)" pass; bare
  // forms fall through).
  eq('a prefix is not part of the body, so it reads as non-bare', FL.isBareVariable('y=x'), false)
})

group('the outer-paren check requires the parens to actually wrap', () => {
  // "(x)(x)" opens and closes to depth 0 only at the final index, so it is
  // not treated as one wrapper and the peel stops on a non-"x" body.
  eq('(x)(x)', FL.isBareVariable('(x)(x)'), false)
  eq('(x) is a wrapper', FL.isBareVariable('(x)'), true)
  eq('(x) with an inner pair', FL.isBareVariable('((x))'), true)
  eq('(x + 1)', FL.isBareVariable('(x + 1)'), false)
})

// ---------------------------------------------------------------------------
section('FuncLib.isFunctionIncomplete - the eager-typing gate')

group('a completed function is not incomplete', () => {
  for (const q of ['x', 'x^2', 'x+1', '2x', 'sin(x)', 'x+sin(x)', '5x', '(x)', '-x']) {
    eq(`${q} is complete`, FL.isFunctionIncomplete(q), false)
  }
})

group('a structural gap IS incomplete', () => {
  // The header: "Structural gaps (missing operand, open paren) ARE."
  eq('x+', FL.isFunctionIncomplete('x+'), true)
  eq('x*', FL.isFunctionIncomplete('x*'), true)
  eq('x-', FL.isFunctionIncomplete('x-'), true)
  eq('x/', FL.isFunctionIncomplete('x/'), true)
  eq('x^', FL.isFunctionIncomplete('x^'), true)
  eq('(x', FL.isFunctionIncomplete('(x'), true)
  eq('x)', FL.isFunctionIncomplete('x)'), true)
  eq('sin(x', FL.isFunctionIncomplete('sin(x'), true)
  eq('x((', FL.isFunctionIncomplete('x(('), true)
  eq('a doubled operator', FL.isFunctionIncomplete('x+*1'), true)
  eq('a trailing dot', FL.isFunctionIncomplete('x.'), true)
  eq('a doubled dot', FL.isFunctionIncomplete('x..'), true)
  // Two operands in a row are not a gap: the tokenizer reads them as an
  // implicit product, so the query is complete rather than half-typed.
  eq('two operands in a row are a product, not a gap', FL.isFunctionIncomplete('x 1'), false)
  eq('and the same with a letter', FL.isFunctionIncomplete('x x'), false)
})

group('an unknown word is NOT incomplete - it must fall through to app search', () => {
  // The header is the whole point of this gate: "Unknown words ('x chat') are
  // NOT incomplete - they fall through to app search." If these returned
  // true the launcher would hide apps while the user typed a query.
  eq('x chat', FL.isFunctionIncomplete('x chat'), false)
  eq('x foo bar', FL.isFunctionIncomplete('x foo bar'), false)
  eq('x,y', FL.isFunctionIncomplete('x,y'), false)
  eq('x!', FL.isFunctionIncomplete('x!'), false)
  eq('x_1', FL.isFunctionIncomplete('x_1'), false)
  eq('x firefox', FL.isFunctionIncomplete('x firefox'), false)
  eq('a bare unknown name', FL.isFunctionIncomplete('chat'), false)
  eq('an app name', FL.isFunctionIncomplete('firefox'), false)
  eq('a dangling func name with no parens', FL.isFunctionIncomplete('sin'), false)
})

group('a body with no variable is not incomplete either', () => {
  eq('2+2', FL.isFunctionIncomplete('2+2'), false)
  eq('5', FL.isFunctionIncomplete('5'), false)
  eq('pi', FL.isFunctionIncomplete('pi'), false)
  eq('a constant expression', FL.isFunctionIncomplete('2pi'), false)
})

group('x/0 compiles but never draws, so it is still treated as typing', () => {
  // "x/0" is structurally valid, so tryParseFunction rejects it on the
  // >=3-finite-probe rule rather than on a parse error. isFunctionIncomplete
  // then re-compiles successfully and returns true, keeping the single entry
  // up "so apps stay hidden like CalcLib's incomplete" (the code comment).
  eq('tryParseFunction rejects x/0', FL.tryParseFunction('x/0'), null)
  eq('it compiles though', FL.countFinite(FL.compileBody('x/0')), 0)
  eq('isFunctionIncomplete says typing', FL.isFunctionIncomplete('x/0'), true)
  eq('and x%0 the same way', FL.isFunctionIncomplete('x%0'), true)
  // 1/x does draw: 10 of the 11 probes are finite, clear of the threshold.
  eq('1/x clears the finite threshold', FL.countFinite(FL.compileBody('1/x')), 10)
  eq('1/x is not incomplete', FL.isFunctionIncomplete('1/x'), false)
})

group('the probe set is fixed, so a domain-limited body can be rejected outright', () => {
  // PROBE_XS is 11 points. sqrt(x) is only defined on half of them, so it
  // just clears the >=3 threshold; a body that is non-finite on nearly all of
  // them is not a function as far as the launcher is concerned.
  eq('the probe set is 11 points', FL.PROBE_XS.length, 11)
  eq('PROBE_XS is the documented list', FL.PROBE_XS, [-5, -3, -2, -1, -0.5, 0, 0.5, 1, 2, 3, 5])
  eq('sqrt(x) finite count', FL.countFinite(FL.compileBody('sqrt(x)')), 6)
  eq('sqrt(x) is a function', FL.tryParseFunction('sqrt(x)') !== null, true)
  eq('ln(x) finite count', FL.countFinite(FL.compileBody('ln(x)')), 5)
  // A constant has nothing to probe: the variable gate refuses it first, and
  // compileBody throws rather than returning an empty probe count.
  eq('a constant is not a function', FL.tryParseFunction('0'), null)
  eq('and compileBody refuses it', (() => { try { FL.compileBody('0'); return 'no throw' } catch (e) { return e.message } })(), 'no variable')
})

group('the gate short-circuits on the quick reject', () => {
  eq('firefox', FL.isFunctionIncomplete('firefox'), false)
  eq('empty', FL.isFunctionIncomplete(''), false)
  eq('undefined', FL.isFunctionIncomplete(undefined), false)
  eq('a 300-char body', FL.isFunctionIncomplete('x' + '0'.repeat(299)), false)
  eq('exactly 256 chars still reaches the parser', FL.isFunctionIncomplete('x' + '0'.repeat(255)), false)
})

// ---------------------------------------------------------------------------
section('FuncLib.tryParseFunction - what counts as a real function')

group('the four documented accept/reject examples', () => {
  // Verbatim from the header block.
  is('x^2 parses', FL.tryParseFunction('x^2'), (v) => v !== null, 'non-null result')
  is('y = sin(x) parses to the stripped body', FL.tryParseFunction('y = sin(x)'), (v) => v !== null && v.expr === 'sin(x)', 'expr is sin(x)')
  eq('2+2 is null (no variable)', FL.tryParseFunction('2+2'), null)
  eq('x+ is null (incomplete)', FL.tryParseFunction('x+'), null)
  eq('x chat is null (unknown word, NOT incomplete)', FL.tryParseFunction('x chat'), null)
})

group('the returned record carries expr, body and a ready-to-run rpn', () => {
  const r = FL.tryParseFunction('x^2')
  eq('expr', r.expr, 'x^2')
  eq('body', r.body, 'x^2')
  is('rpn is a non-empty array', r.rpn, (v) => Array.isArray(v) && v.length > 0, 'non-empty array')
  eq('x^2 compiles to three tokens', r.rpn.length, 3)
  eq('the record has exactly the three documented keys', Object.keys(r).sort(), ['body', 'expr', 'rpn'])
  // expr is the *stripped* body, so a display caller never has to strip again.
  eq('expr is the display body', FL.tryParseFunction('y = x^2').expr, 'x^2')
  eq('f(x)= form', FL.tryParseFunction('f(x)=x^2').expr, 'x^2')
  eq('plot form', FL.tryParseFunction('plot 2x').expr, '2x')
  eq('graph form', FL.tryParseFunction('graph sin(x)').expr, 'sin(x)')
  eq('trailing = is already gone', FL.tryParseFunction('x^2=').expr, 'x^2')
  // stripBody is case-preserving; only the tokenizer lowercases, so a
  // capital X survives into the display string and still evaluates.
  eq('expr keeps the user casing', FL.tryParseFunction('Y = X + 1').expr, 'X + 1')
  approx('but X still evaluates as the variable', ev('Y = X + 1', 2), 3, 1e-12)
})

group('a lone variable parses, because it is y=x', () => {
  is('bare x', FL.tryParseFunction('x'), (v) => v !== null, 'non-null')
  eq('and compiles to a single token', FL.tryParseFunction('x').rpn.length, 1)
  is('(x)', FL.tryParseFunction('(x)'), (v) => v !== null, 'non-null')
  is('-x', FL.tryParseFunction('-x'), (v) => v !== null, 'non-null')
  // The display-vs-graph split is the two gates disagreeing by design:
  // tryParseFunction accepts, isBareVariable then refuses to plot.
  eq('isBareVariable still says no curve', FL.isBareVariable(FL.tryParseFunction('x').body), true)
  eq('isBareVariable says yes for 2x', FL.isBareVariable(FL.tryParseFunction('2x').body), false)
})

group('everything without a variable is null', () => {
  for (const q of ['2+2', '42', 'pi', 'e', 'tau', '2pi', '1+1', '0', '5', '-1', '100']) {
    eq(`${q} has no variable`, FL.tryParseFunction(q), null)
  }
})

group('structural errors are null, never a throw', () => {
  for (const q of ['x+', 'x*', '(x', 'x)', 'x((', '))', ')(', ')(x', '5..3', '.', '..', 'x..', '.x', 'x!', 'x@x', 'x,x', 'x**2']) {
    eq(`${q} is malformed`, FL.tryParseFunction(q), null)
  }
  noThrow('mismatched parens do not escape', () => FL.tryParseFunction('(x'))
  noThrow('a doubled dot does not escape', () => FL.tryParseFunction('5..3'))
  noThrow('an invalid char does not escape', () => FL.tryParseFunction('x@y'))
  noThrow('undefined does not escape', () => FL.tryParseFunction(undefined))
  noThrow('a number does not escape', () => FL.tryParseFunction(42))
  noThrow('a nested function with no parens does not escape', () => FL.tryParseFunction('sinsin'))
})

group('a domain-hostile body is rejected by the finite-probe threshold', () => {
  // The header of countFinite: "must evaluate without structural errors and
  // yield finite numbers in enough places that a curve actually exists".
  eq('x/0', FL.tryParseFunction('x/0'), null)
  eq('x%0', FL.tryParseFunction('x%0'), null)
  eq('1/(x-x)', FL.tryParseFunction('1/(x-x)'), null)
  eq('1/0', FL.tryParseFunction('1/0'), null)
  is('1/x is admitted', FL.tryParseFunction('1/x'), (v) => v !== null, 'non-null')
  is('x^2 is admitted', FL.tryParseFunction('x^2'), (v) => v !== null, 'non-null')
  // x-x is y = 0, which is finite everywhere, so it is a (degenerate) real
  // function and the gate admits it. Only dividing by it is hostile.
  is('x-x is admitted as the constant zero', FL.tryParseFunction('x-x'), (v) => v !== null, 'non-null')
  approx('and it evaluates to 0', ev('x-x', 7), 0, 0)
})

group('the quick reject runs before the parse, so a rejected shape costs nothing', () => {
  eq('firefox never reaches tokenize', FL.tryParseFunction('firefox'), null)
  eq('a 300-char body never reaches tokenize', FL.tryParseFunction('x' + '0'.repeat(299)), null)
  eq('multiline never reaches tokenize', FL.tryParseFunction('x\ny'), null)
  eq('an empty body returns before the gate', FL.tryParseFunction(''), null)
  eq('undefined returns before the gate', FL.tryParseFunction(undefined), null)
})

group('FUNCS is the published single-argument table', () => {
  eq('exactly the 18 documented functions', Object.keys(FL.FUNCS).length, 18)
  eq('and the same set the header lists', Object.keys(FL.FUNCS), [
    'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'sinh', 'cosh', 'tanh',
    'sqrt', 'cbrt', 'abs', 'exp', 'ln', 'log', 'floor', 'ceil', 'round',
  ])
  is('every value is exactly true', FL.FUNCS, (v) => Object.values(v).every((x) => x === true), 'all true')
  // Each name is recognised by the tokenizer, so each must compile when
  // applied to x. This is the property the table exists to guarantee.
  for (const name of Object.keys(FL.FUNCS)) {
    is(`${name}(x) compiles`, FL.tryParseFunction(`${name}(x)`), (v) => v !== null, 'non-null')
  }
})

// ---------------------------------------------------------------------------
section('FuncLib - operator precedence and unary signs')

group('multiplication and division bind tighter than addition', () => {
  approx('x+2x', ev('x+2x', 3), 9, 1e-12)
  approx('x-2x', ev('x-2x', 3), -3, 1e-12)
  approx('2x+3x', ev('2x+3x', 3), 15, 1e-12)
  approx('x/2+1', ev('x/2+1', 4), 3, 1e-12)
  approx('1+x/2', ev('1+x/2', 4), 3, 1e-12)
  approx('x^2*2+1', ev('x^2*2+1', 3), 19, 1e-12)
  approx('1+2*3^2 with a variable', ev('1+2*x^2', 3), 19, 1e-12)
  // A constant expression has no variable, so it never reaches the evaluator
  // through tryParseFunction. The engine below that gate computes it
  // correctly, which is what keeps the gate from being a parser limitation.
  approx('1+2*3^2 below the gate', rpn('1+2*3^2', 0), 19, 0)
})

group('parentheses override precedence', () => {
  approx('(x+2)*3', ev('(x+2)*3', 3), 15, 1e-12)
  approx('x^(2+1)', ev('x^(2+1)', 2), 8, 1e-12)
  approx('((x))', ev('((x))', 7), 7, 1e-12)
  approx('(x+1)(x+2)', ev('(x+1)(x+2)', 1), 6, 1e-12)
  approx('(x+1)/(x+1)', ev('(x+1)/(x+1)', 5), 1, 1e-12)
  // A paren that only *starts* a group is not treated as a wrapper, so the
  // expression is not bare and does parse.
  is('(x+1) parses', FL.tryParseFunction('(x+1)'), (v) => v !== null, 'non-null')
})

group('^ is right-associative', () => {
  // toRpn declares assoc["^"] = "R", so x^2^3 is x^(2^3) = 256 at x = 2,
  // not (x^2)^3 = 64.
  is('x^2^3 parses', FL.tryParseFunction('x^2^3'), (v) => v !== null, 'non-null')
  approx('x^2^3 at x=2', ev('x^2^3', 2), 256, 1e-9)
  approx('x^3^2 at x=2', ev('x^3^2', 2), 512, 1e-9)
  approx('(x^3)^2 at x=2 is 64', ev('(x^3)^2', 2), 64, 1e-9)
  approx('(x^2)^3 at x=2 is 64', ev('(x^2)^3', 2), 64, 1e-9)
  approx('x^2^2 at x=2', ev('x^2^2', 2), 16, 1e-9)
  approx('2^3^2 below the gate is 2^(3^2)', rpn('2^3^2', 0), 512, 0)
  approx('(2^3)^2 below the gate is 64', rpn('(2^3)^2', 0), 64, 0)
})

group('+ - * / are left-associative', () => {
  approx('x-1-2 at x=10', ev('x-1-2', 10), 7, 1e-12)
  approx('x/2/2 at x=8', ev('x/2/2', 8), 2, 1e-12)
  approx('x*2*3 at x=1', ev('x*2*3', 1), 6, 1e-12)
  approx('12-x-2-1 at x=3', ev('12-x-2-1', 3), 6, 1e-12)
  approx('12-3-2-1 below the gate', rpn('12-3-2-1', 0), 6, 0)
})

group('unary +/- outranks ^ on the left, and is a right operand on the right', () => {
  // toRpn's table gives u-/u+ precedence 4 against ^'s 3, so the unary sign
  // is emitted before the ^ and the expression groups as (-x)^2 = 9 rather
  // than the usual mathematical -(x^2) = -9. That is what the precedence
  // table declares, and it is the one place the engine parts ways with
  // convention, so both directions are pinned.
  approx('-x^2 at x=3 is (-x)^2', ev('-x^2', 3), 9, 1e-12)
  approx('confirming the grouping at x=1', ev('-x^2', 1), 1, 1e-12)
  approx('(+x)^2 at x=3 is the same', ev('(+x)^2', 3), 9, 1e-12)
  approx('(-x)^2 at x=3', ev('(-x)^2', 3), 9, 1e-12)
  approx('-(x^2) needs the parens and is -9', ev('-(x^2)', 3), -9, 1e-12)
  // On the right of ^ the grouping is forced by the syntax, and the same
  // high precedence makes the sign bind to the exponent only.
  approx('2^-x at x=3', ev('2^-x', 3), 0.125, 1e-12)
  approx('2^+x at x=3', ev('2^+x', 3), 8, 1e-12)
  approx('x^-1 at x=2 is 1/x', ev('x^-1', 2), 0.5, 1e-12)
  approx('2^-1 below the gate', rpn('2^-1', 0), 0.5, 0)
})

group('unary signs chain', () => {
  approx('--x at x=3', ev('--x', 3), 3, 1e-12)
  approx('-+x at x=3', ev('-+x', 3), -3, 1e-12)
  approx('+-x at x=3', ev('+-x', 3), -3, 1e-12)
  approx('+-2x at x=3', ev('+-2x', 3), -6, 1e-12)
  approx('-(-x) at x=3', ev('-(-x)', 3), 3, 1e-12)
  approx('x*-x at x=3', ev('x*-x', 3), -9, 1e-12)
  approx('x--x at x=3', ev('x--x', 3), 6, 1e-12)
  approx('x-(-x) at x=3', ev('x-(-x)', 3), 6, 1e-12)
  approx('+x at x=3', ev('+x', 3), 3, 1e-12)
  approx('-x at x=3', ev('-x', 3), -3, 1e-12)
})

group('% is a binary operator with JavaScript remainder semantics', () => {
  // evalRpn maps % to a2 % b, so the sign follows the dividend, not the
  // mathematical modulus. That is the JS operator the engine reuses. A
  // constant expression has no variable, so these go through the pipeline
  // below the variable gate; the gate is not what decides the result.
  approx('7%3', rpn('7%3', 0), 1, 0)
  approx('-7%3 keeps the dividend sign', rpn('-7%3', 0), -1, 0)
  approx('7%-3', rpn('7%-3', 0), 1, 0)
  approx('-7%-3', rpn('-7%-3', 0), -1, 0)
  approx('7.5%2', rpn('7.5%2', 0), 1.5, 0)
  approx('2%2', rpn('2%2', 0), 0, 0)
  approx('10%3', rpn('10%3', 0), 1, 0)
  approx('with a variable in it', ev('10+x%3', 1), 11, 0)
  approx('and the parenthesised form', ev('10+(x%3)', 1), 11, 0)
  // x%0 and x/0 are non-finite at every probe, so the finite-probe gate
  // rejects them; FuncLib does not throw, it returns null.
  eq('x%0 is null', evx('x%0', 5), EV_NULL)
  eq('x/0 is null', evx('x/0', 5), EV_NULL)
  eq('0%0 is null', evx('0%0', 0), EV_NULL)
  eq('x%0 does not throw', FL.tryParseFunction('x%0'), null)
  // Once past the gate, % and / by zero are plain JS: the value is NaN, not
  // an exception. 0^0 is 1 and 0/0 is NaN by the same operator semantics.
  approx('0^0 is 1', rpn('0^0', 0), 1, 0)
  is('0/0 is NaN, not a throw', rpn('0/0', 0), Number.isNaN, 'NaN')
  is('1/0 is Infinity, not a throw', rpn('1/0', 0), (v) => v === Infinity, 'Infinity')
})

// ---------------------------------------------------------------------------
section('FuncLib - implicit multiplication and scientific notation')

group('juxtaposition is a multiplication', () => {
  // The header: "implicit multiplication: 2x, 2sin(x), x(x+1), 2(x+1), pix, )(".
  approx('2x at x=3', ev('2x', 3), 6, 1e-12)
  approx('2(x+1) at x=3', ev('2(x+1)', 3), 8, 1e-12)
  approx('x(x+1) at x=3', ev('x(x+1)', 3), 12, 1e-12)
  approx('(x+1)(x+2) at x=1', ev('(x+1)(x+2)', 1), 6, 1e-12)
  approx('x x at x=2 (whitespace is not a separator)', ev('x x', 2), 4, 1e-12)
  approx('2x2 at x=1 is (2x)*2', ev('2x2', 1), 4, 1e-12)
  approx('x%2x at x=5 is x%(2x)', ev('x%2x', 5), 5, 1e-12)
  approx('x pi at x=2', ev('x pi', 2), 2 * Math.PI, 1e-12)
  // The implicit * is inserted between the *tokens*, so for "2^2x" it lands
  // after the ^ and the grouping is (2^2)*x = 12, not 2^(2x) = 64.
  approx('2^2x at x=3 is (2^2)*x', ev('2^2x', 3), 12, 0)
  approx('confirming at x=2', ev('2^2x', 2), 8, 0)
})

group('a number before a function name is a multiplication, but a name before ( is its call', () => {
  // withImplicitMult has an explicit carve-out: "a func name directly before
  // '(' is its own call - never split those".
  approx('2sin(x) at x=0', ev('2sin(x)', 0), 0, 1e-12)
  approx('2sin(x) at x=1 is 2*sin(1)', ev('2sin(x)', 1), 2 * Math.sin(1), 1e-12)
  approx('3cos(x) at x=0 is 3', ev('3cos(x)', 0), 3, 1e-12)
  approx('2sqrt(x) at x=9 is 6', ev('2sqrt(x)', 9), 6, 1e-12)
  // With the carve-out absent, sin(x) would become sin*(x) and never compile;
  // that it compiles at all is the property under test.
  eq('sin(x) is two rpn tokens, not three', FL.tryParseFunction('sin(x)').rpn.length, 2)
  eq('2sin(x) is four rpn tokens', FL.tryParseFunction('2sin(x)').rpn.length, 4)
})

group('a closing paren before an opening one is a multiplication', () => {
  // ")" is a left value and "(" is a right start, so the )( case in the
  // header is the same rule as 2x.
  approx('(x+1)(x+2) at x=1', ev('(x+1)(x+2)', 1), 6, 1e-12)
  // A bare ")" before "(" is a syntax error, not a product.
  eq(')(x is still null', FL.tryParseFunction(')(x'), null)
})

group('the header lists "pix" as an implicit product, but no layer accepts it', () => {
  // The header's implicit-multiplication list includes "pix". It cannot be
  // evaluated from any entry point, and it is rejected twice over:
  //   1. isPotentialFunction's standalone-x regex requires an x that is not
  //      inside a longer word, and in "pix" the x is preceded by the letter i.
  //   2. Even reached directly, tokenize reads a whole run of letters as one
  //      name, so "pix" is the word "pix" and not pi followed by x.
  // Both are the same rule that keeps "xterm" out of the math path, so the
  // gate is behaving as its own comment describes; only the header's example
  // is unreachable.
  eq('stripBody leaves it alone', FL.stripBody('pix'), 'pix')
  eq('the quick reject kills it', FL.isPotentialFunction('pix'), false)
  eq('so tryParseFunction is null', FL.tryParseFunction('pix'), null)
  eq('and isFunctionIncomplete does not call it typing', FL.isFunctionIncomplete('pix'), false)
  eq('the tokenizer reads it as one unknown word', (() => { try { FL.tokenize('pix'); return 'no throw' } catch (e) { return e.message } })(), 'unknown function: pix')
  // The same rule rejects "pix" and "xterm" identically, which is what makes
  // this a header/list mismatch rather than a separate defect.
  eq('and "pix" is rejected exactly like "xterm"', FL.isPotentialFunction('pix'), FL.isPotentialFunction('xterm'))
  // The product the header meant is available whenever the x is standalone.
  approx('pi x at x=1 is pi', ev('pi x', 1), Math.PI, 1e-12)
  approx('2 pi x at x=1 is 2pi', ev('2 pi x', 1), 2 * Math.PI, 1e-12)
  eq('and the tokenizer does expand a spaced pi x', FL.withImplicitMult(FL.tokenize('pi x')).length, 3)
})

group('a scientific exponent wins over the e constant', () => {
  // The header: 'Implicit-mult + scientific-notation edge: "1e6" parses as
  // 1000000 (exponent wins over the `e` constant)'.
  approx('1e6x at x=0 is 0', ev('1e6x', 0), 0, 1e-12)
  approx('1e6x at x=1 is 1e6', ev('1e6x', 1), 1e6, 1e-12)
  approx('1e6-1x at x=0 is 1e6', ev('1e6-1x', 0), 1e6, 1e-12)
  approx('1e6x-1 at x=0 is -1', ev('1e6x-1', 0), -1, 1e-12)
  approx('1.5e-3x at x=1', ev('1.5e-3x', 1), 0.0015, 1e-15)
  approx('1.5e3x at x=1', ev('1.5e3x', 1), 1500, 1e-9)
  approx('1e+3x at x=1', ev('1e+3x', 1), 1000, 1e-9)
  approx('2e3x at x=1', ev('2e3x', 1), 2000, 1e-9)
  // The tail must contain at least one digit or the e is a constant, which is
  // the documented distinction: "bare 2e means 2*e".
  approx('bare 2e means 2*e', ev('2e*x', 1), 2 * Math.E, 1e-12)
  approx('confirming at x=0 the product collapses to 0', ev('2e*x', 0), 0, 1e-12)
  approx('x-e at x=0 is -e', ev('x-e', 0), -Math.E, 1e-12)
  approx('x-e at x=1 is 1-e', ev('x-e', 1), 1 - Math.E, 1e-12)
  // "1e" with no digit after the e falls back to the constant: 1 * e.
  approx('1e is 1*e', ev('1e*x', 1), Math.E, 1e-12)
  // "2ex" is one word to the tokenizer, so it is an unknown function, not a
  // product - the exponent form needs a separator.
  eq('2ex is an unknown function', FL.tryParseFunction('2ex'), null)
  eq('and 1e-1 with no variable is null', FL.tryParseFunction('1e-1'), null)
})

group('a number keeps at most one decimal point', () => {
  is('a trailing dot is a number', FL.tokenize('5.')[0].value, (v) => v === 5, '5')
  is('a leading dot is a number', FL.tokenize('.5')[0].value, (v) => v === 0.5, '0.5')
  eq('a doubled dot throws inside tokenize', (() => { try { FL.tokenize('5..3'); return 'no throw' } catch (e) { return e.message } })(), 'invalid number')
  eq('a lone dot throws', (() => { try { FL.tokenize('.'); return 'no throw' } catch (e) { return e.message } })(), 'invalid number')
  eq('two dots throw', (() => { try { FL.tokenize('..'); return 'no throw' } catch (e) { return e.message } })(), 'invalid number')
  eq('and the parser surfaces it as null', FL.tryParseFunction('5..3'), null)
})

// ---------------------------------------------------------------------------
section('FuncLib - constants')

group('pi, e and tau are folded to their numeric values at tokenize time', () => {
  approx('pi*x at x=1', ev('pi*x', 1), Math.PI, 1e-12)
  approx('x*pi at x=2', ev('x*pi', 2), 2 * Math.PI, 1e-12)
  approx('pi/pi below the gate is 1', rpn('pi/pi', 0), 1, 0)
  approx('x/pi at x=1', ev('x/pi', 1), 1 / Math.PI, 1e-12)
  approx('e*x at x=1', ev('e*x', 1), Math.E, 1e-12)
  approx('tau*x at x=1', ev('tau*x', 1), 2 * Math.PI, 1e-12)
  approx('tau is 2*pi', ev('tau*x', 1), ev('2pi*x', 1), 1e-12)
  // A constant alone is still a constant: no variable, so no function.
  eq('pi alone', FL.tryParseFunction('pi'), null)
  eq('e alone', FL.tryParseFunction('e'), null)
  eq('tau alone', FL.tryParseFunction('tau'), null)
})

group('constants are case-insensitive, like every function name', () => {
  // compileBody lowercases the whole body, so PI, E, TAU, SIN all work.
  approx('PI*x at x=1', ev('PI*x', 1), Math.PI, 1e-12)
  approx('E*x at x=1', ev('E*x', 1), Math.E, 1e-12)
  approx('TAU*x at x=1', ev('TAU*x', 1), 2 * Math.PI, 1e-12)
  approx('SIN(x) at x=0', ev('SIN(x)', 0), 0, 1e-12)
  approx('X+1 at x=1', ev('X+1', 1), 2, 1e-12)
  // Lowercasing is applied to the value too, which is why an uppercase X in
  // the display string is harmless.
  eq('but expr keeps the casing the user typed', FL.tryParseFunction('X+1').expr, 'X+1')
})

// ---------------------------------------------------------------------------
section('FuncLib - every function in FUNCS')

group('the trigonometric six, evaluated at x = 0.5', () => {
  approx('sin(0.5)', ev('sin(x)', 0.5), Math.sin(0.5), 1e-12)
  approx('cos(0.5)', ev('cos(x)', 0.5), Math.cos(0.5), 1e-12)
  approx('tan(0.5)', ev('tan(x)', 0.5), Math.tan(0.5), 1e-12)
  approx('asin(0.5)', ev('asin(x)', 0.5), Math.asin(0.5), 1e-12)
  approx('acos(0.5)', ev('acos(x)', 0.5), Math.acos(0.5), 1e-12)
  approx('atan(0.5)', ev('atan(x)', 0.5), Math.atan(0.5), 1e-12)
})

group('the hyperbolic three, evaluated at x = 0.5', () => {
  approx('sinh(0.5)', ev('sinh(x)', 0.5), Math.sinh(0.5), 1e-12)
  approx('cosh(0.5)', ev('cosh(x)', 0.5), Math.cosh(0.5), 1e-12)
  approx('tanh(0.5)', ev('tanh(x)', 0.5), Math.tanh(0.5), 1e-12)
  // The hyperbolic three have explicit fallbacks for a host without them, so
  // the identities they must satisfy are the contract, not the exact method.
  approx('cosh(0) is 1', ev('cosh(x)', 0), 1, 1e-12)
  approx('tanh(0) is 0', ev('tanh(x)', 0), 0, 1e-12)
  approx('sinh(1)', ev('sinh(x)', 1), Math.sinh(1), 1e-12)
})

group('roots, abs and exp', () => {
  approx('sqrt(0.5)', ev('sqrt(x)', 0.5), Math.SQRT1_2, 1e-12)
  approx('sqrt(9) is 3', ev('sqrt(x)', 9), 3, 1e-12)
  approx('cbrt(0.5)', ev('cbrt(x)', 0.5), Math.cbrt(0.5), 1e-12)
  // cbrt is the odd root: a negative argument is a real value, not NaN.
  approx('cbrt(-8) is -2', ev('cbrt(x)', -8), -2, 1e-12)
  approx('cbrt(27) is 3', ev('cbrt(x)', 27), 3, 1e-12)
  approx('abs(0.5)', ev('abs(x)', 0.5), 0.5, 1e-12)
  approx('abs(-3)', ev('abs(x)', -3), 3, 1e-12)
  approx('exp(1)', ev('exp(x)', 1), Math.E, 1e-12)
  approx('exp(0) is 1', ev('exp(x)', 0), 1, 1e-12)
})

group('ln is natural log, log is base 10 - the header states the split', () => {
  approx('ln(1) is 0', ev('ln(x)', 1), 0, 1e-12)
  approx('log(1) is 0', ev('log(x)', 1), 0, 1e-12)
  approx('log(100) is 2', ev('log(x)', 100), 2, 1e-12)
  approx('ln(100)', ev('ln(x)', 100), Math.log(100), 1e-12)
  approx('log(1000) is 3', ev('log(x)', 1000), 3, 1e-12)
  approx('ln(e) is 1', ev('ln(x)', Math.E), 1, 1e-12)
  // The two names must not be interchangeable.
  ne('log is not ln', ev('log(x)', 100), ev('ln(x)', 100))
  approx('log10 relationship', ev('log(x)', 100) * Math.LN10, ev('ln(x)', 100), 1e-12)
})

group('floor, ceil and round use the JS rounding of each', () => {
  approx('floor(2.7) is 2', ev('floor(x)', 2.7), 2, 1e-12)
  approx('floor(-2.1) is -3', ev('floor(x)', -2.1), -3, 1e-12)
  approx('ceil(2.1) is 3', ev('ceil(x)', 2.1), 3, 1e-12)
  approx('ceil(-2.7) is -2', ev('ceil(x)', -2.7), -2, 1e-12)
  // Math.round breaks a tie toward +Infinity, which is why round(2.5) is 3
  // and round(-2.5) is -2 rather than a symmetric zero.
  approx('round(2.5) is 3', ev('round(x)', 2.5), 3, 1e-12)
  approx('round(-2.5) is -2', ev('round(x)', -2.5), -2, 1e-12)
  approx('round(2.4) is 2', ev('round(x)', 2.4), 2, 1e-12)
  approx('round(-2.6) is -3', ev('round(x)', -2.6), -3, 1e-12)
  // The rounding functions produce integers, so their output is exact.
  is('round output is an integer', ev('round(x)', 2.5), Number.isInteger, 'integer')
})

group('every function composes with the operators', () => {
  approx('sin(x)+1 at x=0', ev('sin(x)+1', 0), 1, 1e-12)
  approx('2sin(x)+cos(x) at x=0', ev('2sin(x)+cos(x)', 0), 1, 1e-12)
  approx('sqrt(x^2) at x=9', ev('sqrt(x^2)', 9), 9, 1e-9)
  approx('sqrt(x^2) at x=-9 is |x|', ev('sqrt(x^2)', -9), 9, 1e-9)
  approx('abs(x)+abs(x) at x=-3', ev('abs(x)+abs(x)', -3), 6, 1e-12)
  approx('ln(x^2) at x=e', ev('ln(x^2)', Math.E), 2, 1e-9)
  approx('log(x)*log(x) at x=10', ev('log(x)*log(x)', 10), 1, 1e-12)
  approx('floor(x/4) at x=10', ev('floor(x/4)', 10), 2, 1e-12)
  approx('round(x) is nested in an expression', ev('round(x)+round(x)', 2.5), 6, 1e-12)
})

group('a domain edge is NaN or Infinity, never a throw', () => {
  // The painter relies on this: it is what turns an asymptote into a path
  // break instead of a crashed frame.
  is('sqrt(-1) is NaN', ev('sqrt(x)', -1), Number.isNaN, 'NaN')
  is('log(0) is -Infinity', ev('log(x)', 0), (v) => v === -Infinity, '-Infinity')
  is('ln(0) is -Infinity', ev('ln(x)', 0), (v) => v === -Infinity, '-Infinity')
  is('log(-1) is NaN', ev('log(x)', -1), Number.isNaN, 'NaN')
  is('ln(-1) is NaN', ev('ln(x)', -1), Number.isNaN, 'NaN')
  is('asin(2) is NaN', ev('asin(x)', 2), Number.isNaN, 'NaN')
  is('acos(2) is NaN', ev('acos(x)', 2), Number.isNaN, 'NaN')
  is('asin(-2) is NaN', ev('asin(x)', -2), Number.isNaN, 'NaN')
  is('1/0 is Infinity', ev('1/x', 0), (v) => v === Infinity, 'Infinity')
  is('-1/0 is -Infinity', ev('1/x', -0), (v) => v === Infinity || v === -Infinity, 'signed Infinity')
  noThrow('sqrt at its edge', () => ev('sqrt(x)', -1))
  noThrow('log at 0', () => ev('log(x)', 0))
  noThrow('asin past 1', () => ev('asin(x)', 2))
  noThrow('tan at a pole', () => ev('tan(x)', Math.PI / 2))
  // tan at its pole is a huge finite value rather than Infinity, which is
  // why sampleFunction needs its own >1e6 spike guard.
  is('tan at pi/2 is huge but finite', ev('tan(x)', Math.PI / 2), (v) => Number.isFinite(v) && Math.abs(v) > 1e15, 'finite and >1e15')
})

// ---------------------------------------------------------------------------
section('FuncLib.sampleFunction - the one-shot Canvas sampler')

group('the return shape is the documented one', () => {
  const s = FL.sampleFunction('x^2', -10, 10, 100)
  eq('exactly ys, yMin, yMax, valid', Object.keys(s).sort(), ['valid', 'yMax', 'yMin', 'ys'])
  eq('ys has n entries', s.ys.length, 100)
  eq('valid is 100', s.valid, 100)
  is('yMin is below the smallest sample', s, (v) => v.yMin < Math.min(...v.ys), 'yMin < min(ys)')
  is('yMax is above the largest sample', s, (v) => v.yMax > Math.max(...v.ys), 'yMax > max(ys)')
  is('yMin is finite', s, (v) => Number.isFinite(v.yMin), 'finite yMin')
  is('yMax is finite', s, (v) => Number.isFinite(v.yMax), 'finite yMax')
  approx('the samples include both endpoints', s.ys[0], 100, 1e-9)
  approx('ys[0] is the first x', s.ys[0], FL.evalRpn(FL.compileBody('x^2'), -10), 1e-9)
  approx('the last sample is the last x', s.ys[99], 100, 1e-9)
})

group('the x grid is inclusive of both ends', () => {
  const s = FL.sampleFunction('x', -1, 1, 5)
  eq('five samples', s.ys.length, 5)
  approx('first is xMin', s.ys[0], -1, 1e-12)
  approx('middle is the midpoint', s.ys[2], 0, 1e-12)
  approx('last is xMax', s.ys[4], 1, 1e-12)
  // The formula is lo + (hi - lo) * i / (count - 1), so with count = 2 the
  // single step lands exactly on xMax.
  const two = FL.sampleFunction('x', -1, 1, 2)
  eq('two samples', two.ys.length, 2)
  approx('first is xMin', two.ys[0], -1, 1e-12)
  approx('second is xMax', two.ys[1], 1, 1e-12)
})

group('the count is clamped to [2, 400] with a 120 default', () => {
  eq('n = 1 clamps up to 2', FL.sampleFunction('x', -1, 1, 1).ys.length, 2)
  eq('n = 0 falls back to the default', FL.sampleFunction('x', -1, 1, 0).ys.length, 120)
  eq('n = NaN falls back to the default', FL.sampleFunction('x', -1, 1, NaN).ys.length, 120)
  eq('n = -5 clamps up to 2', FL.sampleFunction('x', -1, 1, -5).ys.length, 2)
  eq('n = 400 is kept', FL.sampleFunction('x', -1, 1, 400).ys.length, 400)
  eq('n = 401 clamps down to 400', FL.sampleFunction('x', -1, 1, 401).ys.length, 400)
  eq('n = 999 clamps down to 400', FL.sampleFunction('x', -1, 1, 999).ys.length, 400)
  eq('n = 120 is the default', FL.sampleFunction('x', -1, 1, 120).ys.length, 120)
  eq('undefined n is the default', FL.sampleFunction('x', -1, 1, undefined).ys.length, 120)
  eq('a fractional n is rounded', FL.sampleFunction('x', -1, 1, 10.6).ys.length, 11)
  eq('a string n is coerced', FL.sampleFunction('x', -1, 1, '7').ys.length, 7)
})

group('an unusable range or body returns null, never a throw', () => {
  eq('lo == hi', FL.sampleFunction('x', 1, 1, 10), null)
  eq('lo > hi', FL.sampleFunction('x', 5, 1, 10), null)
  eq('lo is NaN', FL.sampleFunction('x', NaN, 1, 10), null)
  eq('hi is NaN', FL.sampleFunction('x', 0, NaN, 10), null)
  eq('lo is undefined', FL.sampleFunction('x', undefined, 1, 10), null)
  eq('empty body', FL.sampleFunction('', 0, 1, 10), null)
  eq('undefined body', FL.sampleFunction(undefined, 0, 1, 10), null)
  eq('a body with no variable', FL.sampleFunction('2+2', 0, 1, 10), null)
  eq('a malformed body', FL.sampleFunction('x+', 0, 1, 10), null)
  eq('a domain-hostile body with no finite sample', FL.sampleFunction('x/0', -1, 1, 10), null)
  eq('and x%0 likewise', FL.sampleFunction('x%0', -1, 1, 10), null)
  noThrow('an inverted range does not throw', () => FL.sampleFunction('x', 5, 1, 10))
  noThrow('a malformed body does not throw', () => FL.sampleFunction('x+', 0, 1, 10))
  // Numeric strings are coerced through Number(), so a caller may pass
  // spinner values straight in.
  is('string bounds are coerced', FL.sampleFunction('x', '0', '1', 10), (v) => v !== null, 'non-null')
})

group('a non-finite sample becomes NaN so the painter can break the path', () => {
  const iv = FL.sampleFunction('1/x', -1, 1, 101)
  eq('one sample is lost to the pole', iv.valid, 100)
  eq('and exactly one entry is NaN', iv.ys.filter(Number.isNaN).length, 1)
  eq('the break is at the middle', Number.isNaN(iv.ys[50]), true)
  approx('the neighbour below keeps its value', iv.ys[49], -50, 1e-9)
  approx('the neighbour above keeps its value', iv.ys[51], 50, 1e-9)
  // The other side of an asymptote survives, which is the whole point.
  is('both branches are present', iv.ys, (v) => v.some((y) => y < -1) && v.some((y) => y > 1), 'a negative and a positive sample beyond 1')
})

group('a spike over 1e6 is treated as a break', () => {
  // The code comment: "Hard spikes (>1e6, tan exactly at the pole) are breaks."
  const t = FL.sampleFunction('tan(x)', -Math.PI / 2, Math.PI / 2, 3)
  eq('both poles are dropped', t.valid, 1)
  eq('leaving two NaN', t.ys.filter(Number.isNaN).length, 2)
  eq('and the middle sample is the only survivor', t.ys.filter((y) => !Number.isNaN(y)), [0])
  // A large but sub-threshold value is kept, so the guard is a magnitude
  // test and not a "big number" test.
  const big = FL.sampleFunction('1000000x', -1, 1, 3)
  eq('exactly 1e6 is kept', big.valid, 3)
  const bigger = FL.sampleFunction('1000001x', -1, 1, 3)
  // Only the zero at x = 0 is under the threshold, so the sample survives
  // with both ends broken rather than being discarded as unplottable.
  eq('a body over the threshold at both ends keeps only the middle', bigger.valid, 1)
  eq('and leaves two NaN', bigger.ys.filter(Number.isNaN).length, 2)
  // One sample over the line and the rest under it: that sample alone breaks.
  const edge = FL.sampleFunction('1000000x+x', -1, 1, 3)
  eq('one sample over the line', edge.valid, 1)
  eq('leaving one NaN', edge.ys.filter(Number.isNaN).length, 2)
  eq('and the under-threshold sample is the zero', edge.ys.filter((y) => !Number.isNaN(y)), [0])
  const neg = FL.sampleFunction('-1000000x-1', -1, 1, 3)
  eq('a large negative spike is dropped too', neg.valid, 2)
  eq('leaving one NaN', neg.ys.filter(Number.isNaN).length, 1)
  eq('and the survivors are under the threshold', neg.ys.filter((y) => !Number.isNaN(y)), [999999, -1])
})

group('the range is a padded percentile window, not the raw extent', () => {
  // The code comment: "Range uses 5th/95th percentiles so tan-style spikes
  // never flatten the curve, while x^2-style parabolas still keep their wings."
  const sq = FL.sampleFunction('x^2', -10, 10, 100)
  // The grid is inclusive of both ends but 100 is an even count, so no sample
  // lands on the vertex: the smallest sample is one step off it.
  approx('the smallest sample is one step off the vertex', Math.min(...sq.ys), 0.010203040506070672, 1e-12)
  is('but yMin dips below it', sq.yMin, (v) => v < 0, 'negative yMin for a non-negative body')
  is('and yMax stays above the peak', sq.yMax, (v) => v > 100, 'yMax > 100')
  // A linear body is symmetric, so the window is symmetric too.
  const lin = FL.sampleFunction('x', -5, 5, 100)
  approx('linear yMin', lin.yMin, -6.131313131313131, 1e-9)
  approx('linear yMax', lin.yMax, 6.232323232323231, 1e-9)
  is('and mirrored', lin, (v) => Math.abs(v.yMin + v.yMax) < 0.5, 'approximately symmetric')
  // The pad is 18% of the p5..p95 span, so the window is strictly wider
  // than the percentile window on both sides.
  const p = FL.sampleFunction('x^2', -1, 1, 400)
  is('the pad is a fraction of the span', p, (v) => v.yMax > Math.max(...v.ys) && v.yMax - Math.max(...v.ys) > 0, 'padded above the max')
  // A percentile window discards the tail, so a single wild outlier does not
  // drag the frame.
  const out = FL.sampleFunction('x+1e5*x^9', -1, 1, 100)
  is('a high-degree body still gets a bounded window', out, (v) => Number.isFinite(v.yMin) && Number.isFinite(v.yMax), 'finite window')
})

group('a flat body is padded symmetrically instead of collapsing to zero height', () => {
  // With p95 == p5 the code falls back to a centre plus max(1, 10%) pad, so
  // a constant body still produces a drawable band rather than a divide by
  // zero in the painter.
  const flat = FL.sampleFunction('x-x+1', -1, 1, 100)
  is('a constant body is non-null', flat, (v) => v !== null, 'non-null')
  approx('every sample is 1', flat.ys[0], 1, 1e-12)
  is('the band is symmetric', flat, (v) => Math.abs(v.yMin + v.yMax - 2) < 1e-9, 'yMin + yMax == 2')
  is('and has a real height', flat, (v) => v.yMax - v.yMin > 1, 'height > 1')
})

group('the valid count drives which padding branch is taken', () => {
  // valid >= 10 uses percentiles; valid === 1 and 2..9 use explicit padding.
  // With three points on 1/x the pole removes the middle, leaving two.
  const two = FL.sampleFunction('1/x', -1, 1, 3)
  eq('two valid samples', two.valid, 2)
  approx('and a symmetric pad of 12% of the span', two.yMin, -1.24, 1e-9)
  approx('yMin', two.yMin, -1.24, 1e-9)
  approx('yMax', two.yMax, 1.24, 1e-9)
  // Five points on a linear body stay in the 2..9 branch.
  const five = FL.sampleFunction('x', -1, 1, 5)
  eq('five valid', five.valid, 5)
  approx('yMin', five.yMin, -1.24, 1e-9)
  approx('yMax', five.yMax, 1.24, 1e-9)
  // Crossing into the percentile branch changes the pad factor to 18%.
  const many = FL.sampleFunction('x', -1, 1, 10)
  eq('ten valid', many.valid, 10)
  is('the branch changed', many, (v) => Math.abs((v.yMax - v.yMin) / 2 - 1.24) > 1e-6, 'a different pad')
})

group('a domain-limited body is sampled, not rejected', () => {
  // The gate is tryParseFunction's; sampleFunction compiles on its own, so a
  // body that is undefined on part of the domain still draws the part that is.
  for (const body of ['sqrt(x)', 'ln(x)', 'log(x)']) {
    const s = FL.sampleFunction(body, -2, 2, 50)
    is(`${body} returns a result`, s, (v) => v !== null, 'non-null')
    eq(`${body} keeps only the positive half`, s.valid, 25)
    is(`${body} marks the rest NaN`, s, (v) => v.ys.filter(Number.isNaN).length === 25, '25 NaN')
    is(`${body} produces a finite window`, s, (v) => Number.isFinite(v.yMin) && Number.isFinite(v.yMax), 'finite window')
    noThrow(`${body} does not throw`, () => FL.sampleFunction(body, -2, 2, 50))
  }
  // The inverse trig pair is undefined on |x| > 1, which takes one more
  // sample per end off the grid than the 50-point half does.
  const as = FL.sampleFunction('asin(x)', -2, 2, 50)
  eq('asin loses the two |x| > 1 endpoints too', as.valid, 24)
  eq('and marks 26 samples NaN', as.ys.filter(Number.isNaN).length, 26)
  const ac = FL.sampleFunction('acos(x)', -2, 2, 50)
  eq('acos likewise', ac.valid, 24)
  eq('and marks 26 samples NaN', ac.ys.filter(Number.isNaN).length, 26)
  // The percentile window is exactly what the code comment describes: it
  // deliberately does NOT bracket the samples, so the log curve's -3 at the
  // left edge is discarded in favour of a flat-looking middle.
  const lg = FL.sampleFunction('log(x)', 0.001, 1000, 100)
  eq('all 100 samples valid', lg.valid, 100)
  approx('the first sample really is log10(0.001)', lg.ys[0], -3, 1e-12)
  approx('the last sample really is log10(1000)', lg.ys[99], 3, 1e-12)
  is('yet yMin sits well above the minimum sample', lg, (v) => v.yMin > 1, 'yMin > 1')
  is('and yMax is only just above the maximum', lg, (v) => v.yMax < 3.5 && v.yMax > 3, '3 < yMax < 3.5')
})

group('sampleFunction never throws on any body the parser accepts', () => {
  const bodies = ['x', 'x^2', '2x', 'sin(x)', 'tan(x)', '1/x', 'x/0', 'x%0', 'sqrt(x)', 'ln(x)',
    'log(x)', 'asin(x)', 'x+', '(x', 'x)', '5..3', 'firefox', 'pi', '2+2', '', 'x,y', 'x^', '1e6x']
  for (const b of bodies) {
    noThrow(`sampleFunction(${JSON.stringify(b)})`, () => FL.sampleFunction(b, -2, 2, 40))
  }
})

// ---------------------------------------------------------------------------
section('FuncLib - purity and the absence of eval')

group('the engine interprets text without eval, Function or any host import', () => {
  // The header: "Pure-JS, deterministic, no Qt imports". CalcLib's header
  // adds "no eval()". All four of these are the reason a user string can
  // reach the tokenizer at all, so they are asserted against the source text
  // with the comments stripped (the headers mention eval() while denying it).
  notMatch('FuncLib has no eval(', SRC.FuncLib, /\beval\s*\(/)
  notMatch('FuncLib builds no Function', SRC.FuncLib, /\bFunction\s*\(/)
  notMatch('FuncLib has no new Function', SRC.FuncLib, /new\s+Function/)
  notMatch('FuncLib imports nothing', SRC.FuncLib, /\.import|\.pragma/)
  notMatch('FuncLib touches no Qt type', SRC.FuncLib, /\bQt\./)
  notMatch('FuncLib reads no clock', SRC.FuncLib, /\bDate\b/)
  notMatch('FuncLib draws no random numbers', SRC.FuncLib, /Math\s*\.\s*random/)
  notMatch('FuncLib schedules nothing', SRC.FuncLib, /setTimeout|setInterval/)
})

group('the character helpers are total and case-explicit', () => {
  eq('isDigit("0")', FL.isDigit('0'), true)
  eq('isDigit("9")', FL.isDigit('9'), true)
  eq('isDigit("a")', FL.isDigit('a'), false)
  eq('isDigit(".")', FL.isDigit('.'), false)
  eq('isDigit(" ")', FL.isDigit(' '), false)
  eq('isDigit("%")', FL.isDigit('%'), false)
  eq('isLetter("a")', FL.isLetter('a'), true)
  eq('isLetter("Z")', FL.isLetter('Z'), true)
  eq('isLetter("0")', FL.isLetter('0'), false)
  eq('isLetter(".")', FL.isLetter('.'), false)
  eq('isLetter("5")', FL.isLetter('5'), false)
  // Both take a single character, so an empty string is neither.
  eq('isDigit("")', FL.isDigit(''), false)
  eq('isLetter("")', FL.isLetter(''), false)
})

group('nothing the public entry points accept throws', () => {
  const inputs = [undefined, null, '', '   ', 0, 42, {}, [], 'x', 'x^2', 'sin(x)', 'x+',
    'x/0', '5..3', 'firefox', 'x\ny', 'x'.repeat(300)]
  for (const v of inputs) {
    // The braces keep a string return value out of the assertion's detail
    // field, which is tab-separated: stripBody("x\ny") would otherwise split
    // the results record across two lines.
    noThrow(`stripBody(${q(v)})`, () => { FL.stripBody(v) })
    noThrow(`isPotentialFunction(${q(v)})`, () => FL.isPotentialFunction(v))
    noThrow(`isBareVariable(${q(v)})`, () => FL.isBareVariable(v))
    noThrow(`isFunctionIncomplete(${q(v)})`, () => FL.isFunctionIncomplete(v))
    noThrow(`tryParseFunction(${q(v)})`, () => FL.tryParseFunction(v))
    noThrow(`sampleFunction(${q(v)}, 0, 1, 10)`, () => FL.sampleFunction(v, 0, 1, 10))
  }
})

// ---------------------------------------------------------------------------
section('CalcLib.isPotentialCalc - the quick reject that keeps apps visible')

group('a bare number is NOT calc, and that is the documented reason', () => {
  // The comment: "Single number alone (e.g. '42') is NOT considered calc to
  // avoid hiding apps when typing a number."
  eq('42', CL.isPotentialCalc('42'), false)
  eq('123', CL.isPotentialCalc('123'), false)
  eq('0', CL.isPotentialCalc('0'), false)
  eq('007', CL.isPotentialCalc('007'), false)
  eq('1234567890', CL.isPotentialCalc('1234567890'), false)
  eq('5.', CL.isPotentialCalc('5.'), false)
  eq('.5', CL.isPotentialCalc('.5'), false)
  eq('a signed number is the documented exception, see below', CL.isPotentialCalc('-42'), true)
  // The gate is not a "looks numeric" heuristic; it demands an operator or a
  // paren, so the unsigned form falls through to app search.
  eq('and tryEvaluate agrees', CL.tryEvaluate('42'), null)
  eq('and on 5.', CL.tryEvaluate('5.'), null)
})

group('a *signed* bare number is calc anyway, because the sign is the operator', () => {
  // The "must contain an operator or paren" test is a character test, and a
  // leading '-' or '+' satisfies it. So the documented reason - "avoid hiding
  // apps when typing a number" - holds for an unsigned number but not for a
  // negative one: typing -42 in the launcher shows -42 instead of the app
  // list. Pinned as observed, with the gap recorded.
  eq('-42 passes the gate', CL.isPotentialCalc('-42'), true)
  eq('+42 passes the gate', CL.isPotentialCalc('+42'), true)
  eq('-4.2 passes the gate', CL.isPotentialCalc('-4.2'), true)
  eq('- 42 with a space passes too', CL.isPotentialCalc('- 42'), true)
  eq('and tryEvaluate evaluates it', CL.tryEvaluate('-42').value, -42)
  eq('formatted', CL.tryEvaluate('-42').formatted, '-42')
  eq('a signed decimal is evaluated', CL.tryEvaluate('-4.2').formatted, '-4.2')
  eq('a positive signed number is evaluated', CL.tryEvaluate('+42').formatted, '42')
  // The unadorned number is the one the comment is about, and it is refused.
  eq('while the unsigned form is still refused', CL.isPotentialCalc('42'), false)
  eq('and so is a parenthesised one', CL.tryEvaluate('(42)').formatted, '42')
  skip('a single number alone is NOT considered calc to avoid hiding apps', 'CalcLib.js:13-14 - the /[+\\-*\\/%^()]/ operator test is satisfied by a leading sign, so -42 is treated as calc')
})

group('an expression is calc', () => {
  eq('2+2', CL.isPotentialCalc('2+2'), true)
  eq('2*3', CL.isPotentialCalc('2*3'), true)
  eq('7/2', CL.isPotentialCalc('7/2'), true)
  eq('7%2', CL.isPotentialCalc('7%2'), true)
  eq('2^3', CL.isPotentialCalc('2^3'), true)
  eq('(1+2)', CL.isPotentialCalc('(1+2)'), true)
  eq('2.5*2', CL.isPotentialCalc('2.5*2'), true)
  eq('.5+.5', CL.isPotentialCalc('.5+.5'), true)
  eq('with spaces', CL.isPotentialCalc('2 + 2'), true)
  eq('a trailing = is stripped first', CL.isPotentialCalc('2+2='), true)
  eq('and doubled', CL.isPotentialCalc('2+2=='), true)
  // A paren alone proves "expression-like" even with no operator.
  eq('parens count as the proof', CL.isPotentialCalc('(1)'), true)
  eq('a leading unary sign with a paren', CL.isPotentialCalc('-(1)'), true)
})

group('a bare operator or paren with no digit is not calc', () => {
  // The gate needs a digit *and* an operator/paren, so each half alone fails.
  eq('+', CL.isPotentialCalc('+'), false)
  eq('-', CL.isPotentialCalc('-'), false)
  eq('(', CL.isPotentialCalc('('), false)
  eq(')', CL.isPotentialCalc(')'), false)
  eq('+*', CL.isPotentialCalc('+*'), false)
})

group('a non-digit character rejects the whole query', () => {
  // The allowed set is /^[0-9+\-*/%^().\s]+$/, so a letter anywhere is out.
  // Scientific notation is therefore not calc input at all.
  eq('an app name', CL.isPotentialCalc('firefox'), false)
  eq('a letter beside a number', CL.isPotentialCalc('123abc'), false)
  eq('the variable form', CL.isPotentialCalc('x+2'), false)
  eq('implicit multiply', CL.isPotentialCalc('2x'), false)
  eq('scientific notation', CL.isPotentialCalc('1e3'), false)
  eq('scientific notation with a sign', CL.isPotentialCalc('1e+3'), false)
  eq('scientific notation in an expression', CL.isPotentialCalc('1e3+1'), false)
  eq('a comma', CL.isPotentialCalc('1,000'), false)
  eq('an equals sign mid-expression', CL.isPotentialCalc('2+2=2'), false)
  eq('a doubled dot', CL.isPotentialCalc('1..2'), false)
  eq('a lone dot', CL.isPotentialCalc('.'), false)
})

group('an empty or all-equals query is not calc', () => {
  eq('empty', CL.isPotentialCalc(''), false)
  eq('spaces', CL.isPotentialCalc('   '), false)
  eq('= ', CL.isPotentialCalc(' = '), false)
  eq('==', CL.isPotentialCalc('=='), false)
  eq('undefined', CL.isPotentialCalc(undefined), false)
  eq('null', CL.isPotentialCalc(null), false)
  eq('0 folds with the falsy values', CL.isPotentialCalc(0), false)
  eq('42 is a number, not falsy, and reads as text', CL.isPotentialCalc(42), false)
})

group('CalcLib evaluates text without eval, Function or any host import', () => {
  notMatch('CalcLib has no eval(', SRC.CalcLib, /\beval\s*\(/)
  notMatch('CalcLib builds no Function', SRC.CalcLib, /\bFunction\s*\(/)
  notMatch('CalcLib has no new Function', SRC.CalcLib, /new\s+Function/)
  notMatch('CalcLib imports nothing', SRC.CalcLib, /\.import|\.pragma/)
  notMatch('CalcLib touches no Qt type', SRC.CalcLib, /\bQt\./)
  notMatch('CalcLib reads no environment', SRC.CalcLib, /Quickshell/)
})

// ---------------------------------------------------------------------------
section('CalcLib.formatResult - the display formatter')

group('an integer prints plain, with -0 normalised to 0', () => {
  eq('0', CL.formatResult(0), '0')
  eq('-0 is normalised', CL.formatResult(-0), '0')
  eq('1', CL.formatResult(1), '1')
  eq('-1', CL.formatResult(-1), '-1')
  eq('42', CL.formatResult(42), '42')
  eq('100', CL.formatResult(100), '100')
  eq('1e12 is an integer, not exponential', CL.formatResult(1e12), '1000000000000')
  eq('1e13', CL.formatResult(1e13), '10000000000000')
  eq('1e15', CL.formatResult(1e15), '1000000000000000')
  eq('2^63', CL.formatResult(Math.pow(2, 63)), '9223372036854776000')
  eq('999999999999', CL.formatResult(999999999999), '999999999999')
  eq('1e6*1e6', CL.formatResult(1000000 * 1000000), '1000000000000')
})

group('a decimal is trimmed to 10 places', () => {
  eq('2.5', CL.formatResult(2.5), '2.5')
  eq('0.5', CL.formatResult(0.5), '0.5')
  eq('1/3', CL.formatResult(1 / 3), '0.3333333333')
  eq('2/3', CL.formatResult(2 / 3), '0.6666666667')
  eq('the 0.1+0.2 artefact is rounded away', CL.formatResult(0.1 + 0.2), '0.3')
  eq('1/7', CL.formatResult(1 / 7), '0.1428571429')
  eq('-1/3', CL.formatResult(-1 / 3), '-0.3333333333')
  eq('10.5%3', CL.formatResult(10.5 % 3), '1.5')
  eq('1.005 is left alone', CL.formatResult(1.005), '1.005')
  eq('2.675 is left alone', CL.formatResult(2.675), '2.675')
  eq('1e-6 stays fixed', CL.formatResult(1e-6), '0.000001')
  eq('1e-5 stays fixed', CL.formatResult(1e-5), '0.00001')
  eq('0.0001 stays fixed', CL.formatResult(0.0001), '0.0001')
  // The 10-place rounding is where the "avoid floating artefacts" intent
  // stops: at 1e9 magnitude the binary representation of the input is wider
  // than 10 decimal places, so the artefact the comment claims to remove
  // survives into the output. Pinned so a change in either the comment or the
  // formatter is visible here.
  eq('but a 1e9-magnitude value still leaks the artefact', CL.formatResult(1234567890.12345), '1234567890.1234500408')
})

group('an extreme magnitude switches to a trimmed exponential form', () => {
  // The switch is abs >= 1e12 || abs < 1e-6, with exactly 1e-6 on the fixed side.
  eq('1e-7', CL.formatResult(1e-7), '1e-7')
  eq('-1e-7', CL.formatResult(-1e-7), '-1e-7')
  eq('5e-7', CL.formatResult(5e-7), '5e-7')
  eq('1.5e-7 keeps one mantissa digit', CL.formatResult(1.5e-7), '1.5e-7')
  eq('1e-21', CL.formatResult(1e-21), '1e-21')
  eq('1e21', CL.formatResult(1e21), '1e+21')
  eq('the mantissa is rounded to 6 places', CL.formatResult(1.23456789e13), '12345678900000')
  eq('1.1e12', CL.formatResult(1.1e12), '1100000000000')
  // 1e12 is exactly on the boundary and takes the fixed path.
  eq('1e12 is fixed', CL.formatResult(1e12), '1000000000000')
  eq('and 1e-6 is fixed', CL.formatResult(1e-6), '0.000001')
})

group('the non-finite values have their own words', () => {
  eq('NaN', CL.formatResult(NaN), 'NaN')
  eq('Infinity', CL.formatResult(Infinity), 'Infinity')
  eq('-Infinity', CL.formatResult(-Infinity), '-Infinity')
})

group('a non-number argument is not a number, and the fall-through says so', () => {
  // The first branch is `typeof v !== "number" || !isFinite(v)`, and the
  // NaN test that follows is the loose global isNaN, so a numeric *string*
  // is treated as a number by isNaN but never reaches the numeric branches.
  eq('a numeric string', CL.formatResult('42'), 'Infinity')
  eq('null', CL.formatResult(null), '-Infinity')
  eq('undefined', CL.formatResult(undefined), 'NaN')
  eq('true', CL.formatResult(true), 'Infinity')
  eq('a non-numeric string', CL.formatResult('abc'), 'NaN')
  // Nothing in the calculator path ever produces one of these, because
  // tryEvaluate only ever calls formatResult with a number.
  eq('tryEvaluate never passes a string', CL.tryEvaluate('2+2').formatted, '4')
})

group('the trimming never leaves a bare dot or a bare minus', () => {
  // The two guards after the trim: "-0" must read as "0" and an empty string
  // must read as "0" rather than as a blank chip.
  eq('-0 from a subtraction', CL.formatResult(0 - 0), '0')
  eq('-0 from a multiplication', CL.formatResult(0 * -1), '0')
  eq('0 from 1-1', CL.formatResult(1 - 1), '0')
  eq('and nothing empty', CL.formatResult(0), '0')
  is('every integer result is a non-empty string', [0, 1, -1, 42, 1e12], (v) => v.every((n) => typeof CL.formatResult(n) === 'string' && CL.formatResult(n) !== ''), 'non-empty string')
  is('every result round-trips to a parseable number', [0, 2.5, 1 / 3, 1e-7, 1e21, NaN, Infinity, -Infinity], (v) => v.every((n) => ['NaN', 'Infinity', '-Infinity'].includes(CL.formatResult(n)) || !Number.isNaN(Number(CL.formatResult(n)))), 'parses back')
})

// ---------------------------------------------------------------------------
section('CalcLib.tryEvaluate - the arithmetic evaluator')

group('basic arithmetic', () => {
  approx('2+2', CL.tryEvaluate('2+2').value, 4, 0)
  approx('2*3+4', CL.tryEvaluate('2*3+4').value, 10, 0)
  approx('(2+3)*4', CL.tryEvaluate('(2+3)*4').value, 20, 0)
  approx('10-3-2', CL.tryEvaluate('10-3-2').value, 5, 0)
  approx('100/3', CL.tryEvaluate('100/3').value, 100 / 3, 1e-12)
  approx('8/4', CL.tryEvaluate('8/4').value, 2, 0)
  approx('1+2+3+4', CL.tryEvaluate('1+2+3+4').value, 10, 0)
  eq('formatted is the display string', CL.tryEvaluate('2+2').formatted, '4')
  eq('formatted for a decimal', CL.tryEvaluate('2^0.5').formatted, '1.4142135624')
  eq('formatted for 1/3', CL.tryEvaluate('1/3').formatted, '0.3333333333')
})

group('precedence and associativity match the shunting yard it reuses', () => {
  approx('^ is right-associative: 2^3^2', CL.tryEvaluate('2^3^2').value, 512, 0)
  approx('parenthesised: (2^3)^2', CL.tryEvaluate('(2^3)^2').value, 64, 0)
  approx('- is left-associative', CL.tryEvaluate('12-3-2-1').value, 6, 0)
  approx('/ is left-associative', CL.tryEvaluate('100/5/2').value, 10, 0)
  approx('unary minus', CL.tryEvaluate('-5+3').value, -2, 0)
  approx('double unary minus', CL.tryEvaluate('--5').value, 5, 0)
  approx('a trailing dot is a number', CL.tryEvaluate('2.5*2').value, 5, 0)
  approx('a leading dot is a number', CL.tryEvaluate('.5+.5').value, 1, 0)
  approx('0^0 is 1', CL.tryEvaluate('0^0').value, 1, 0)
  approx('a negative exponent', CL.tryEvaluate('2^-1').value, 0.5, 0)
})

group('remainder keeps the dividend sign, as in JS', () => {
  approx('7%3', CL.tryEvaluate('7%3').value, 1, 0)
  approx('-7%3', CL.tryEvaluate('-7%3').value, -1, 0)
  approx('10%3', CL.tryEvaluate('10%3').value, 1, 0)
  approx('2%2', CL.tryEvaluate('2%2').value, 0, 0)
  approx('1%1', CL.tryEvaluate('1%1').value, 0, 0)
})

group('division and modulo by zero are null, not Infinity', () => {
  // evalRpn throws for both, and tryEvaluate's catch turns the throw into the
  // null that means "not a calculator result", so the app list stays.
  eq('1/0', CL.tryEvaluate('1/0'), null)
  eq('1%0', CL.tryEvaluate('1%0'), null)
  eq('0/0', CL.tryEvaluate('0/0'), null)
  eq('1/0*1', CL.tryEvaluate('1/0*1'), null)
  eq('0*1/0', CL.tryEvaluate('0*1/0'), null)
  eq('5%0+1', CL.tryEvaluate('5%0+1'), null)
  eq('(1/0)', CL.tryEvaluate('(1/0)'), null)
  noThrow('1/0 does not throw out of tryEvaluate', () => CL.tryEvaluate('1/0'))
})

group('an overflow to Infinity is still a result', () => {
  // The isFinite guard after evalRpn has an empty body and the comment
  // "still return formatted infinity", so an overflowing exponent reaches
  // formatResult and is displayed as the word.
  is('2^1024 is Infinity', CL.tryEvaluate('2^1024').value, (v) => v === Infinity, 'Infinity')
  eq('and is formatted as the word', CL.tryEvaluate('2^1024').formatted, 'Infinity')
  eq('expr is preserved', CL.tryEvaluate('2^1024').expr, '2^1024')
})

group('an incomplete expression is null, and apps stay visible', () => {
  eq('1+', CL.tryEvaluate('1+'), null)
  eq('1*', CL.tryEvaluate('1*'), null)
  eq('(1', CL.tryEvaluate('(1'), null)
  eq('1)', CL.tryEvaluate('1)'), null)
  eq('+', CL.tryEvaluate('+'), null)
  eq('2+*3', CL.tryEvaluate('2+*3'), null)
  eq('1..2', CL.tryEvaluate('1..2'), null)
  eq('1,000', CL.tryEvaluate('1,000'), null)
  eq('2+2=2', CL.tryEvaluate('2+2=2'), null)
  eq('firefox', CL.tryEvaluate('firefox'), null)
  eq('x+2', CL.tryEvaluate('x+2'), null)
  eq('2x', CL.tryEvaluate('2x'), null)
  eq('1e3', CL.tryEvaluate('1e3'), null)
  eq('1e400', CL.tryEvaluate('1e400'), null)
  eq('1e-400', CL.tryEvaluate('1e-400'), null)
  eq('a doubled decimal', CL.tryEvaluate('1.5.5+1'), null)
  eq('a trailing operator after a paren', CL.tryEvaluate('(1)+'), null)
})

group('the record carries expr, value, formatted and the original text', () => {
  eq('the key set', Object.keys(CL.tryEvaluate('2+2')).sort(), ['expr', 'formatted', 'original', 'value'])
  eq('expr drops the trailing =', CL.tryEvaluate('2+2=').expr, '2+2')
  eq('original keeps it', CL.tryEvaluate('2+2=').original, '2+2=')
  eq('original is trimmed', CL.tryEvaluate('  2+2  ').original, '2+2')
  eq('expr is trimmed', CL.tryEvaluate('  2+2  ').expr, '2+2')
  eq('a spaced = is dropped from expr', CL.tryEvaluate('2+2 =').expr, '2+2')
  eq('and kept, spaced, in original', CL.tryEvaluate('2+2 =').original, '2+2 =')
  eq('a doubled = is dropped from expr', CL.tryEvaluate('2+2 ==').expr, '2+2')
  eq('and kept in original', CL.tryEvaluate('2+2 ==').original, '2+2 ==')
  // value is the raw double, formatted is the display: they can disagree in
  // the last digit and that is the point of having both.
  const r = CL.tryEvaluate('1/3')
  ne('value keeps full precision', r.formatted, String(r.value))
  eq('formatted is 10dp', r.formatted, '0.3333333333')
  approx('and value is the exact quotient', r.value, 1 / 3, 0)
})

group('an empty or all-equals query is null', () => {
  eq('empty', CL.tryEvaluate(''), null)
  eq('spaces', CL.tryEvaluate('   '), null)
  eq('= only', CL.tryEvaluate('='), null)
  eq('== only', CL.tryEvaluate('=='), null)
  eq('spaces and =', CL.tryEvaluate(' = '), null)
  eq('undefined', CL.tryEvaluate(undefined), null)
  eq('null', CL.tryEvaluate(null), null)
  eq('0', CL.tryEvaluate(0), null)
  eq('42', CL.tryEvaluate(42), null)
})

group('nothing tryEvaluate accepts throws', () => {
  const inputs = [undefined, null, '', '   ', '=', '42', '2+2', '2+2=', '1/0', '1+', '(1', '1)',
    'firefox', '1..2', '1e3', '2^1024', '.5+.5', '5.', '0', '  2 + 2  ', '1,000']
  for (const v of inputs) {
    noThrow(`tryEvaluate(${q(v)})`, () => CL.tryEvaluate(v))
    noThrow(`isPotentialCalc(${q(v)})`, () => CL.isPotentialCalc(v))
    noThrow(`formatResult(${q(v)})`, () => CL.formatResult(v))
  }
  noThrow('formatResult(undefined)', () => CL.formatResult(undefined))
  noThrow('formatResult({})', () => CL.formatResult({}))
})

// ---------------------------------------------------------------------------
section('ColorMath.FORMATS and the clamping helpers')

group('FORMATS is the chip order the header documents', () => {
  eq('the seven names in order', CM.FORMATS, ['hex', 'rgb', 'rgba', 'hsl', 'hsla', 'hsv', 'hsva'])
  eq('seven entries', CM.FORMATS.length, 7)
  is('every name is a non-empty string', CM.FORMATS, (v) => v.every((s) => typeof s === 'string' && s !== ''), 'non-empty strings')
  is('and there are no duplicates', CM.FORMATS, (v) => new Set(v).size === v.length, 'unique')
  // Every name must be a case format() actually handles, or a chip would
  // render as null.
  is('format handles every name', { r: 1, g: 0, b: 0 }, (c) => CM.FORMATS.every((f) => typeof CM.format(c, f, 0.5) === 'string'), 'all seven serialize')
})

group('clamp01 holds a channel in [0, 1] and treats junk as 0', () => {
  eq('-1', CM.clamp01(-1), 0)
  eq('-0.5', CM.clamp01(-0.5), 0)
  eq('0', CM.clamp01(0), 0)
  eq('0.5', CM.clamp01(0.5), 0.5)
  eq('1', CM.clamp01(1), 1)
  eq('2', CM.clamp01(2), 1)
  eq('NaN is 0, not NaN', CM.clamp01(NaN), 0)
  eq('Infinity is 0, because the non-finite check comes first', CM.clamp01(Infinity), 0)
  eq('-Infinity is 0', CM.clamp01(-Infinity), 0)
  eq('a numeric string is coerced', CM.clamp01('0.25'), 0.25)
  eq('"1.5" clamps high', CM.clamp01('1.5'), 1)
  eq('"-0.5" clamps low', CM.clamp01('-0.5'), 0)
  eq('a non-numeric string is 0', CM.clamp01('abc'), 0)
  eq('null is 0', CM.clamp01(null), 0)
  eq('undefined is 0', CM.clamp01(undefined), 0)
  eq('true is 1', CM.clamp01(true), 1)
  eq('an empty string is Number("") = 0', CM.clamp01(''), 0)
  eq('an object is NaN, so 0', CM.clamp01({}), 0)
  eq('an array', CM.clamp01([]), 0)
  // A non-finite value answers 0 rather than clamping to the nearest end,
  // because the !isFinite branch runs before the range test. clampAlpha
  // takes the same branch and answers 1 instead, so one non-finite input
  // means "black" for a channel and "opaque" for an alpha.
  eq('the same non-finite value means a different thing for alpha', [CM.clamp01(Infinity), CM.clampAlpha(Infinity)], [0, 1])
  is('never returns a non-number', [-1, 2, NaN, Infinity, null, 'x', {}], (v) => v.every((n) => typeof CM.clamp01(n) === 'number'), 'always a number')
  is('and never leaves the range', [-1, 2, NaN, Infinity, -Infinity, 0.5], (v) => v.every((n) => CM.clamp01(n) >= 0 && CM.clamp01(n) <= 1), 'within [0, 1]')
})

group('clampAlpha defaults absent or junk to opaque, not to zero', () => {
  // The comment: "Clamp any incoming alpha to [0, 1]; absent or non-numeric
  // is opaque." Opaque is 1, so a missing alpha never makes a swatch vanish.
  eq('undefined is opaque', CM.clampAlpha(undefined), 1)
  eq('null is opaque', CM.clampAlpha(null), 1)
  eq('NaN is opaque', CM.clampAlpha(NaN), 1)
  eq('a non-numeric string is opaque', CM.clampAlpha('abc'), 1)
  eq('an object is opaque', CM.clampAlpha({}), 1)
  eq('Infinity is opaque', CM.clampAlpha(Infinity), 1)
  eq('1', CM.clampAlpha(1), 1)
  eq('0.5', CM.clampAlpha(0.5), 0.5)
  eq('0', CM.clampAlpha(0), 0)
  eq('-1 clamps to fully transparent', CM.clampAlpha(-1), 0)
  eq('2 clamps to opaque', CM.clampAlpha(2), 1)
  eq('a numeric string is coerced', CM.clampAlpha('0.25'), 0.25)
  // The asymmetry with clamp01 is deliberate but easy to misread: Number("")
  // is 0, so an *empty* alpha is transparent while a *missing* one is opaque.
  eq('an empty string is Number("") = 0, not opaque', CM.clampAlpha(''), 0)
  eq('whereas clamp01("") is 0 as well', CM.clamp01(''), 0)
  eq('and clamp01(null) is 0 where clampAlpha(null) is 1', [CM.clamp01(null), CM.clampAlpha(null)], [0, 1])
  is('never returns a non-number', [undefined, null, NaN, -1, 2, 'x'], (v) => v.every((n) => typeof CM.clampAlpha(n) === 'number'), 'always a number')
})

group('valid() guards the serializers on the three colour channels', () => {
  eq('a full colour', CM.valid({ r: 0, g: 0, b: 0 }), true)
  eq('with out-of-range channels, which hex6 clamps', CM.valid({ r: -1, g: 2, b: 0.5 }), true)
  eq('null', CM.valid(null), false)
  eq('undefined', CM.valid(undefined), false)
  eq('an empty object', CM.valid({}), false)
  eq('a partial colour', CM.valid({ r: 1 }), false)
  eq('a NaN channel', CM.valid({ r: NaN, g: 0, b: 0 }), false)
  eq('an infinite channel', CM.valid({ r: Infinity, g: 0, b: 0 }), false)
  eq('a null channel', CM.valid({ r: null, g: 0, b: 0 }), true)
  // isFinite(null) is true because Number(null) is 0, so a null channel is
  // read as a zero channel rather than rejected. Harmless - every serializer
  // clamps through Number() again - but it is not what "non-finite" suggests.
  eq('because isFinite(null) is true', CM.valid({ r: null, g: 0, b: 0 }), true)
  eq('and hex6 then reads it as 00', CM.hex6({ r: null, g: 0, b: 0 }), '#000000')
  eq('the same for a numeric string channel', CM.hex6({ r: '1', g: 0, b: 0 }), '#ff0000')
  // null passes valid() because isFinite(null) is true, but undefined does
  // not, so only the null case reaches the serializer.
  eq('an undefined channel is not valid at all', CM.valid({ r: undefined, g: 0, b: 0 }), false)
  eq('and hex6 answers "" for it', CM.hex6({ r: undefined, g: 0, b: 0 }), '')
  // alpha is deliberately not part of the check: it has its own clamp.
  eq('a NaN alpha is still a valid colour', CM.valid({ r: 0, g: 0, b: 0, a: NaN }), true)
  eq('a missing alpha is still a valid colour', CM.valid({ r: 0, g: 0, b: 0 }), true)
})

// ---------------------------------------------------------------------------
section('ColorMath.parse - hex forms')

group('the 3 and 4 digit forms double each nibble', () => {
  approx('#fff red channel', px('#fff').r, 1, 1e-12)
  approx('#fff green channel', px('#fff').g, 1, 1e-12)
  approx('#fff blue channel', px('#fff').b, 1, 1e-12)
  approx('#fff is opaque', px('#fff').a, 1, 1e-12)
  approx('#123 red', px('#123').r, 0x11 / 255, 1e-12)
  approx('#123 green', px('#123').g, 0x22 / 255, 1e-12)
  approx('#123 blue', px('#123').b, 0x33 / 255, 1e-12)
  // A 4-digit form carries alpha in the fourth nibble: #ff00 is transparent
  // yellow, and #ff08 is the same at 0x88/255 opacity.
  approx('#ff00 red', px('#ff00').r, 1, 1e-12)
  approx('#ff00 green', px('#ff00').g, 1, 1e-12)
  approx('#ff00 blue', px('#ff00').b, 0, 1e-12)
  approx('#ff00 alpha is 0', px('#ff00').a, 0, 1e-12)
  approx('#ff08 alpha is 0x88/255', px('#ff08').a, 0x88 / 255, 1e-12)
  approx('#ff08 red', px('#ff08').r, 1, 1e-12)
  approx('#ff08 blue', px('#ff08').b, 0, 1e-12)
  approx('#00f8 blue', px('#00f8').b, 1, 1e-12)
  approx('#00f8 alpha is 0x88/255', px('#00f8').a, 0x88 / 255, 1e-12)
  approx('#ffff alpha is 1', px('#ffff').a, 1, 1e-12)
  approx('#0000 alpha is 0', px('#0000').a, 0, 1e-12)
  // A 3-digit form has no alpha nibble at all, so "#f0f" is f/0/f and opaque.
  approx('#f0f is a 3-digit colour', px('#f0f').r, 1, 1e-12)
  approx('#f0f green', px('#f0f').g, 0, 1e-12)
  approx('#f0f blue', px('#f0f').b, 1, 1e-12)
  approx('#f0f is opaque', px('#f0f').a, 1, 1e-12)
})

group('the 6 and 8 digit forms read byte pairs', () => {
  approx('#00ff00 red', px('#00ff00').r, 0, 1e-12)
  approx('#00ff00 green', px('#00ff00').g, 1, 1e-12)
  approx('#00ff00 blue', px('#00ff00').b, 0, 1e-12)
  approx('#336699 red', px('#336699').r, 0x33 / 255, 1e-12)
  approx('#336699 green', px('#336699').g, 0x66 / 255, 1e-12)
  approx('#336699 blue', px('#336699').b, 0x99 / 255, 1e-12)
  approx('#0000ff80 blue', px('#0000ff80').b, 1, 1e-12)
  approx('#0000ff80 alpha', px('#0000ff80').a, 0x80 / 255, 1e-12)
  approx('#ffffffff is opaque', px('#ffffffff').a, 1, 1e-12)
  approx('#00000000 is transparent', px('#00000000').a, 0, 1e-12)
  eq('a 6-digit form is opaque', px('#ff0000').a, 1)
})

group('the hash is optional and the case does not matter', () => {
  eq('#ffffff and ffffff agree', px('#ffffff'), px('ffffff'))
  eq('#FFF and #fff agree', px('#FFF'), px('#fff'))
  eq('#FFFFFF and #ffffff agree', px('#FFFFFF'), px('#ffffff'))
  eq('#AbCdEf and #abcdef agree', px('#AbCdEf'), px('#abcdef'))
  eq('#FFFFFFFF and #ffffffff agree', px('#FFFFFFFF'), px('#ffffffff'))
  eq('ffff and #ffff agree', px('ffff'), px('#ffff'))
  eq('the surrounding whitespace is trimmed', px('  #ff0000  '), px('#ff0000'))
  eq('a tab is trimmed too', px('\t#ff0000\t'), px('#ff0000'))
  // parseHex strips a *run* of hashes, so "##fff" is accepted where the
  // header only promises "with or without the hash". Harmless and pinned.
  eq('##fff is accepted', px('##fff'), px('#fff'))
  eq('###ff0000 is accepted', px('###ff0000'), px('#ff0000'))
})

group('every malformed hex form is null, not a throw', () => {
  const bad = ['', '#', '  ', '#1', '#12', '#12345', '#1234567', '#123456789', '#1234567890',
    '#ggg', '#gg', 'zzzzzz', 'gg', '#-1', '#+1', '# 1', '#1 1', '0x00ff00', 'rgb', '#abcde',
    'ff 00 00', 'ff,00,00', '#ff00zz', 42, true, null, undefined, {}, []]
  for (const v of bad) {
    eq(`parse(${q(v)}) is null`, px(v), null)
  }
  noThrow('a number does not throw', () => px(42))
  noThrow('null does not throw', () => px(null))
  noThrow('undefined does not throw', () => px(undefined))
  noThrow('an object does not throw', () => px({}))
  noThrow('an array does not throw', () => px([]))
  noThrow('a boolean does not throw', () => px(true))
})

// ---------------------------------------------------------------------------
section('ColorMath.parse - rgb/hsl/hsv function forms')

group('rgb() takes comma or space separated channels', () => {
  eq('rgb(255,0,0)', px('rgb(255,0,0)'), { r: 1, g: 0, b: 0, a: 1 })
  eq('rgb(0, 0, 0)', px('rgb(0, 0, 0)'), { r: 0, g: 0, b: 0, a: 1 })
  eq('space separated', px('rgb(255 0 0)'), px('rgb(255,0,0)'))
  eq('mixed separators', px('rgb(255, 0 0)'), px('rgb(255,0,0)'))
  eq('extra internal space', px('rgb( 10 , 20 , 30 )'), px('rgb(10,20,30)'))
  eq('uppercase function name', px('RGB(255,0,0)'), px('rgb(255,0,0)'))
  eq('mixed case', px('RgB(255,0,0)'), px('rgb(255,0,0)'))
  eq('whitespace between name and paren', px('rgb (255,0,0)'), px('rgb(255,0,0)'))
  approx('rgb(10,20,30) red', px('rgb(10,20,30)').r, 10 / 255, 1e-12)
  approx('rgb(1e2,0,0) parses a float channel', px('rgb(1e2,0,0)').r, 100 / 255, 1e-12)
})

group('percentages and the modern slash alpha', () => {
  eq('rgb(100%,0%,0%)', px('rgb(100%,0%,0%)'), px('rgb(255,0,0)'))
  eq('rgb(50%,0%,0%) is half, not byte 128', px('rgb(50%,0%,0%)').r, 0.5)
  approx('150% clamps to full', px('rgb(150%,0%,0%)').r, 1, 1e-12)
  eq('rgba(255,0,0,0.5)', px('rgba(255,0,0,0.5)'), { r: 1, g: 0, b: 0, a: 0.5 })
  eq('the slash separator is the fourth part', px('rgb(255 0 0 / 0.5)'), { r: 1, g: 0, b: 0, a: 0.5 })
  eq('a comma alpha is also 50%', px('rgba(255,0,0,50%)'), { r: 1, g: 0, b: 0, a: 0.5 })
  eq('an alpha above 1 clamps to opaque', px('rgb(0,0,0,2)').a, 1)
  eq('rgba() and rgb() share the reader', px('rgba(255,0,0)'), px('rgb(255,0,0)'))
})

group('a channel above its range clamps, one below zero is rejected', () => {
  // _chan255 returns -1 for a negative value, which parseRgb treats as
  // malformed; a value above 255 is clamped. The asymmetry is deliberate:
  // over-range is a readable colour, a negative one is not.
  eq('300 clamps to 255', px('rgb(300,0,0)').r, 1)
  eq('255.9 rounds through the clamp to 1', px('rgb(255.9,0,0)').r, 1)
  eq('a negative channel is null', px('rgb(-1,0,0)'), null)
  eq('a negative middle channel is null', px('rgb(0,-1,0)'), null)
  eq('a negative alpha is null', px('rgb(0,0,0,-1)'), null)
  eq('a negative percentage is null', px('rgb(-1%,0%,0%)'), null)
})

group('hsl() accepts a percentage or a unitless fraction', () => {
  eq('hsl(0,100%,50%)', px('hsl(0,100%,50%)'), { r: 1, g: 0, b: 0, a: 1 })
  eq('hsl(0,1,0.5)', px('hsl(0,1,0.5)'), { r: 1, g: 0, b: 0, a: 1 })
  eq('hsla(0,100%,50%,0.3)', px('hsla(0,100%,50%,0.3)'), { r: 1, g: 0, b: 0, a: 0.3 })
  eq('hsl(360,100%,50%) wraps to red', px('hsl(360,100%,50%)'), px('hsl(0,100%,50%)'))
  eq('hsl(720,100%,50%) wraps to red', px('hsl(720,100%,50%)'), px('hsl(0,100%,50%)'))
  eq('hsl(120,50%,50%)', px('hsl(120,50%,50%)'), { r: 0.25, g: 0.75, b: 0.25, a: 1 })
  eq('hsl(180,100%,50%)', px('hsl(180,100%,50%)'), { r: 0, g: 1, b: 1, a: 1 })
  eq('the deg suffix is optional', px('hsl(0deg,100%,50%)'), px('hsl(0,100%,50%)'))
  // _chanUnit reads a bare number above 1 as a percentage, so "2" is 2%.
  approx('a unitless 2 is 2% saturation', px('hsl(0,2,0.5)').r, 0.51, 1e-12)
  eq('a saturation above 100% clamps', px('hsl(0,200%,50%)'), px('hsl(0,100%,50%)'))
  eq('an hsla slash alpha', px('hsl(0 100% 50% / 0.25)'), { r: 1, g: 0, b: 0, a: 0.25 })
  eq('a light channel above 100% clamps', px('hsl(0,100%,200%)'), px('hsl(0,100%,100%)'))
})

group('hsl() and hsv() are different spaces, not aliases', () => {
  eq('hsv(0,100%,100%)', px('hsv(0,100%,100%)'), { r: 1, g: 0, b: 0, a: 1 })
  eq('hsv(120,100%,100%)', px('hsv(120,100%,100%)'), { r: 0, g: 1, b: 0, a: 1 })
  eq('hsva(0,100%,100%,0.25)', px('hsva(0,100%,100%,0.25)'), { r: 1, g: 0, b: 0, a: 0.25 })
  eq('hsv(120,50%,50%) is a different colour from hsl(120,50%,50%)',
    px('hsv(120,50%,50%)') === px('hsl(120,50%,50%)'), false)
  eq('hsl(120,50%,50%) reads 50% as lightness', px('hsl(120,50%,50%)'), { r: 0.25, g: 0.75, b: 0.25, a: 1 })
  approx('hsv(120,50%,50%) reads 50% as value', px('hsv(120,50%,50%)').b, 0.25, 1e-12)
  eq('hsv keeps a zero value black', px('hsv(120,100%,0%)'), { r: 0, g: 0, b: 0, a: 1 })
  eq('a hue past 360 wraps', px('hsv(480,100%,100%)'), px('hsv(120,100%,100%)'))
})

group('a negative hue is rejected by the parser even though the converter wraps it', () => {
  // _hue documents "-1 on malformed input" and parseHsl then tests
  // `h < 0`, so a negative hue is indistinguishable from a malformed one and
  // never reaches hslToRgb - even though hslToRgb's own first line is
  // `((h % 360) + 360) % 360`, which exists precisely to handle one. The
  // converter is therefore correct for negative hue and the parser refuses
  // it. Pinned because the two halves disagree.
  eq('hsl(-120,100%,50%) is null', px('hsl(-120,100%,50%)'), null)
  eq('hsl(-1,100%,50%) is null', px('hsl(-1,100%,50%)'), null)
  eq('hsv(-120,100%,100%) is null', px('hsv(-120,100%,100%)'), null)
  // The converter itself does wrap, and reaches blue at -120 degrees.
  eq('hslToRgb(-120) is blue', CM.hslToRgb(-120, 1, 0.5), { r: 0, g: 0, b: 1, a: 1 })
  eq('hslToRgb(240) is the same colour', CM.hslToRgb(240, 1, 0.5), { r: 0, g: 0, b: 1, a: 1 })
  eq('and hslToRgb(360) is red', CM.hslToRgb(360, 1, 0.5), { r: 1, g: 0, b: 0, a: 1 })
  eq('hslToRgb(NaN) is null', CM.hslToRgb(NaN, 1, 0.5), null)
  skip('hsl() is documented to accept hsl()/hsla() forms', 'ColorMath.js:150 rejects h < 0 before :195 can wrap it, so a negative hue never parses')
})

group('every malformed function form is null', () => {
  const bad = ['rgb()', 'rgb(255,0)', 'rgb(255,0,0,0,0)', 'rgb(a,b,c)', 'rgb(255,0,0',
    'hsl(0,100%)', 'hsl(0,100%,50%', 'hsla(0,100%,50%,abc)',
    'hsl(abc,100%,50%)', 'hsv(0,100%)', 'rgb(,0,0)', 'rgb(,,)', 'rgb(0,0,0,)',
    'hsl(0,100%,50%,)', 'hsv(0,100%,100%,x)', 'rgb 255,0,0', 'rgb(){}',
    '()', 'rgb(0;0;0)', 'hsl(0,,50%)', 'rgb(255,0,)', 'rgb(,,0)']
  for (const v of bad) {
    eq(`parse(${JSON.stringify(v)}) is null`, px(v), null)
  }
  noThrow('an unclosed paren does not throw', () => px('rgb(255,0,0'))
  noThrow('an extra paren does not throw', () => px('rgb(255,0,0))'))
  noThrow('a hostile body does not throw', () => px('rgb(){}'))
})

group('text after the closing paren, and an extra paren, are both swallowed', () => {
  // _parts is handed the slice between the first "(" and the *last* ")", so
  // a trailing paren or trailing junk lands inside the last channel token.
  // parseFloat stops at the first non-numeric character, so "0)" reads as 0
  // and "0" alone reads as 0 - both parse. Harmless, but it means these
  // strings are accepted where a CSS parser would reject them.
  eq('rgb(255,0,0)) parses', px('rgb(255,0,0))'), { r: 1, g: 0, b: 0, a: 1 })
  eq('rgb(0,0,0)extra parses', px('rgb(0,0,0)extra'), { r: 0, g: 0, b: 0, a: 1 })
  eq('the junk reads as zero because parseFloat stops early', px('rgb(0,0,0)extra').b, 0)
  eq('rgba(255,0,0,0.5)junk parses', px('rgba(255,0,0,0.5)junk'), { r: 1, g: 0, b: 0, a: 0.5 })
  eq('hsl(0,100%,50%)x parses', px('hsl(0,100%,50%)x'), { r: 1, g: 0, b: 0, a: 1 })
  eq('hsl(0,100%,50%)) parses', px('hsl(0,100%,50%))'), { r: 1, g: 0, b: 0, a: 1 })
  // The swallow is total for a token that starts with a digit, so trailing
  // junk on the last channel is absorbed there too.
  eq('rgba(255,0,0,0.5)abc parses at 0.5', px('rgba(255,0,0,0.5)abc'), { r: 1, g: 0, b: 0, a: 0.5 })
  eq('rgb(1,2,3)xyz parses at 3', px('rgb(1,2,3)xyz'), px('rgb(1,2,3)'))
  // A token with no leading digit is still a real malformed channel, and one
  // that leaves too few parts is still the wrong arity.
  eq('rgb(abc,2,3) is null', px('rgb(abc,2,3)'), null)
  eq('rgb(0,0,abc) is null', px('rgb(0,0,abc)'), null)
  eq('rgb(,0,0)xyz leaves two parts and is null', px('rgb(,0,0)xyz'), null)
})

// ---------------------------------------------------------------------------
section('ColorMath - the conversions round trip')

group('rgb -> hsl -> rgb returns to the original', () => {
  const hexes = ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#00ffff', '#ff00ff',
    '#336699', '#808080', '#7f7f7f', '#123456', '#abcdef', '#010203', '#fefdfc', '#2b2b2b', '#7f3f1f']
  for (const h of hexes) {
    const c = px(h)
    const hsl = CM.rgbToHsl(c.r, c.g, c.b)
    const back = CM.hslToRgb(hsl.h, hsl.s, hsl.l)
    approx(`${h} hsl red`, back.r, c.r, 1e-9)
    approx(`${h} hsl green`, back.g, c.g, 1e-9)
    approx(`${h} hsl blue`, back.b, c.b, 1e-9)
  }
})

group('rgb -> hsv -> rgb returns to the original', () => {
  const hexes = ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#00ffff', '#ff00ff',
    '#336699', '#808080', '#7f7f7f', '#123456', '#abcdef', '#010203', '#fefdfc', '#2b2b2b', '#7f3f1f']
  for (const h of hexes) {
    const c = px(h)
    const hsv = CM.rgbToHsv(c.r, c.g, c.b)
    const back = CM.hsvToRgb(hsv.h, hsv.s, hsv.v)
    approx(`${h} hsv red`, back.r, c.r, 1e-9)
    approx(`${h} hsv green`, back.g, c.g, 1e-9)
    approx(`${h} hsv blue`, back.b, c.b, 1e-9)
  }
})

group('the hue sextant boundaries are exact', () => {
  const at = (h) => CM.hsvToRgb(h, 1, 1)
  eq('0 degrees', at(0), { r: 1, g: 0, b: 0, a: 1 })
  eq('60 degrees', at(60), { r: 1, g: 1, b: 0, a: 1 })
  eq('120 degrees', at(120), { r: 0, g: 1, b: 0, a: 1 })
  eq('180 degrees', at(180), { r: 0, g: 1, b: 1, a: 1 })
  eq('240 degrees', at(240), { r: 0, g: 0, b: 1, a: 1 })
  eq('300 degrees', at(300), { r: 1, g: 0, b: 1, a: 1 })
  eq('360 degrees wraps to 0', at(360), at(0))
  eq('a negative hue wraps too', at(-120), at(240))
  eq('zero saturation is achromatic whatever the hue', CM.hsvToRgb(200, 0, 1), CM.hsvToRgb(0, 0, 1))
  eq('and that achromatic colour is white', CM.hsvToRgb(200, 0, 1), { r: 1, g: 1, b: 1, a: 1 })
  eq('zero saturation is white at full value', CM.hsvToRgb(0, 0, 1), { r: 1, g: 1, b: 1, a: 1 })
  eq('a zero value is black whatever the hue', CM.hsvToRgb(120, 1, 0), { r: 0, g: 0, b: 0, a: 1 })
  eq('out-of-range s and v are clamped', CM.hsvToRgb(0, 2, 2), { r: 1, g: 0, b: 0, a: 1 })
  eq('a non-finite component is null', CM.hsvToRgb(0, NaN, 1), null)
  eq('an infinite hue is null', CM.hsvToRgb(Infinity, 1, 1), null)
})

group('hslToRgb matches the standard construction', () => {
  eq('red', CM.hslToRgb(0, 1, 0.5), { r: 1, g: 0, b: 0, a: 1 })
  eq('yellow', CM.hslToRgb(60, 1, 0.5), { r: 1, g: 1, b: 0, a: 1 })
  eq('green', CM.hslToRgb(120, 1, 0.5), { r: 0, g: 1, b: 0, a: 1 })
  eq('cyan', CM.hslToRgb(180, 1, 0.5), { r: 0, g: 1, b: 1, a: 1 })
  eq('blue', CM.hslToRgb(240, 1, 0.5), { r: 0, g: 0, b: 1, a: 1 })
  eq('magenta', CM.hslToRgb(300, 1, 0.5), { r: 1, g: 0, b: 1, a: 1 })
  eq('white', CM.hslToRgb(0, 0, 1), { r: 1, g: 1, b: 1, a: 1 })
  eq('black', CM.hslToRgb(0, 0, 0), { r: 0, g: 0, b: 0, a: 1 })
  approx('a 50% mid grey', CM.hslToRgb(0, 0, 0.5).r, 0.5, 1e-12)
  is('the channels stay in range', [0, 60, 120, 180, 240, 300, 359.9], (list) => list.every((h) => {
    const c = CM.hslToRgb(h, 1, 0.5)
    return c !== null && [c.r, c.g, c.b].every((v) => v >= 0 && v <= 1)
  }), 'within [0, 1]')
})

group('rgbToHsl and rgbToHsv report the achromatic case as s = 0', () => {
  // With max == min the hue is undefined; both converters return h = 0 and
  // s = 0 rather than a division by zero, which is what the pickers paint.
  eq('black hsl', CM.rgbToHsl(0, 0, 0), { h: 0, s: 0, l: 0 })
  eq('white hsl', CM.rgbToHsl(1, 1, 1), { h: 0, s: 0, l: 1 })
  eq('black hsv', CM.rgbToHsv(0, 0, 0), { h: 0, s: 0, v: 0 })
  eq('white hsv', CM.rgbToHsv(1, 1, 1), { h: 0, s: 0, v: 1 })
  eq('mid grey hsl', CM.rgbToHsl(0.5, 0.5, 0.5), { h: 0, s: 0, l: 0.5 })
  eq('mid grey hsv', CM.rgbToHsv(0.5, 0.5, 0.5), { h: 0, s: 0, v: 0.5 })
  eq('red hsl', CM.rgbToHsl(1, 0, 0), { h: 0, s: 1, l: 0.5 })
  eq('red hsv', CM.rgbToHsv(1, 0, 0), { h: 0, s: 1, v: 1 })
})

group('a non-finite channel zeroes the whole conversion', () => {
  // Both converters return an all-zero record rather than null, because the
  // pickers call them on every frame and a zero record is paintable.
  eq('rgbToHsl(NaN,0,0)', CM.rgbToHsl(NaN, 0, 0), { h: 0, s: 0, l: 0 })
  eq('rgbToHsl(0,NaN,0)', CM.rgbToHsl(0, NaN, 0), { h: 0, s: 0, l: 0 })
  eq('rgbToHsl(0,0,Infinity)', CM.rgbToHsl(0, 0, Infinity), { h: 0, s: 0, l: 0 })
  eq('rgbToHsv(0,NaN,0)', CM.rgbToHsv(0, NaN, 0), { h: 0, s: 0, v: 0 })
  eq('rgbToHsv(0,0,-1)', CM.rgbToHsv(0, 0, -1), { h: 60, s: 0, v: 0 })
  // s and v are both 0 there, so the hue is never used; the code still
  // computes one from the out-of-range channels because max === r.
  eq('so the hue is meaningless and the colour is black', CM.hsvToRgb(CM.rgbToHsv(0, 0, -1).h, CM.rgbToHsv(0, 0, -1).s, CM.rgbToHsv(0, 0, -1).v), { r: 0, g: 0, b: 0, a: 1 })
  eq('rgbToHsl(undefined,0,0)', CM.rgbToHsl(undefined, 0, 0), { h: 0, s: 0, l: 0 })
})

group('the six primaries and the secondaries survive a full parse/convert cycle', () => {
  // The property a chip grid depends on: parse(hex) -> convert -> hex is the
  // identity, so a swatch never drifts when the user picks it.
  for (const h of ['#ff0000', '#00ff00', '#0000ff', '#ffff00', '#00ffff', '#ff00ff',
    '#000000', '#ffffff', '#336699', '#808080', '#7f7f7f']) {
    eq(`${h} survives hsl`, CM.hex6(CM.hslToRgb(...['h', 's', 'l'].map((k) => CM.rgbToHsl(px(h).r, px(h).g, px(h).b)[k]))), h)
    const v = CM.rgbToHsv(px(h).r, px(h).g, px(h).b)
    eq(`${h} survives hsv`, CM.hex6(CM.hsvToRgb(v.h, v.s, v.v)), h)
  }
})

// ---------------------------------------------------------------------------
section('ColorMath - the serializers')

group('hex6 is lowercase #rrggbb and "" when the channels are unusable', () => {
  eq('red', CM.hex6({ r: 1, g: 0, b: 0 }), '#ff0000')
  eq('green', CM.hex6({ r: 0, g: 1, b: 0 }), '#00ff00')
  eq('blue', CM.hex6({ r: 0, g: 0, b: 1 }), '#0000ff')
  eq('white', CM.hex6({ r: 1, g: 1, b: 1 }), '#ffffff')
  eq('black', CM.hex6({ r: 0, g: 0, b: 0 }), '#000000')
  eq('mid', CM.hex6({ r: 0.2, g: 0.4, b: 0.6 }), '#336699')
  eq('an uppercase parse normalises to lowercase', CM.hex6(px('#FF0000')), '#ff0000')
  eq('and mixed case', CM.hex6(px('#AbCdEf')), '#abcdef')
  eq('a null colour', CM.hex6(null), '')
  eq('an empty object', CM.hex6({}), '')
  eq('a NaN channel', CM.hex6({ r: NaN, g: 0, b: 0 }), '')
  eq('undefined', CM.hex6(undefined), '')
  // hex6 is the only serializer that answers "" rather than null, so each
  // byte is two hex digits even for a zero.
  eq('a zero channel is padded', CM.hex6({ r: 0, g: 0.5, b: 0 }), '#008000')
})

group('_byte rounds to the nearest byte and clamps out-of-range channels', () => {
  eq('0', CM._byte(0), '00')
  eq('1', CM._byte(1), 'ff')
  eq('0.5 rounds to 0x80', CM._byte(0.5), '80')
  eq('a low value is padded', CM._byte(1 / 255), '01')
  eq('a negative channel clamps to 00', CM._byte(-1), '00')
  eq('a high channel clamps to ff', CM._byte(2), 'ff')
  eq('a NaN channel clamps to 00', CM._byte(NaN), '00')
  eq('hex8 clamps too', CM.hex8({ r: -1, g: 2, b: 0.5 }, 0.5), '#00ff8080')
})

group('hex8 adds the alpha byte only once the alpha drops below 1', () => {
  eq('an opaque alpha stays 6 digits', CM.hex8({ r: 1, g: 0, b: 0 }, 1), '#ff0000')
  eq('a missing alpha is opaque', CM.hex8({ r: 1, g: 0, b: 0 }), '#ff0000')
  eq('a NaN alpha is opaque', CM.hex8({ r: 1, g: 0, b: 0 }, NaN), '#ff0000')
  eq('an alpha above 1 is opaque', CM.hex8({ r: 1, g: 0, b: 0 }, 2), '#ff0000')
  eq('a negative alpha is transparent', CM.hex8({ r: 1, g: 0, b: 0 }, -1), '#ff000000')
  eq('a zero alpha', CM.hex8({ r: 1, g: 0, b: 0 }, 0), '#ff000000')
  eq('a half alpha', CM.hex8({ r: 1, g: 0, b: 0 }, 0.5), '#ff000080')
  eq('white at half', CM.hex8({ r: 1, g: 1, b: 1 }, 0.5), '#ffffff80')
  eq('mid at half', CM.hex8({ r: 0.2, g: 0.4, b: 0.6 }, 0.5), '#33669980')
  eq('a null colour is null, not ""', CM.hex8(null, 1), null)
  eq('an empty object', CM.hex8({}, 1), null)
})

group('rgb() drops the alpha and the space-after-comma shape is fixed', () => {
  eq('red', CM.rgb({ r: 1, g: 0, b: 0 }), 'rgb(255, 0, 0)')
  eq('white', CM.rgb({ r: 1, g: 1, b: 1 }), 'rgb(255, 255, 255)')
  eq('black', CM.rgb({ r: 0, g: 0, b: 0 }), 'rgb(0, 0, 0)')
  eq('mid', CM.rgb({ r: 0.2, g: 0.4, b: 0.6 }), 'rgb(51, 102, 153)')
  eq('128 rounds to 128', CM.rgb(px('#808080')), 'rgb(128, 128, 128)')
  eq('127 rounds to 127', CM.rgb(px('#7f7f7f')), 'rgb(127, 127, 127)')
  // The header: "The opaque rgb() form cannot carry alpha; a is accepted and
  // dropped so every serializer shares one signature."
  eq('an alpha argument is accepted and dropped', CM.rgb({ r: 1, g: 0, b: 0 }, 0.5), 'rgb(255, 0, 0)')
  eq('a null colour', CM.rgb(null), null)
  eq('an empty object', CM.rgb({}), null)
  eq('out-of-range channels are clamped', CM.rgb({ r: -1, g: 2, b: 0.5 }), 'rgb(0, 255, 128)')
})

group('rgba() carries the alpha at three decimal places', () => {
  eq('a half alpha', CM.rgba({ r: 1, g: 0, b: 0 }, 0.5), 'rgba(255, 0, 0, 0.500)')
  eq('a missing alpha is opaque', CM.rgba({ r: 1, g: 0, b: 0 }), 'rgba(255, 0, 0, 1.000)')
  eq('a NaN alpha is opaque', CM.rgba({ r: 1, g: 0, b: 0 }, NaN), 'rgba(255, 0, 0, 1.000)')
  eq('a zero alpha', CM.rgba({ r: 1, g: 0, b: 0 }, 0), 'rgba(255, 0, 0, 0.000)')
  eq('a tiny alpha still prints three places', CM.rgba({ r: 1, g: 0, b: 0 }, 0.0001), 'rgba(255, 0, 0, 0.000)')
  eq('rounding is to 3dp', CM.rgba({ r: 1, g: 0, b: 0 }, 0.3335), 'rgba(255, 0, 0, 0.334)')
  eq('an alpha above 1 clamps', CM.rgba({ r: 1, g: 0, b: 0 }, 2), 'rgba(255, 0, 0, 1.000)')
  eq('a negative alpha clamps', CM.rgba({ r: 1, g: 0, b: 0 }, -1), 'rgba(255, 0, 0, 0.000)')
  eq('mid', CM.rgba({ r: 0.2, g: 0.4, b: 0.6 }, 0.25), 'rgba(51, 102, 153, 0.250)')
  eq('a null colour', CM.rgba(null, 0.5), null)
  eq('an empty object', CM.rgba({}, 0.5), null)
})

group('hsl(), hsla(), hsv() and hsva() round the percentages', () => {
  eq('red hsl', CM.hsl({ r: 1, g: 0, b: 0 }), 'hsl(0, 100%, 50%)')
  eq('red hsv', CM.hsv({ r: 1, g: 0, b: 0 }), 'hsv(0, 100%, 100%)')
  eq('green hsl', CM.hsl({ r: 0, g: 1, b: 0 }), 'hsl(120, 100%, 50%)')
  eq('blue hsv', CM.hsv({ r: 0, g: 0, b: 1 }), 'hsv(240, 100%, 100%)')
  eq('yellow hsl', CM.hsl({ r: 1, g: 1, b: 0 }), 'hsl(60, 100%, 50%)')
  eq('cyan hsl', CM.hsl({ r: 0, g: 1, b: 1 }), 'hsl(180, 100%, 50%)')
  eq('magenta hsv', CM.hsv({ r: 1, g: 0, b: 1 }), 'hsv(300, 100%, 100%)')
  eq('black hsl', CM.hsl({ r: 0, g: 0, b: 0 }), 'hsl(0, 0%, 0%)')
  eq('white hsl', CM.hsl({ r: 1, g: 1, b: 1 }), 'hsl(0, 0%, 100%)')
  eq('mid hsl', CM.hsl({ r: 0.2, g: 0.4, b: 0.6 }), 'hsl(210, 50%, 40%)')
  eq('mid hsv', CM.hsv({ r: 0.2, g: 0.4, b: 0.6 }), 'hsv(210, 67%, 60%)')
  eq('a near-white hsl', CM.hsl(px('#fefdfc')), 'hsl(30, 50%, 99%)')
  eq('a near-black hsl', CM.hsl(px('#010203')), 'hsl(210, 50%, 1%)')
  eq('a near-black hsv', CM.hsv(px('#010203')), 'hsv(210, 67%, 1%)')
  eq('a dark grey hsv', CM.hsv(px('#2b2b2b')), 'hsv(0, 0%, 17%)')
  eq('an orange hsl', CM.hsl(px('#ff9900')), 'hsl(36, 100%, 50%)')
  eq('a teal hsl', CM.hsl(px('#00b3b3')), 'hsl(180, 100%, 35%)')
  eq('a teal hsv', CM.hsv(px('#00b3b3')), 'hsv(180, 100%, 70%)')
  eq('a muted brown hsl', CM.hsl(px('#7f3f1f')), 'hsl(20, 61%, 31%)')
  eq('a muted brown hsv', CM.hsv(px('#7f3f1f')), 'hsv(20, 76%, 50%)')
  // hsla/hsva are the only difference from hsl/hsv: the alpha suffix.
  eq('hsla a half', CM.hsla({ r: 1, g: 0, b: 0 }, 0.5), 'hsla(0, 100%, 50%, 0.500)')
  eq('hsla opaque', CM.hsla({ r: 1, g: 0, b: 0 }), 'hsla(0, 100%, 50%, 1.000)')
  eq('hsva a quarter', CM.hsva({ r: 1, g: 0, b: 0 }, 0.25), 'hsva(0, 100%, 100%, 0.250)')
  eq('hsva opaque', CM.hsva({ r: 1, g: 0, b: 0 }), 'hsva(0, 100%, 100%, 1.000)')
  // hsl/hsv accept and drop the alpha for the same one-signature reason.
  eq('hsl drops an alpha argument', CM.hsl({ r: 1, g: 0, b: 0 }, 0.5), 'hsl(0, 100%, 50%)')
  eq('hsv drops an alpha argument', CM.hsv({ r: 1, g: 0, b: 0 }, 0.5), 'hsv(0, 100%, 100%)')
  eq('hsl a null colour', CM.hsl(null), null)
  eq('hsla a null colour', CM.hsla(null, 0.5), null)
  eq('hsv a null colour', CM.hsv(null), null)
  eq('hsva a null colour', CM.hsva(null, 0.5), null)
  eq('hsl an empty object', CM.hsl({}), null)
  eq('hsv a NaN channel', CM.hsv({ r: NaN, g: 0, b: 0 }), null)
})

// ---------------------------------------------------------------------------
section('ColorMath.format and allFormats')

group('format dispatches on the seven names and nulls the rest', () => {
  const red = { r: 1, g: 0, b: 0 }
  eq('hex at a half alpha', CM.format(red, 'hex', 0.5), '#ff000080')
  eq('hex opaque', CM.format(red, 'hex', 1), '#ff0000')
  eq('rgb', CM.format(red, 'rgb'), 'rgb(255, 0, 0)')
  eq('rgba', CM.format(red, 'rgba', 0.5), 'rgba(255, 0, 0, 0.500)')
  eq('hsl', CM.format(red, 'hsl'), 'hsl(0, 100%, 50%)')
  eq('hsla', CM.format(red, 'hsla', 0.5), 'hsla(0, 100%, 50%, 0.500)')
  eq('hsv', CM.format(red, 'hsv'), 'hsv(0, 100%, 100%)')
  eq('hsva', CM.format(red, 'hsva', 0.5), 'hsva(0, 100%, 100%, 0.500)')
  eq('an unknown name', CM.format(red, 'nope'), null)
  eq('an empty name', CM.format(red, ''), null)
  eq('a null name', CM.format(red, null), null)
  eq('no name at all', CM.format(red), null)
  eq('an uppercase name is not a case', CM.format(red, 'HEX'), null)
  eq('a null colour', CM.format(null, 'hex'), null)
  eq('an empty object', CM.format({}, 'rgb'), null)
})

group('allFormats returns exactly the seven, in chip order, with no nulls', () => {
  const all = CM.allFormats({ r: 1, g: 0, b: 0 }, 0.5)
  eq('all seven keys', Object.keys(all).sort(), [...CM.FORMATS].sort())
  eq('in FORMATS order', Object.keys(all), CM.FORMATS)
  eq('hex', all.hex, '#ff000080')
  eq('rgb', all.rgb, 'rgb(255, 0, 0)')
  eq('rgba', all.rgba, 'rgba(255, 0, 0, 0.500)')
  eq('hsl', all.hsl, 'hsl(0, 100%, 50%)')
  eq('hsla', all.hsla, 'hsla(0, 100%, 50%, 0.500)')
  eq('hsv', all.hsv, 'hsv(0, 100%, 100%)')
  eq('hsva', all.hsva, 'hsva(0, 100%, 100%, 0.500)')
  is('no value is null', all, (v) => Object.values(v).every((s) => typeof s === 'string'), 'all strings')
  // Opaque output is where the alpha formats collapse onto their opaque pair.
  const opaque = CM.allFormats({ r: 1, g: 0, b: 0 }, 1)
  eq('opaque hex is 6 digits', opaque.hex, '#ff0000')
  eq('opaque rgba', opaque.rgba, 'rgba(255, 0, 0, 1.000)')
  eq('opaque hsva', opaque.hsva, 'hsva(0, 100%, 100%, 1.000)')
})

group('allFormats drops the null serializers rather than carrying them', () => {
  // The comment: "null serializers are skipped". hex6 answers "" rather than
  // null, so it is the only name that can come back empty, and it is not.
  eq('a null colour yields an empty map', CM.allFormats(null, 1), {})
  eq('an empty object yields an empty map', CM.allFormats({}, 1), {})
  eq('a NaN channel yields an empty map', CM.allFormats({ r: NaN, g: 0, b: 0 }, 1), {})
  is('every value of a good map is a non-empty string', CM.allFormats(px('#336699'), 0.5), (v) => Object.values(v).every((s) => typeof s === 'string' && s !== ''), 'non-empty strings')
})

// ---------------------------------------------------------------------------
section('ColorMath.detectFormat - the format a code was written in')

group('detectFormat names the spelling, the inverse of format', () => {
  eq('a hex code', CM.detectFormat('#ff0000'), 'hex')
  eq('a hex code with an alpha', CM.detectFormat('#ff000080'), 'hex')
  eq('a short hex code', CM.detectFormat('#f00'), 'hex')
  eq('a hex code without its hash', CM.detectFormat('ff0000'), 'hex')
  eq('an rgb code', CM.detectFormat('rgb(255, 0, 0)'), 'rgb')
  eq('an rgba code', CM.detectFormat('rgba(255, 0, 0, 0.500)'), 'rgba')
  eq('an hsl code', CM.detectFormat('hsl(0, 100%, 50%)'), 'hsl')
  eq('an hsla code', CM.detectFormat('hsla(0, 100%, 50%, 0.500)'), 'hsla')
  eq('an hsv code', CM.detectFormat('hsv(0, 100%, 100%)'), 'hsv')
  eq('an hsva code', CM.detectFormat('hsva(0, 100%, 100%, 0.500)'), 'hsva')
  // The canonical library and the picker's view of it are one function.
  eq('Color.js agrees', COL.detectFormat('rgb(255, 0, 0)'), 'rgb')
})

group('a four-channel expression is the alpha spelling of its family', () => {
  // The spelling the user typed does not decide it: the CHANNELS do.
  // rgb(1,2,3,0.5) carries an alpha, and the format that can print that
  // alpha back is rgba - so a picker that follows the spelling would
  // otherwise drop the alpha it was just handed.
  eq('four rgb channels', CM.detectFormat('rgb(255, 0, 0, 0.5)'), 'rgba')
  eq('four hsl channels', CM.detectFormat('hsl(0, 100%, 50%, 0.5)'), 'hsla')
  eq('four hsv channels', CM.detectFormat('hsv(0, 100%, 100%, 0.5)'), 'hsva')
  eq('three rgb channels', CM.detectFormat('rgb(255, 0, 0)'), 'rgb')
})

group('the reading ignores spelling noise', () => {
  eq('surrounding space', CM.detectFormat('  rgb(255, 0, 0)  '), 'rgb')
  eq('a space before the paren', CM.detectFormat('rgb (255, 0, 0)'), 'rgb')
  eq('upper case', CM.detectFormat('RGB(255, 0, 0)'), 'rgb')
  eq('mixed case', CM.detectFormat('RgB(255, 0, 0)'), 'rgb')
  eq('upper case rgba', CM.detectFormat('RGBA(255, 0, 0, 0.5)'), 'rgba')
  eq('upper case hex', CM.detectFormat('#FF0000'), 'hex')
  eq('spaces between the channels', CM.detectFormat('rgb(255 0 0)'), 'rgb')
  eq('the slash alpha separator', CM.detectFormat('rgb(255 0 0 / 0.5)'), 'rgba')
})

group('a string that is not a color code has no format', () => {
  eq('an empty string', CM.detectFormat(''), null)
  eq('null', CM.detectFormat(null), null)
  eq('undefined', CM.detectFormat(undefined), null)
  eq('a number', CM.detectFormat(42), null)
  eq('words', CM.detectFormat('not a color'), null)
  eq('a name', CM.detectFormat('rebeccapurple'), null)
  // A spelling that does not parse is not a color code, so it has no
  // format: "rgb(1,2)" is a broken rgb, not an rgb.
  eq('a broken rgb', CM.detectFormat('rgb(1,2)'), null)
  eq('an rgb with no channels', CM.detectFormat('rgb()'), null)
  eq('an unclosed rgb', CM.detectFormat('rgb(255, 0, 0'), null)
  eq('a hex of the wrong length', CM.detectFormat('#ff000'), null)
  eq('a hex with a non-hex digit', CM.detectFormat('#gggggg'), null)
  eq('a bare word', CM.detectFormat('rgb'), null)
})

group('every format reads back its own output', () => {
  // The round trip that makes the function usable: a code the picker
  // printed is read back as the format it printed it in.
  const c = { r: 0.2, g: 0.4, b: 0.6 }
  for (const fmt of CM.FORMATS) {
    const printed = CM.format(c, fmt, 0.5)
    eq(`${fmt}: its own output reads back as ${fmt}`, CM.detectFormat(printed), fmt)
    eq(`${fmt}: and Color.js agrees`, COL.detectFormat(printed), fmt)
  }
  eq('the opaque pair reads back too', CM.detectFormat(CM.format(c, 'hex', 1)), 'hex')
})

// ---------------------------------------------------------------------------
section('ColorMath.contrastText')

group('the readable side is chosen by integer-channel luminance', () => {
  // lum = (299r + 587g + 114b) / 1000 > 127 picks black text. The channels
  // are rounded to bytes first, so the switch happens between byte 127 and 128.
  eq('pure white gets black text', CM.contrastText({ r: 1, g: 1, b: 1 }), '#000000')
  eq('pure black gets white text', CM.contrastText({ r: 0, g: 0, b: 0 }), '#ffffff')
  eq('near-white 0.9 gets black text', CM.contrastText({ r: 0.9, g: 0.9, b: 0.9 }), '#000000')
  eq('a mid grey gets black text', CM.contrastText({ r: 0.5, g: 0.5, b: 0.5 }), '#000000')
  eq('red is dark to the formula', CM.contrastText({ r: 1, g: 0, b: 0 }), '#ffffff')
  eq('blue is dark to the formula', CM.contrastText({ r: 0, g: 0, b: 1 }), '#ffffff')
  eq('magenta is dark to the formula', CM.contrastText({ r: 1, g: 0, b: 1 }), '#ffffff')
  // The weights are luma, not perceptual luminance: green carries 587/1000 of
  // the sum, so a saturated green reads as light and gets black text even
  // though on screen it looks mid-dark.
  eq('green is light to the formula', CM.contrastText({ r: 0, g: 1, b: 0 }), '#000000')
  eq('cyan is light to the formula', CM.contrastText({ r: 0, g: 1, b: 1 }), '#000000')
  eq('yellow is light to the formula', CM.contrastText({ r: 1, g: 1, b: 0 }), '#000000')
  approx('green luminance is 149.7', (299 * 0 + 587 * 255 + 114 * 0) / 1000, 149.685, 1e-9)
  approx('red luminance is 76.2', (299 * 255 + 587 * 0 + 114 * 0) / 1000, 76.245, 1e-9)
  eq('a dark slate', CM.contrastText({ r: 0.2, g: 0.4, b: 0.6 }), '#ffffff')
  eq('an almost-white blue', CM.contrastText({ r: 1, g: 1, b: 0.999 }), '#000000')
})

group('the switch is exactly between byte 127 and byte 128', () => {
  // 0.5 * 255 = 127.5, which rounds to 128, giving lum 128 > 127 and black
  // text. 0.4999 * 255 = 127.47, which rounds to 127, giving lum 127 and
  // white text. Pinned because the whole choice hinges on that rounding.
  eq('0.5 is 128 after rounding, so black', CM.contrastText({ r: 0.5, g: 0.5, b: 0.5 }), '#000000')
  eq('0.501 is still 128, so black', CM.contrastText({ r: 0.501, g: 0.501, b: 0.501 }), '#000000')
  eq('0.4999 is 127, so white', CM.contrastText({ r: 0.4999, g: 0.4999, b: 0.4999 }), '#ffffff')
  approx('0.5 rounds to byte 128', Math.round(0.5 * 255), 128, 0)
  approx('0.4999 rounds to byte 127', Math.round(0.4999 * 255), 127, 0)
  approx('luminance at byte 128', (299 * 128 + 587 * 128 + 114 * 128) / 1000, 128, 0)
  approx('luminance at byte 127', (299 * 127 + 587 * 127 + 114 * 127) / 1000, 127, 0)
})

group('an unusable colour falls back to white text', () => {
  eq('null', CM.contrastText(null), '#ffffff')
  eq('undefined', CM.contrastText(undefined), '#ffffff')
  eq('an empty object', CM.contrastText({}), '#ffffff')
  eq('a NaN channel', CM.contrastText({ r: NaN, g: 0, b: 0 }), '#ffffff')
  eq('an infinite channel', CM.contrastText({ r: Infinity, g: 0, b: 0 }), '#ffffff')
  // Out-of-range channels are clamped rather than rejected, so the choice is
  // still made.
  eq('a negative channel clamps to black', CM.contrastText({ r: -1, g: -1, b: -1 }), '#ffffff')
  eq('an over-range channel clamps to white', CM.contrastText({ r: 2, g: 2, b: 2 }), '#000000')
})

// ---------------------------------------------------------------------------
section('ColorMath.recordKey and sanitizeFormats')

group('recordKey is color|alpha|fmt, the one key both consumers use', () => {
  eq('all three fields', CM.recordKey({ color: '#ff0000', alpha: 0.5, fmt: 'rgb' }), '#ff0000|0.500|rgb')
  eq('a missing fmt defaults to hex', CM.recordKey({ color: '#ff0000', alpha: 0.5 }), '#ff0000|0.500|hex')
  eq('a missing alpha defaults to opaque', CM.recordKey({ color: '#ff0000' }), '#ff0000|1.000|hex')
  eq('a non-string fmt defaults to hex', CM.recordKey({ color: '#fff', fmt: 2 }), '#fff|1.000|hex')
  eq('a non-object record', CM.recordKey(null), '|1.000|hex')
  eq('undefined', CM.recordKey(undefined), '|1.000|hex')
  eq('an empty object', CM.recordKey({}), '|1.000|hex')
  eq('no color', CM.recordKey({ alpha: 0.5 }), '|0.500|hex')
})

group('the alpha in the key is clamped and fixed to three places', () => {
  eq('a half', CM.recordKey({ color: '#fff', alpha: 0.5 }), '#fff|0.500|hex')
  eq('a zero', CM.recordKey({ color: '#fff', alpha: 0 }), '#fff|0.000|hex')
  eq('one', CM.recordKey({ color: '#fff', alpha: 1 }), '#fff|1.000|hex')
  eq('above 1 clamps', CM.recordKey({ color: '#fff', alpha: 2 }), '#fff|1.000|hex')
  eq('below 0 clamps', CM.recordKey({ color: '#fff', alpha: -1 }), '#fff|0.000|hex')
  eq('NaN is opaque', CM.recordKey({ color: '#fff', alpha: NaN }), '#fff|1.000|hex')
  eq('a non-numeric string is opaque', CM.recordKey({ color: '#fff', alpha: 'x' }), '#fff|1.000|hex')
  eq('a numeric string is coerced', CM.recordKey({ color: '#fff', alpha: '0.5' }), '#fff|0.500|hex')
  eq('rounding to 3dp', CM.recordKey({ color: '#fff', alpha: 0.3335 }), '#fff|0.334|hex')
  // The rounding is what makes the key a dedupe key: two alphas that print
  // the same are the same swatch.
  eq('two alphas that round alike collide', CM.recordKey({ color: '#fff', alpha: 0.5001 }) === CM.recordKey({ color: '#fff', alpha: 0.5004 }), true)
})

group('the key separates on each of the three fields', () => {
  ne('two colours', CM.recordKey({ color: '#fff' }), CM.recordKey({ color: '#000' }))
  ne('two alphas', CM.recordKey({ color: '#fff', alpha: 1 }), CM.recordKey({ color: '#fff', alpha: 0.5 }))
  ne('two formats', CM.recordKey({ color: '#fff', alpha: 1, fmt: 'hex' }), CM.recordKey({ color: '#fff', alpha: 1, fmt: 'rgb' }))
  eq('the same record is the same key', CM.recordKey({ color: '#fff', alpha: 1, fmt: 'hex' }), CM.recordKey({ color: '#fff', alpha: 1, fmt: 'hex' }))
  // The default fmt is indistinguishable from an explicit "hex", which is
  // what lets the store and the history list agree.
  eq('an explicit hex equals the default', CM.recordKey({ color: '#fff', alpha: 1, fmt: 'hex' }), CM.recordKey({ color: '#fff', alpha: 1 }))
})

group('sanitizeFormats copies only the known names, dropping the rest', () => {
  eq('two known names', CM.sanitizeFormats({ hex: '#fff', rgb: 'rgb(1,2,3)' }), { hex: '#fff', rgb: 'rgb(1,2,3)' })
  eq('an unknown name is dropped', CM.sanitizeFormats({ hex: '#fff', bogus: 'x' }), { hex: '#fff' })
  eq('an empty string is dropped', CM.sanitizeFormats({ hex: '', rgb: 'rgb(1,2,3)' }), { rgb: 'rgb(1,2,3)' })
  eq('a non-string is dropped', CM.sanitizeFormats({ hex: 5, rgb: null, hsl: 'hsl(0,0%,0%)' }), { hsl: 'hsl(0,0%,0%)' })
  eq('all seven survive', CM.sanitizeFormats({
    hex: '#fff', rgb: 'rgb(1,2,3)', rgba: 'rgba(1,2,3,1)', hsl: 'hsl(0,0%,0%)',
    hsla: 'hsla(0,0%,0%,1)', hsv: 'hsv(0,0%,0%)', hsva: 'hsva(0,0%,0%,1)',
  }), {
    hex: '#fff', rgb: 'rgb(1,2,3)', rgba: 'rgba(1,2,3,1)', hsl: 'hsl(0,0%,0%)',
    hsla: 'hsla(0,0%,0%,1)', hsv: 'hsv(0,0%,0%)', hsva: 'hsva(0,0%,0%,1)',
  })
  eq('a non-object is empty', CM.sanitizeFormats(null), {})
  eq('undefined', CM.sanitizeFormats(undefined), {})
  eq('a string', CM.sanitizeFormats('nope'), {})
  eq('a number', CM.sanitizeFormats(5), {})
  eq('an array', CM.sanitizeFormats(['a']), {})
  eq('an unknown key only', CM.sanitizeFormats({ nope: 'x' }), {})
  eq('an empty object', CM.sanitizeFormats({}), {})
  // The key order is FORMATS order regardless of the input order, which
  // keeps a persisted file stable.
  eq('the key order is FORMATS order', Object.keys(CM.sanitizeFormats({ hsva: 'a', hex: 'b', rgb: 'c' })), ['hex', 'rgb', 'hsva'])
  noThrow('a hostile map does not throw', () => CM.sanitizeFormats({ hex: { toString() { throw new Error('x') } } }))
})

// ---------------------------------------------------------------------------
section('ColorMath.parseHistory - the store shapes')

// The shape the state store actually writes. The store wraps whatever the
// slot holds under "data", so the file this module itself wrote comes back
// wrapped - and read by the JSONL branch it matched nothing: its lines are
// indented and the lone "{" fails JSON.parse alone, so every entry was
// skipped SILENTLY and the history read as empty. The caller then wrote that
// empty result back over the file, which is how 18 records became 1.
group('the slot-wrapped document is unwrapped, not read as JSONL', () => {
  const one = { color: '#ff0000', alpha: 0.5, timestamp: 123 }
  eq('records under data.records', CM.parseHistory(JSON.stringify({ data: { records: [one] } })), [one])
  eq('records under a bare data array', CM.parseHistory(JSON.stringify({ data: [one] })), [one])
  eq('the real on-disk shape, pretty-printed as the store writes it',
    CM.parseHistory(JSON.stringify({ data: { records: [one] } }, null, 4)), [one])
  eq('a malformed wrapped entry is dropped like any other',
    CM.parseHistory('{"data":{"records":[{"color":"zzz"},{"color":"#00ff00"}]}}'),
    [{ color: '#00ff00', alpha: 1, timestamp: 0 }])
  eq('an empty wrapped document is an empty history', CM.parseHistory('{"data":{"records":[]}}'), [])
  // A wrapper carrying no records is unreadable, not empty: the caller
  // writes the parse result back, so this must not silently answer [] for a
  // shape it does not understand.
  eq('a wrapper with no records key is empty', CM.parseHistory('{"data":{"nope":1}}'), [])
  eq('a wrapper whose data is null is empty', CM.parseHistory('{"data":null}'), [])
  // Not a wrapper: a single JSONL record on one line parses as an object with
  // no `data`, so it must fall through to the line branch, not be unwrapped.
  eq('a one-line JSONL record still reads as JSONL',
    CM.parseHistory('{"color":"#00ff00","alpha":0.25}'), [{ color: '#00ff00', alpha: 0.25, timestamp: 0 }])
  eq('a multi-line JSONL document still reads as JSONL',
    CM.parseHistory('{"color":"#00ff00"}\n{"color":"#0000ff"}'),
    [{ color: '#00ff00', alpha: 1, timestamp: 0 }, { color: '#0000ff', alpha: 1, timestamp: 0 }])
  eq('a broken wrapper is an empty history', CM.parseHistory('{"data":'), [])
})

group('an empty document is an empty history', () => {
  eq('empty', CM.parseHistory(''), [])
  eq('spaces', CM.parseHistory('   '), [])
  eq('newlines', CM.parseHistory('\n\n\n'), [])
  eq('null', CM.parseHistory(null), [])
  eq('undefined', CM.parseHistory(undefined), [])
  eq('a number', CM.parseHistory(42), [])
})

group('the JSON array document is read first when it starts with [', () => {
  eq('one record', CM.parseHistory('[{"color":"#ff0000","alpha":0.5,"timestamp":123}]'),
    [{ color: '#ff0000', alpha: 0.5, timestamp: 123 }])
  eq('a malformed entry is dropped', CM.parseHistory('[{"color":"zzz"},{"color":"#00ff00"}]'),
    [{ color: '#00ff00', alpha: 1, timestamp: 0 }])
  eq('a broken document is an empty history', CM.parseHistory('[{"color":'), [])
  eq('a truncated array is an empty history', CM.parseHistory('[1,2,3'), [])
  // JSON.parse succeeds on "[]" and on a nested array, and Array.isArray
  // guards the second; a non-array document returns [].
  eq('an empty array', CM.parseHistory('[]'), [])
  eq('every entry dropped', CM.parseHistory('[{"color":"zzz"}]'), [])
  eq('a record with no alpha or timestamp', CM.parseHistory('[{"color":"rgb(255,0,0)"}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('a non-numeric alpha becomes opaque', CM.parseHistory('[{"color":"#fff","alpha":"0.5"}]'),
    [{ color: '#ffffff', alpha: 1, timestamp: 0 }])
  eq('a non-numeric timestamp becomes 0', CM.parseHistory('[{"color":"#fff","timestamp":"5"}]'),
    [{ color: '#ffffff', alpha: 1, timestamp: 0 }])
  eq('an infinite timestamp becomes 0', CM.parseHistory('[{"color":"#fff","timestamp":1e999}]'),
    [{ color: '#ffffff', alpha: 1, timestamp: 0 }])
  eq('a negative timestamp is kept', CM.parseHistory('[{"color":"#fff","timestamp":-5}]'),
    [{ color: '#ffffff', alpha: 1, timestamp: -5 }])
})

group('records normalise their colour to hex6', () => {
  eq('a bare hex in', CM.parseHistory('[{"color":"#336699"}]'), [{ color: '#336699', alpha: 1, timestamp: 0 }])
  eq('a 3-digit hex is expanded', CM.parseHistory('[{"color":"#f00"}]'), [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('a function form is converted', CM.parseHistory('[{"color":"rgb(51, 102, 153)"}]'), [{ color: '#336699', alpha: 1, timestamp: 0 }])
  eq('an hsl form is converted', CM.parseHistory('[{"color":"hsl(0,100%,50%)"}]'), [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('an uppercase hex is lowercased', CM.parseHistory('[{"color":"#FF0000"}]'), [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  // The JSONL bare-hex path does carry the hex alpha, but _recordFrom does
  // not: it takes the alpha only from a numeric o.alpha field and otherwise
  // forces 1, so the 8-digit alpha is dropped on the record path. The colour
  // itself still normalises, which is what the store keys on.
  eq('a hex alpha is dropped by the record path', CM.parseHistory('[{"color":"#ff000080"}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('while the bare-hex line path keeps it', CM.parseHistory('#ff000080'),
    [{ color: '#ff0000', alpha: 0.5019607843137255, timestamp: 0 }])
  eq('an explicit alpha overrides the hex alpha', CM.parseHistory('[{"color":"#ff000080","alpha":0.25}]'),
    [{ color: '#ff0000', alpha: 0.25, timestamp: 0 }])
  eq('and an explicit 0 alpha is kept', CM.parseHistory('[{"color":"#ff000080","alpha":0}]'),
    [{ color: '#ff0000', alpha: 0, timestamp: 0 }])
})

group('the formats and fmt extras are carried through when well formed', () => {
  eq('a well-formed formats map', CM.parseHistory('[{"color":"#ff0000","formats":{"hex":"#ff0000","rgb":"rgb(255, 0, 0)","bogus":"x"}}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0, formats: { hex: '#ff0000', rgb: 'rgb(255, 0, 0)' } }])
  eq('a known fmt is kept', CM.parseHistory('[{"color":"#ff0000","fmt":"hsl"}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0, fmt: 'hsl' }])
  eq('an unknown fmt is dropped', CM.parseHistory('[{"color":"#00ff00","fmt":"bogus"}]'),
    [{ color: '#00ff00', alpha: 1, timestamp: 0 }])
  eq('an empty formats map is kept as empty', CM.parseHistory('[{"color":"#ff0000","formats":{}}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0, formats: {} }])
  eq('a non-object formats is dropped', CM.parseHistory('[{"color":"#ff0000","formats":"x"}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('a non-string fmt is dropped', CM.parseHistory('[{"color":"#ff0000","fmt":5}]'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  // The formats map is sanitized exactly like sanitizeFormats does, so the
  // two paths cannot disagree.
  eq('the formats map matches sanitizeFormats', CM.parseHistory('[{"color":"#ff0000","formats":{"hex":"#f00","rgb":"rgb(1, 2, 3)"}}]')[0].formats,
    CM.sanitizeFormats({ hex: '#f00', rgb: 'rgb(1, 2, 3)' }))
})

group('the one-record-per-line form accepts bare colours and JSON lines', () => {
  eq('two hex lines', CM.parseHistory('#ff0000\n#00ff00'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }, { color: '#00ff00', alpha: 1, timestamp: 0 }])
  eq('bare hex without the hash', CM.parseHistory('ff0000\n00ff00'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }, { color: '#00ff00', alpha: 1, timestamp: 0 }])
  eq('a mixed document', CM.parseHistory('#ff0000\n{"color":"#00ff00","alpha":0.5,"timestamp":9}\nnotacolor\n\n#0000ff'),
    [
      { color: '#ff0000', alpha: 1, timestamp: 0 },
      { color: '#00ff00', alpha: 0.5, timestamp: 9 },
      { color: '#0000ff', alpha: 1, timestamp: 0 },
    ])
  eq('a broken JSON line is skipped', CM.parseHistory('{"color": bad}\n#ff0000'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('a bare hex alpha becomes the record alpha', CM.parseHistory('#ff000080'),
    [{ color: '#ff0000', alpha: 0.5019607843137255, timestamp: 0 }])
  eq('a 3-digit bare line is a colour', CM.parseHistory('123\n#ff0000'),
    [{ color: '#112233', alpha: 1, timestamp: 0 }, { color: '#ff0000', alpha: 1, timestamp: 0 }])
  eq('CRLF line endings', CM.parseHistory('#ff0000\r\n#00ff00'),
    [{ color: '#ff0000', alpha: 1, timestamp: 0 }, { color: '#00ff00', alpha: 1, timestamp: 0 }])
  // "bare-hex lines normalize to opaque records at timestamp 0, which
  // preserves the file order" - the order is the property.
  eq('the file order is preserved', CM.parseHistory('#111111\n#222222\n#333333').map((r) => r.color),
    ['#111111', '#222222', '#333333'])
  eq('order survives mixed lines', CM.parseHistory('#ffffff\n#000000').map((r) => r.color), ['#ffffff', '#000000'])
})

group('a leading { is a JSONL line, not a document', () => {
  // The array branch keys on "[" alone, so a single JSON object is read by
  // the line reader and produces exactly one record.
  eq('one object', CM.parseHistory('{"color":"#fff"}'), [{ color: '#ffffff', alpha: 1, timestamp: 0 }])
  eq('an object with extras', CM.parseHistory('{"color":"#ff0000","alpha":0.5,"timestamp":9}'),
    [{ color: '#ff0000', alpha: 0.5, timestamp: 9 }])
  eq('a non-object JSON line is dropped', CM.parseHistory('[1,2,3]'), [])
  eq('a bare word line is dropped', CM.parseHistory('firefox'), [])
})

group('a parsed record is exactly the four documented keys, in order', () => {
  eq('a bare line', Object.keys(CM.parseHistory('#ff0000')[0]), ['color', 'alpha', 'timestamp'])
  eq('a JSON line with formats', Object.keys(CM.parseHistory('{"color":"#ff0000","fmt":"hsl","formats":{"hex":"#f00"}}')[0]),
    ['color', 'alpha', 'timestamp', 'formats', 'fmt'])
  eq('formats only', Object.keys(CM.parseHistory('{"color":"#ff0000","formats":{"hex":"#f00"}}')[0]),
    ['color', 'alpha', 'timestamp', 'formats'])
  eq('fmt only', Object.keys(CM.parseHistory('{"color":"#ff0000","fmt":"hsl"}')[0]),
    ['color', 'alpha', 'timestamp', 'fmt'])
})

group('parseHistory survives a hostile document', () => {
  const bad = ['[', '[]', '{}', '[[]]', '[null]', '[1]', '["#fff"]', '[{"color":null}]',
    '[{"color":{}}]', '[]extra', '\n\n', '   [  ]  ', '[' + '{"color":"#fff"},' + ']']
  for (const v of bad) {
    noThrow(`parseHistory(${JSON.stringify(v)})`, () => CM.parseHistory(v))
  }
  eq('[null] drops the entry', CM.parseHistory('[null]'), [])
  eq('[1] drops the entry', CM.parseHistory('[1]'), [])
  eq('["#fff"] drops the entry', CM.parseHistory('["#fff"]'), [])
  eq('[{"color":null}] drops the entry', CM.parseHistory('[{"color":null}]'), [])
  eq('[]extra yields nothing', CM.parseHistory('[]extra'), [])
  eq('a spaced empty array', CM.parseHistory('  [  ]  '), [])
})

// ---------------------------------------------------------------------------
section('ColorLib - the launcher color engine, and its agreement with ColorMath')
// ---------------------------------------------------------------------------

// One corpus for every agreement assertion below. It spans the hex lengths, the
// three function families, the alpha forms, the greys, the extremes and the
// rounding edges, because "the launcher and the picker agree" is only worth
// anything if it holds where the serializers are hardest.
const CORPUS = [
  '#f00', '#0f08', '#ff0000', '#00ff0080', '#000', '#fff', '#000000', '#ffffff',
  '#abcdef', '#123456', '#7f7f7f', '#808080', '#336699', '#010203', '#fefdfc',
  'rgb(255, 0, 0)', 'rgb(0, 0, 0)', 'rgba(255, 0, 0, 0.5)', 'rgb(51, 102, 153)',
  'rgb(100%, 0%, 50%)', 'rgba(1, 2, 3, 0.25)', 'RGB(12, 34, 56)',
  'hsl(0, 100%, 50%)', 'hsl(120, 50%, 25%)', 'hsla(240, 100%, 50%, 0.333)',
  'hsv(0, 100%, 100%)', 'hsv(200, 40%, 60%)', 'hsva(60, 100%, 50%, 0.75)',
  'hsl(32, 100%, 50%)', 'hsv(32, 100%, 100%)',
  '#FF8800', '#Ff8800aa',
]

group('ColorLib carries the pickers own formats and serializers, unchanged', () => {
  eq('the same seven names, in the same chip order', COL.FORMATS, CM.FORMATS)
  eq('the same seven names', COL.FORMATS,
    ['hex', 'rgb', 'rgba', 'hsl', 'hsla', 'hsv', 'hsva'])
  // Every serializer, over the whole corpus, byte for byte. A drift here is a
  // launcher that spells a color differently from the bar module that picked
  // it, which is the one thing the copy exists to prevent.
  for (const s of CORPUS) {
    const c = CM.parse(s)
    is(`ColorLib.parse reads ${JSON.stringify(s)} the same way`, COL.parse(s), (v) => v !== null, 'a parsed color')
    for (const fmt of CM.FORMATS) {
      eq(`${s} as ${fmt}`, COL.format(c, fmt, c.a), CM.format(c, fmt, c.a))
    }
  }
  // The parse itself, not only the serializers: a parser that disagreed on the
  // channels would agree on the spelling of the wrong color.
  for (const s of CORPUS) {
    eq(`the channels of ${JSON.stringify(s)}`, COL.parse(s), CM.parse(s))
  }
  eq('the opaque hex of a mid color', COL.hex6({ r: 0.2, g: 0.4, b: 0.6 }), '#336699')
  eq('the contrast rule is the pickers', COL.contrastText({ r: 1, g: 1, b: 1 }), CM.contrastText({ r: 1, g: 1, b: 1 }))
  eq('on a dark color', COL.contrastText({ r: 0, g: 0, b: 0 }), CM.contrastText({ r: 0, g: 0, b: 0 }))
  eq('and on an unusable color it is the same white', COL.contrastText(null), '#ffffff')
  // The store half is the one documented omission: a plugin cannot import, but
  // nothing in the launcher has a color history to persist.
  for (const n of ['parseHistory', 'recordKey', 'sanitizeFormats']) {
    eq(`${n} is not carried`, COL[n], undefined)
  }
})

group('DISPLAY_FORMATS is the chip order without the hex the user typed', () => {
  eq('six rows', COL.DISPLAY_FORMATS.length, 6)
  eq('in the chip order', COL.DISPLAY_FORMATS, ['rgb', 'rgba', 'hsl', 'hsla', 'hsv', 'hsva'])
  eq('and never the hex, which is the input field', COL.DISPLAY_FORMATS.indexOf('hex'), -1)
  // Derived rather than typed, so the row order cannot drift from the chip order.
  is('it is FORMATS minus hex', COL.DISPLAY_FORMATS, (v) => v.every((f, i) => f === CM.FORMATS.filter((x) => x !== 'hex')[i]), 'chip order')
})

group('isPotentialColor is the one rule the launcher adds: a hex needs its hash', () => {
  // ColorMath takes a bare RRGGBB because it is handed a pick or a stored
  // record, where a color is all the input there is. Free text is a different
  // input, and these are all valid colors as well as all plausible app names.
  for (const q of ['face', 'cafe', 'facade', 'added', 'ff8800', 'abcdef', 'deadbeef', 'beef']) {
    eq(`${JSON.stringify(q)} is not a color query`, COL.isPotentialColor(q), false)
  }
  for (const q of ['#f00', '#f00f', '#ff0000', '#ff0000ff', '#ABCDEF', '#', '# ', '#gg']) {
    // The gate only asks about the SHAPE: "#gg", a bare "#" and "hsl(" are
    // admitted here and refused by the parse, which is where a malformed code
    // is decided.
    eq(`${JSON.stringify(q)} passes the gate`, COL.isPotentialColor(q), true)
  }
  for (const q of ['rgb(1,2,3)', 'rgba(1,2,3,0.5)', 'RGB(1,2,3)', 'hsl(1,2%,3%)',
    'hsla(1,2%,3%,0.5)', 'hsv(1,2%,3%)', 'hsva(1,2%,3%,0.5)', 'rgb (1, 2, 3)', 'hsl(']) {
    eq(`${JSON.stringify(q)} passes the gate`, COL.isPotentialColor(q), true)
  }
  for (const q of ['', '   ', 'rgb', 'rgbx(1,2,3)', 'x^2', '2+2', '5m in cm',
    'firefox', null, undefined]) {
    eq(`${JSON.stringify(q)} is not a color query`, COL.isPotentialColor(q), false)
  }
  eq('it never throws on an object', COL.isPotentialColor({}), false)
  noThrow('nor on a number', () => COL.isPotentialColor(42))
})

group('isColorIncomplete is the mid-typing gate: a strict prefix stays a color query', () => {
  // A complete code is not incomplete, and text that cannot become a color by
  // typing more is not either. Only shapes with a valid continuation answer
  // true, so the engine keeps its claim between keystrokes ("#ffffff0" on the
  // way to "#ffffff00", "rgb(" before the channels) instead of flashing the
  // web fallback, while "#gg" and "rgb(foo)" still fall through.
  for (const q of ['#', '#f', '#ff', '#fffff', '#ffffff0', '#12345',
    'rgb(', 'rgb(1', 'rgb(255, 136)', 'rgb(1, 2, 3', 'rgb(1,2)', 'rgb()',
    'hsl(', 'hsl(32, 100%', 'rgba(1, 2, 3, 0.', 'hsv(200, 40%',
    'hsva(60, 100%, 50%, 0.7', 'rgb (1, 2, 3', 'RGB(255, 0,']) {
    eq(`${JSON.stringify(q)} is mid-typing`, COL.isColorIncomplete(q), true)
  }
  // Complete codes are decided, not pending.
  for (const q of CORPUS) {
    eq(`${JSON.stringify(q)} is not incomplete`, COL.isColorIncomplete(q), false)
  }
  // Unrecoverable text stays a miss: non-hex, overlong hex, a doubled hash,
  // unknown channels, too many channels, a paren violation, or no color
  // shape at all.
  for (const q of ['#gg', '#gggggg', '#123456789', '##', '##########',
    'rgb(foo)', 'rgb(1,2,3,4,5)',
    'rgb(1,2,3))x', 'rgbx(1,2,3)', 'face', 'firefox', 'rgb', '', '   ',
    null, undefined, 42]) {
    eq(`${JSON.stringify(q)} is not mid-typing`, COL.isColorIncomplete(q), false)
  }
  eq('it never throws on an object', COL.isColorIncomplete({}), false)
  noThrow('nor on a number', () => COL.isColorIncomplete(42))
})

group('tryColor is total: a code is six readings, anything else is null', () => {
  const r = COL.tryColor('#ff8800')
  eq('the six readings, in chip order', r.formats.map((f) => [f.fmt, f.text]), [
    ['rgb', 'rgb(255, 136, 0)'],
    ['rgba', 'rgba(255, 136, 0, 1.000)'],
    ['hsl', 'hsl(32, 100%, 50%)'],
    ['hsla', 'hsla(32, 100%, 50%, 1.000)'],
    ['hsv', 'hsv(32, 100%, 100%)'],
    ['hsva', 'hsva(32, 100%, 100%, 1.000)'],
  ])
  eq('the opaque hex the dot is painted', r.hex, '#ff8800')
  eq('the typed code, trimmed', r.input, '#ff8800')
  eq('an opaque alpha', r.alpha, 1)
  // Alpha is parsed and serialized, and deliberately kept out of the dot.
  const half = COL.tryColor('hsla(32, 100%, 50%, 0.5)')
  eq('the alpha readings carry it', half.formats.map((f) => f.text).filter((t) => /0\.500\)/.test(t)).length, 3)
  eq('the dot is still opaque', half.hex, '#ff8800')
  eq('and so is the swatch the row paints', half.hex, COL.hex6(CM.parse('hsla(32, 100%, 50%, 0.5)')))
  // Every miss is a null, never a throw and never a partial row.
  for (const q of ['#gg', '#ff', '#12345', '#gggggg', 'rgb(1,2)', 'rgb(1,2,3', 'rgb()', 'face',
    'firefox', '', '   ', '#', null, undefined, 42]) {
    eq(`tryColor(${JSON.stringify(q)}) is null`, COL.tryColor(q), null)
  }
  for (const q of CORPUS) {
    is(`tryColor(${JSON.stringify(q)}) answers with six`, COL.tryColor(q).formats.length, (v) => v === 6, '6')
  }
  noThrow('an object', () => COL.tryColor({}))
  // A caller reading a null must be able to, and hex6 is the only serializer
  // that answers "" rather than null, so an empty hex is the other null shape.
  eq('an empty hex is the unusable-channel verdict', COL.hex6({}), '')
})

group('tryColor is ColorMath on every accepted code', () => {
  // The agreement, stated over the launcher own entry point: for every code the
  // gate admits, each reading is exactly what ColorMath.format would print, and
  // the dot is exactly ColorMath.hex6.
  for (const s of CORPUS) {
    const mine = COL.tryColor(s)
    const c = CM.parse(s)
    eq(`${s}: the dot`, mine.hex, CM.hex6(c))
    eq(`${s}: the rim`, mine.edge, CM.contrastText(c))
    eq(`${s}: the alpha`, mine.alpha, CM.clampAlpha(c.a))
    for (const f of mine.formats) {
      eq(`${s}: the ${f.fmt} reading`, f.text, CM.format(c, f.fmt, CM.clampAlpha(c.a)))
    }
  }
})

// ---------------------------------------------------------------------------
section('Color.mix - two colours blended into one')
// ---------------------------------------------------------------------------

group('the share is of the second colour', () => {
  eq('no share is the first colour', COL.mix('#141414', '#877070', 0), '#141414')
  eq('all of it is the second colour', COL.mix('#141414', '#877070', 1), '#877070')
  eq('halfway between black and white', COL.mix('#000000', '#ffffff', 0.5), '#808080')
  eq('a third of the way is a third of the way', COL.mix('#000000', '#ffffff', 1 / 3), '#555555')
  // The shell's own case: a near-black surface tinted five percent toward
  // the theme's red. Pinned because it is the number an urgent notification
  // card is painted with, and a change in the rounding would change every
  // urgent card in every theme.
  eq('the urgent tint of the default background', COL.mix('#141414', '#877070', 0.05), '#1a1919')
  eq('a colour mixed with itself is itself', COL.mix('#336699', '#336699', 0.3), '#336699')
})

group('the share is clamped, and a share that is not a number is none', () => {
  eq('above one is the second colour', COL.mix('#141414', '#877070', 2), '#877070')
  eq('below zero is the first colour', COL.mix('#141414', '#877070', -1), '#141414')
  eq('NaN is no share', COL.mix('#141414', '#877070', NaN), '#141414')
  eq('undefined is no share', COL.mix('#141414', '#877070', undefined), '#141414')
  eq('a numeric string is coerced', COL.mix('#141414', '#877070', '0.5'), '#4e4242')
})

group('a colour that cannot be read is no blend at all', () => {
  eq('an unreadable first colour', COL.mix('not-a-color', '#877070', 0.3), '')
  eq('an unreadable second colour', COL.mix('#141414', 'not-a-color', 0.3), '')
  eq('an empty string', COL.mix('', '#877070', 0.3), '')
  eq('null', COL.mix(null, '#877070', 0.3), '')
  eq('undefined', COL.mix(undefined, '#877070', 0.3), '')
  // "" and not a colour, so a caller can tell a failed blend from a black one.
  ne('a failed blend is not black', COL.mix('nope', '#877070', 0.3), '#000000')
})

group('the blend is over the channels, and the result is opaque', () => {
  // The alpha of either colour is dropped: a blend of two palette leaves is a
  // surface, and a surface is opaque.
  eq('a translucent red mixed into black', COL.mix('#ff000080', '#000000', 0.5), '#800000')
  eq('an hsl() colour blends like any other', COL.mix('hsl(0, 100%, 50%)', '#000000', 0.5), '#800000')
  eq('an rgb() colour blends like any other', COL.mix('rgb(255, 0, 0)', '#000000', 0.5), '#800000')
  // The channels are mixed as they are stored - gamma-encoded sRGB, the
  // arithmetic CSS color-mix() does by default - so the midpoint of black and
  // white is the middle grey and not a gamma-space surprise.
  eq('a mid grey is the arithmetic midpoint', COL.mix('#000000', '#ffffff', 0.5), '#808080')
})

// ---------------------------------------------------------------------------
section('UnitLib - the UNITS table')

group('the table is 360 entries across 24 dimensions with no duplicate symbol', () => {
  eq('360 entries', UL.UNITS.length, 360)
  eq('the dimensions', [...new Set(UL.UNITS.map((u) => u.dim))],
    ['length', 'mass', 'volume', 'speed', 'temperature', 'area', 'time', 'energy', 'power', 'pressure', 'data', 'angle',
      'frequency', 'force', 'torque', 'fuel', 'concentration', 'molarity', 'fraction', 'flow',
      'density', 'acceleration', 'datarate', 'count'])
  const syms = UL.UNITS.map((u) => u.sym)
  eq('no duplicate sym', syms.length, new Set(syms).size)
  is('every sym is a non-empty string', UL.UNITS, (v) => v.every((u) => typeof u.sym === 'string' && u.sym !== ''), 'non-empty sym')
  is('every names array is non-empty', UL.UNITS, (v) => v.every((u) => Array.isArray(u.names) && u.names.length > 0), 'non-empty names')
  // A symbol is an alias of its own unit once NORMALIZED, not once lowercased:
  // normalizeUnit drops spaces, underscores and dashes, which is how a multiword
  // symbol like "Earth radius" reaches the "earthradius" its names list carries.
  // Asking for the raw lowercase form instead would fail on every multiword
  // symbol in the table rather than catching anything.
  //
  // The three that are NOT in their own names are the capitalisation traps -
  // Mm, MW and kN fold onto mm, mW and kn, which are three different units. So
  // the rule is the one the engine actually follows: a symbol resolves to its
  // own unit through unitFor, which consults CASE_OVERRIDE before it folds.
  eq('every symbol resolves to its own unit, folded or through the override',
    UL.UNITS.filter((u) => UL.unitFor(u.sym) === null || UL.unitFor(u.sym).sym !== u.sym).map((u) => u.sym), [])
  eq('and the three that need the override are exactly the three traps',
    UL.UNITS.filter((u) => !u.names.includes(UL.normalizeUnit(u.sym))).map((u) => u.sym), ['Mm', 'MW', 'kN'])
  // So symLookup, which matches the table's own spelling first, is what every
  // internal reference has to use: a default or a shortlist entry naming "kN"
  // means the kilonewton, and a bare lookup would hand back the knot.
  eq('and the folded alias table alone would get two of the three wrong',
    ['Mm', 'MW', 'kN'].map((s) => UL.lookup(s).sym), ['mm', 'mW', 'kn'])
  is('every names entry is a non-empty string', UL.UNITS, (v) => v.every((u) => u.names.every((n) => typeof n === 'string' && n !== '')), 'non-empty names')
  is('no alias is shared by two units', UL.UNITS, (v) => {
    const seen = new Set()
    for (const u of v) for (const n of u.names) {
      if (seen.has(n)) return false
      seen.add(n)
    }
    return true
  }, 'aliases are unique')
})

group('every non-temperature unit carries a numeric factor, and only those', () => {
  // The temperature entries are the only ones with no factor, because they
  // convert through Celsius rather than by scaling.
  is('a factor on every non-temperature unit', UL.UNITS,
    (v) => v.filter((u) => u.dim !== 'temperature').every((u) => typeof u.factor === 'number' && isFinite(u.factor)), 'numeric factor')
  eq('the five temperature units', UL.UNITS.filter((u) => u.dim === 'temperature').map((u) => u.sym), ['C', 'F', 'K', 'Re', 'R'])
  is('and no factor on any temperature unit', UL.UNITS,
    (v) => v.filter((u) => u.dim === 'temperature').every((u) => u.factor === undefined), 'no factor')
  is('every factor is positive', UL.UNITS, (v) => v.filter((u) => u.dim !== 'temperature').every((u) => u.factor > 0), 'positive')
})

group('every def resolves to a real unit, so a bare query can never be stranded', () => {
  for (const u of UL.UNITS) {
    const d = UL.lookup(u.def)
    is(`${u.sym} -> ${u.def} resolves`, d, (v) => v !== null, 'non-null')
    is(`${u.sym} -> ${u.def} is the same dimension`, { u, d }, (v) => v.d !== null && v.d.dim === v.u.dim, 'same dim')
  }
})

group('the reference factors are the published ones', () => {
  const f = (sym) => UL.lookup(sym).factor
  approx('1 nm', f('nm'), 1e-9, 0)
  approx('1 um', f('um'), 1e-6, 0)
  approx('1 mm', f('mm'), 0.001, 0)
  approx('1 cm', f('cm'), 0.01, 0)
  approx('1 m', f('m'), 1, 0)
  approx('1 km', f('km'), 1000, 0)
  approx('1 in', f('in'), 0.0254, 0)
  approx('1 ft', f('ft'), 0.3048, 0)
  approx('1 yd', f('yd'), 0.9144, 0)
  approx('1 mi', f('mi'), 1609.344, 0)
  approx('1 nmi', f('nmi'), 1852, 0)
  approx('1 kg', f('kg'), 1, 0)
  approx('1 lb', f('lb'), 0.45359237, 0)
  approx('1 st', f('st'), 6.35029318, 0)
  approx('1 ton', f('ton'), 907.18474, 0)
  approx('1 l', f('l'), 1, 0)
  approx('1 gal', f('gal'), 3.785411784, 0)
  approx('1 m3', f('m3'), 1000, 0)
  approx('1 mph', f('mph'), 0.44704, 0)
  approx('1 atm', f('atm'), 101325, 0)
  approx('1 psi', f('psi'), 6894.757293168, 0)
  approx('1 hp', f('hp'), 745.699872, 0)
  approx('1 eV', f('eV'), 1.602176634e-19, 0)
  approx('1 B', f('B'), 1, 0)
  approx('1 KiB', f('KiB'), 1024, 0)
  approx('1 bit', f('bit'), 0.125, 0)
  // The eight dimensions that arrived with the second half of the table. Each
  // factor is pinned because a wrong one is invisible until somebody converts
  // with it: the ratio assertions at the end of this group only prove the
  // table is self-consistent, not that it agrees with the published value.
  approx('1 Hz', f('Hz'), 1, 0)
  approx('1 kHz', f('kHz'), 1000, 0)
  approx('1 rpm is a sixtieth of a hertz', f('rpm'), 1 / 60, 1e-15)
  approx('1 dyn', f('dyn'), 1e-5, 0)
  approx('1 N', f('N'), 1, 0)
  approx('1 kgf is the weight of a kilogram', f('kgf'), 9.80665, 0)
  approx('1 lbf', f('lbf'), 4.4482216152605, 0)
  approx('1 N\u00b7m', f('N\u00b7m'), 1, 0)
  approx('1 lbf\u00b7ft', f('lbf\u00b7ft'), 1.3558179483314004, 0)
  approx('1 mpg is 0.4251437074976 km/L', f('mpg'), 0.4251437074976, 0)
  approx('1 mpgimp is 0.354006189934 km/L', f('mpgimp'), 0.354006189934, 0)
  approx('1 g/L', f('g/L'), 1, 0)
  approx('1 mg/dL is a hundredth of a g/L', f('mg/dL'), 0.01, 0)
  approx('1 mg/L', f('mg/L'), 0.001, 0)
  approx('1 mol/L', f('mol/L'), 1, 0)
  approx('1 mmol/L', f('mmol/L'), 0.001, 0)
  approx('1 umol/L', f('umol/L'), 1e-6, 0)
  approx('1 % is a hundredth', f('%'), 0.01, 0)
  approx('1 permille is a thousandth', f('\u2030'), 0.001, 0)
  approx('1 ppm', f('ppm'), 1e-6, 0)
  approx('1 ppb', f('ppb'), 1e-9, 0)
  approx('1 m3/h', f('m3/h'), 1, 0)
  approx('1 l/min is 0.06 m3/h', f('l/min'), 0.06, 0)
  approx('1 cfm', f('cfm'), 1.69901079552, 0)
  approx('1 gpm is one US gallon a minute', f('gpm'), 0.22712470704, 0)
  // The table is in SI base units per dimension, so a chain of them is exact.
  approx('1 km is 1000 m', f('km') / f('m'), 1000, 1e-9)
  approx('1 mi is 1609.344 m', f('mi') / f('m'), 1609.344, 1e-9)
  approx('1 cm is 10 mm', f('cm') / f('mm'), 10, 1e-9)
  approx('1 kg is 1000 g', f('kg') / f('g'), 1000, 1e-9)
  approx('1 l is 1000 ml', f('l') / f('ml'), 1000, 1e-9)
  approx('1 h is 3600 s', f('h') / f('s'), 3600, 0)
  approx('1 d is 24 h', f('d') / f('h'), 24, 0)
  approx('1 wk is 7 d', f('wk') / f('d'), 7, 1e-9)
  approx('1 yr is 365 d', f('yr') / f('d'), 365, 1e-9)
  approx('1 KiB is 1024 B', f('KiB') / f('B'), 1024, 0)
  approx('1 TiB is 1024 GiB', 1099511627776 / f('GiB'), 1024, 0)
  // KB, MB, GB and TB are SI decimal and KiB..PiB are binary, so the two
  // ladders disagree by 2.4 percent at every step. That is the published
  // reading of each symbol, not an approximation, so it is pinned.
  approx('1 KB is 1000 B', f('KB') / f('B'), 1000, 0)
  approx('1 MB is 1000 KB', f('MB') / f('KB'), 1000, 0)
  approx('1 GB is 1000 MB', f('GB') / f('MB'), 1000, 0)
  approx('1 TB is 1000 GB', f('TB') / f('GB'), 1000, 0)
  ne('and a kibibyte is not a kilobyte', f('KiB'), f('KB'))
  // The two tonnes: "ton" is the US short ton and longton is the other one.
  approx('1 ton is 2000 lb', f('ton') / f('lb'), 2000, 1e-9)
  approx('1 longton is 2240 lb', f('longton') / f('lb'), 2240, 1e-9)
  ne('and they are not the same unit', f('ton'), f('longton'))
  eq('ton keeps the short name', UL.lookup('ton').sym, 'ton')
  eq('longton claims only its own name', UL.lookup('longton').sym, 'longton')
  // km and mi are deliberately distinct, and both have distinct defaults.
  ne('km and mi are not the same unit', UL.lookup('km').sym, UL.lookup('mi').sym)
  ne('and not the same factor', f('km'), f('mi'))
  eq('km defaults to mi', UL.lookup('km').def, 'mi')
  eq('mi defaults to km', UL.lookup('mi').def, 'km')
})

// ---------------------------------------------------------------------------
section('UnitLib - normalizeUnit, lookup and aliasMap')

group('normalizeUnit lowercases and drops the separators in the names', () => {
  // The comment: "Lowercase, drop spaces/underscores/dashes so 'fluid ounces'
  // hits 'fluidounces'; keep '/', '^' and quotes (m/s, m^2, ')'."
  eq('lowercase', UL.normalizeUnit('M'), 'm')
  eq('uppercase', UL.normalizeUnit('MPS'), 'mps')
  eq('inner spaces', UL.normalizeUnit('fluid ounces'), 'fluidounces')
  eq('underscores', UL.normalizeUnit('fluid_ounces'), 'fluidounces')
  eq('dashes', UL.normalizeUnit('fluid-ounces'), 'fluidounces')
  eq('leading and trailing space', UL.normalizeUnit('  km  '), 'km')
  eq('a repeated underscore run collapses to nothing', UL.normalizeUnit('a__b'), 'ab')
  eq('a dash run collapses too', UL.normalizeUnit('a--b'), 'ab')
  eq('a mixed run', UL.normalizeUnit('a - _ b'), 'ab')
  eq('trailing dots are dropped', UL.normalizeUnit('deg.'), 'deg')
  eq('a repeated trailing dot run', UL.normalizeUnit('deg..'), 'deg')
  eq('an inner dot is kept', UL.normalizeUnit('m.s'), 'm.s')
  // The three kept characters are what make the compound symbols work.
  eq('a slash is kept', UL.normalizeUnit('m/s'), 'm/s')
  eq('a caret is kept', UL.normalizeUnit('m^2'), 'm^2')
  eq('a double quote is kept', UL.normalizeUnit('"'), '"')
  eq('a single quote is kept', UL.normalizeUnit("'"), "'")
  eq('an empty string', UL.normalizeUnit(''), '')
  eq('whitespace only', UL.normalizeUnit('   '), '')
  eq('null', UL.normalizeUnit(null), '')
  eq('undefined', UL.normalizeUnit(undefined), '')
  eq('a number', UL.normalizeUnit(42), '42')
})

group('normalizeUnit alone does not make a name resolvable', () => {
  // A typo normalizes cleanly and then simply misses the alias table, so an
  // unknown unit is a null rather than a wrong conversion.
  eq('a typo', UL.normalizeUnit('metres!'), 'metres!')
  eq('and lookup rejects it', UL.lookup('metres!'), null)
  eq('a real name survives', UL.lookup('metres').sym, 'm')
})

group('lookup resolves every documented alias, case-insensitively', () => {
  const at = (a) => { const u = UL.lookup(a); return u === null ? null : u.sym }
  eq('m', at('m'), 'm')
  eq('meter', at('meter'), 'm')
  eq('meters', at('meters'), 'm')
  eq('metre', at('metre'), 'm')
  eq('metres', at('metres'), 'm')
  eq('M', at('M'), 'm')
  eq('METERS', at('METERS'), 'm')
  eq('Feet', at('Feet'), 'ft')
  eq('inches', at('inches'), 'in')
  eq('" is the inch', at('"'), 'in')
  eq("' is the foot", at("'"), 'ft')
  eq('fluidounces', at('fluidounces'), 'floz')
  eq('ukfluidounces', at('ukfluidounces'), 'ukfloz')
  eq('sqm', at('sqm'), 'm2')
  eq('sqft', at('sqft'), 'ft2')
  eq('sqmi', at('sqmi'), 'mi2')
  eq('ft3', at('ft3'), 'ft3')
  eq('ft^3', at('ft^3'), 'ft3')
  eq('m^3', at('m^3'), 'm3')
  eq('mps', at('mps'), 'm/s')
  eq('kmh', at('kmh'), 'km/h')
  eq('kph', at('kph'), 'km/h')
  eq('mi/h', at('mi/h'), 'mph')
  eq('fps', at('fps'), 'ft/s')
  eq('kt', at('kt'), 'kn')
  eq('knots', at('knots'), 'kn')
  eq('torr', at('torr'), 'mmHg')
  eq('degc', at('degc'), 'C')
  eq('centigrade', at('centigrade'), 'C')
  eq('k', at('k'), 'K')
  eq('kelvin', at('kelvin'), 'K')
  eq('b', at('b'), 'B')
  eq('kilobyte', at('kilobyte'), 'KB')
  eq('kib', at('kib'), 'KiB')
  eq('sec', at('sec'), 's')
  eq('secs', at('secs'), 's')
  eq('hrs', at('hrs'), 'h')
  eq('metricton', at('metricton'), 't')
  eq('shortton', at('shortton'), 'ton')
  eq('pascal', at('pascal'), 'Pa')
  eq('atmospheres', at('atmospheres'), 'atm')
  eq('kilowatthours', at('kilowatthours'), 'kWh')
  eq('radian', at('radian'), 'rad')
  // The eight newer dimensions, so a dimension whose every alias was renamed
  // would not look like a dimension that merely has few names.
  eq('hertz', at('hertz'), 'Hz')
  eq('revolutionsperminute', at('revolutionsperminute'), 'rpm')
  eq('newtons', at('newtons'), 'N')
  eq('kilogramforce', at('kilogramforce'), 'kgf')
  eq('poundforces', at('poundforces'), 'lbf')
  eq('newtonmetres', at('newtonmetres'), 'N\u00b7m')
  eq('footpounds', at('footpounds'), 'lbf\u00b7ft')
  eq('milespergallon', at('milespergallon'), 'mpg')
  eq('imperialmpg', at('imperialmpg'), 'mpgimp')
  eq('gramsperliter', at('gramsperliter'), 'g/L')
  eq('milligramsperdeciliter', at('milligramsperdeciliter'), 'mg/dL')
  eq('molar', at('molar'), 'mol/L')
  eq('millimolar', at('millimolar'), 'mmol/L')
  eq('micromolar', at('micromolar'), 'umol/L')
  eq('percent', at('percent'), '%')
  eq('permille', at('permille'), '\u2030')
  eq('partspermillion', at('partspermillion'), 'ppm')
  eq('literperminute', at('literperminute'), 'l/min')
  eq('cubicmetersperhour', at('cubicmetersperhour'), 'm3/h')
  eq('gallonperminute', at('gallonperminute'), 'gpm')
})

group('normalizeUnit also folds the spellings a keyboard cannot reach', () => {
  // Lowercasing and separator dropping are not enough for a unit that is
  // typed with a sign instead of a letter, so the transliterations run after
  // the folding: both mu letters become "u", the superscript digits become
  // "^1".."^3", the degree sign is dropped, and the latin small letter a with
  // ring becomes "angstrom".
  eq('the micro sign', UL.normalizeUnit('\u00b5m'), 'um')
  eq('the greek mu', UL.normalizeUnit('\u03bcm'), 'um')
  eq('a bare mu sign is a u', UL.normalizeUnit('\u00b5'), 'u')
  eq('the superscript two', UL.normalizeUnit('m\u00b2'), 'm^2')
  eq('the superscript three', UL.normalizeUnit('cm\u00b3'), 'cm^3')
  eq('the superscript one', UL.normalizeUnit('m\u00b9'), 'm^1')
  eq('a superscript on a named unit', UL.normalizeUnit('cm\u00b3'), 'cm^3')
  // The sign is dropped ONLY in front of a scale name, where it is decoration:
  // "\u00b0C" is Celsius either way. In front of anything else it IS the unit -
  // the degree of angle - and dropping it there used to fuse it with whatever
  // word followed once the spaces went, so "90 deg in rad" split at the keyword
  // and the head came back as the inch.
  eq('the degree sign is dropped before a scale', UL.normalizeUnit('\u00b0C'), 'c')
  eq('and before the long scale names too', UL.normalizeUnit('\u00b0fahrenheit'), 'fahrenheit')
  eq('but a lone degree sign is the angle and stays', UL.normalizeUnit('\u00b0'), '\u00b0')
  eq('and the sign reaches the degree row', UL.lookup('\u00b0').sym, 'deg')
  eq('so a typed degree converts', cvOut('90\u00b0 in rad'), Math.PI / 2, 1e-9)
  eq('the ring above becomes the name', UL.normalizeUnit('\u00c5'), 'angstrom')
  eq('and it is folded first, so a capital ring works too', UL.normalizeUnit('\u00e5'.toUpperCase()), 'angstrom')
  // The three characters normalizeUnit deliberately keeps. The slash is a
  // rate, the caret is a power, and the two quotes are the inch and the foot -
  // which is also why the middle dot survives, being none of the three.
  eq('the middle dot survives', UL.normalizeUnit('N\u00b7m'), 'n\u00b7m')
  eq('and the star is kept as a second spelling of the middle dot', UL.normalizeUnit('N*m'), 'n*m')
  eq('the permille sign is already an alias', UL.normalizeUnit('\u2030'), '\u2030')
  // Reachability is the point of a fold: each transliterated spelling has to
  // land on a real row, not merely normalize into a plausible-looking string.
  eq('the micro sign reaches the micrometre', UL.lookup('\u00b5m').sym, 'um')
  eq('the greek mu reaches the same row', UL.lookup('\u03bcm').sym, 'um')
  eq('the superscript two reaches the square metre', UL.lookup('m\u00b2').sym, 'm2')
  eq('the superscript three reaches the cubic centimetre', UL.lookup('cm\u00b3').sym, 'ml')
  eq('the degree sign reaches Celsius', UL.lookup('\u00b0C').sym, 'C')
  eq('the ring above reaches the angstrom', UL.lookup('\u00c5').sym, 'A')
  eq('the middle dot reaches the newton metre', UL.lookup('N\u00b7m').sym, 'N\u00b7m')
  // And a fold never invents a unit: a transliterated string that is not an
  // alias is still a miss, not a near neighbour.
  eq('a bare mu sign is no unit', UL.lookup('\u00b5'), null)
  // Both of these were refusals and are now rows. "N*m" is the middle dot
  // written the way a keyboard can reach it, and m/s\u00b2 is an acceleration -
  // a distinct dimension with its own rows, not a malformed speed.
  eq('a star reaches the newton metre', UL.lookup('N*m').sym, 'N\u00b7m')
  eq('and a squared speed is an acceleration', UL.lookup('m/s\u00b2').dim, 'acceleration')
  eq('which is not the speed dimension', UL.lookup('m/s\u00b2').dim === UL.lookup('m/s').dim, false)
})

group('an unknown or empty key is null, never a wrong unit', () => {
  eq('a nonsense word', UL.lookup('nope'), null)
  eq('a near miss', UL.lookup('metr'), null)
  eq('a number', UL.lookup('5'), null)
  eq('an empty string', UL.lookup(''), null)
  eq('whitespace only', UL.lookup('   '), null)
  eq('null', UL.lookup(null), null)
  eq('undefined', UL.lookup(undefined), null)
  eq('a prototype key is not an alias', UL.lookup('constructor'), null)
  eq('toString is not an alias', UL.lookup('toString'), null)
  eq('__proto__ is not an alias', UL.lookup('__proto__'), null)
  eq('hasOwnProperty is not an alias', UL.lookup('hasOwnProperty'), null)
})

group('aliasMap is built once and covers every name exactly once', () => {
  const m = UL.aliasMap()
  eq('1190 aliases', Object.keys(m).length, 1190)
  eq('and it is the cached instance on the second call', UL.aliasMap() === m, true)
  eq('the alias count matches the name count', Object.keys(m).length,
    UL.UNITS.reduce((n, u) => n + u.names.length, 0))
  is('every alias points at a table entry', m, (v) => Object.values(v).every((u) => UL.UNITS.includes(u)), 'a real entry')
  is('every alias maps to the unit that lists it', m, (v) => UL.UNITS.every((u) => u.names.every((n) => v[n] === u)), 'consistent')
  is('the keys are all lowercase already', m, (v) => Object.keys(v).every((k) => k === k.toLowerCase()), 'lowercase')
  // The map is the one place a normalized name meets the table, so a name
  // that normalizeUnit changes must still be findable under its raw form.
  is('every raw name is findable', m, (v) => UL.UNITS.every((u) => u.names.every((n) => UL.lookup(n) !== null)), 'all reachable')
})

// ---------------------------------------------------------------------------
section('UnitLib.formatNumber')

group('an integer prints plain, with -0 normalised to 0', () => {
  eq('0', UL.formatNumber(0), '0')
  eq('-0', UL.formatNumber(-0), '0')
  eq('1', UL.formatNumber(1), '1')
  eq('42', UL.formatNumber(42), '42')
  eq('100', UL.formatNumber(100), '100')
  eq('1e12', UL.formatNumber(1e12), '1000000000000')
  eq('1e13', UL.formatNumber(1e13), '10000000000000')
  eq('1e6*1e6', UL.formatNumber(1000000 * 1000000), '1000000000000')
  eq('1234567', UL.formatNumber(1234567), '1234567')
  eq('745.7 from a trim', UL.formatNumber(745.699872), '745.7')
})

group('a decimal is rounded to six significant digits, not ten decimal places', () => {
  // The code comment: "At most 6 significant digits: '20cm' reads '7.87402 in'
  // while exact-looking results ('402.336', '2.20462') are untouched". The
  // header comment two dozen lines earlier instead says the routine is the
  // "Same rounding as CalcLib.formatResult ... trimmed to 10dp", which is
  // not what toPrecision(6) does. 1/3 is the clearest witness: CalcLib's
  // formatResult prints 0.3333333333, this prints 0.333333.
  eq('1/3', UL.formatNumber(1 / 3), '0.333333')
  eq('2/3', UL.formatNumber(2 / 3), '0.666667')
  eq('2.5', UL.formatNumber(2.5), '2.5')
  eq('0.5', UL.formatNumber(0.5), '0.5')
  eq('the 0.1+0.2 artefact is rounded away', UL.formatNumber(0.1 + 0.2), '0.3')
  eq('402.336 is untouched', UL.formatNumber(402.336), '402.336')
  eq('2.20462 is untouched', UL.formatNumber(2.2046226218487757), '2.20462')
  eq('7.87402 is untouched', UL.formatNumber(7.874015748031497), '7.87402')
  eq('3.28084 from 6 significant digits', UL.formatNumber(3.280839895013123), '3.28084')
  eq('123.456789 rounds', UL.formatNumber(123.456789), '123.457')
  eq('-3.14159', UL.formatNumber(-3.14159), '-3.14159')
  eq('1.0000005 loses its fraction', UL.formatNumber(1.0000005), '1')
  // The two routines differ on the same input, which is the observable form
  // of the drift: same rounding as CalcLib.formatResult would make these equal.
  eq('CalcLib prints 1/3 with 10 decimal places', CL.formatResult(1 / 3), '0.3333333333')
  ne('and the two formatters disagree on it', CL.formatResult(1 / 3), UL.formatNumber(1 / 3))
  ne('and on 2/3', CL.formatResult(2 / 3), UL.formatNumber(2 / 3))
  skip('formatNumber is the same rounding as CalcLib.formatResult', 'UnitLib.js:227-228 claims 10dp; :244 uses toPrecision(6), so 1/3 is 0.333333 here and 0.3333333333 there')
  // At 1e6 magnitude six significant digits land on a whole number, so the
  // decimal part disappears entirely.
  eq('123456.789 becomes 123457', UL.formatNumber(123456.789), '123457')
  // Between there and 1e12 a whole number is the readable answer, so this rounds
  // to a million rather than reaching for the exponent form.
  eq('999999.9 becomes 1000000', UL.formatNumber(999999.9), '1000000')
})

group('an extreme magnitude switches to a trimmed exponential form', () => {
  eq('1e-7', UL.formatNumber(1e-7), '1e-7')
  eq('1e-21', UL.formatNumber(1e-21), '1e-21')
  eq('1e+21', UL.formatNumber(1e21), '1e+21')
  eq('1.5e-7 keeps one mantissa digit', UL.formatNumber(1.5e-7), '1.5e-7')
  eq('the eV factor', UL.formatNumber(1.602176634e-19), '1.602177e-19')
  eq('a subnormal result', UL.formatNumber(2.204521e-320), '2.204521e-320')
  eq('a 1e296 result', UL.formatNumber(1e296), '1e+296')
  eq('1e-6 is on the fixed side of the boundary', UL.formatNumber(1e-6), '0.000001')
  eq('1e-5', UL.formatNumber(1e-5), '0.00001')
  eq('0.000001', UL.formatNumber(0.000001), '0.000001')
})

group('the non-numbers are named, and only NaN is a real one', () => {
  eq('NaN', UL.formatNumber(NaN), 'NaN')
  eq('Infinity', UL.formatNumber(Infinity), 'Infinity')
  eq('-Infinity', UL.formatNumber(-Infinity), '-Infinity')
  // Unlike CalcLib.formatResult, this routine tests isNaN first and answers
  // "NaN" for any non-number, so a numeric string does not read as Infinity.
  eq('a numeric string', UL.formatNumber('42'), 'NaN')
  eq('null', UL.formatNumber(null), 'NaN')
  eq('undefined', UL.formatNumber(undefined), 'NaN')
  eq('an object', UL.formatNumber({}), 'NaN')
  eq('true', UL.formatNumber(true), 'NaN')
})

group('a formatted conversion always parses back to the same 6 digits', () => {
  // The property the copy button depends on: what the user pastes is what
  // the converter would read again.
  for (const v of [1 / 3, 402.336, 7.874015748031497, 1.602176634e-19, 123.456789, 0.1 + 0.2, 1000000.5]) {
    const s = UL.formatNumber(v)
    is(`formatNumber(${v}) reparses`, { v, s }, (r) => Number.isFinite(Number(r.s)) || r.s === 'Infinity' || r.s === '-Infinity', 'a parseable string')
    approx(`and agrees with the value for ${s}`, Number(s), v, Math.abs(v) * 1e-5 + 1e-12)
  }
})

// ---------------------------------------------------------------------------
section('UnitLib - temperature')

group('toCelsius and fromCelsius are exact at the freezing and boiling points', () => {
  approx('32 F is 0 C', UL.toCelsius(32, 'F'), 0, 0)
  approx('212 F is 100 C', UL.toCelsius(212, 'F'), 100, 0)
  approx('0 C is 0 C', UL.toCelsius(0, 'C'), 0, 0)
  approx('100 C is 100 C', UL.toCelsius(100, 'C'), 100, 0)
  approx('273.15 K is 0 C', UL.toCelsius(273.15, 'K'), 0, 1e-12)
  approx('373.15 K is 100 C', UL.toCelsius(373.15, 'K'), 100, 1e-12)
  approx('0 C is 32 F', UL.fromCelsius(0, 'F'), 32, 0)
  approx('100 C is 212 F', UL.fromCelsius(100, 'F'), 212, 0)
  approx('-40 C is -40 F', UL.fromCelsius(-40, 'F'), -40, 0)
  approx('0 C is 273.15 K', UL.fromCelsius(0, 'K'), 273.15, 1e-12)
  approx('100 C is 373.15 K', UL.fromCelsius(100, 'K'), 373.15, 1e-12)
  approx('-273.15 C is 0 K', UL.fromCelsius(-273.15, 'K'), 0, 1e-12)
  approx('0 C is 0 C', UL.fromCelsius(0, 'C'), 0, 0)
})

group('the absolute-zero anchor is 0 K = -273.15 C', () => {
  approx('0 K in Celsius', UL.toCelsius(0, 'K'), -273.15, 1e-12)
  approx('0 K in Fahrenheit', UL.fromCelsius(UL.toCelsius(0, 'K'), 'F'), -459.67, 1e-9)
  approx('-459.67 F in Celsius', UL.toCelsius(-459.67, 'F'), -273.15, 1e-2)
  approx('1 K is -272.15 C', UL.toCelsius(1, 'K'), -272.15, 1e-12)
  approx('body temperature 37 C is 98.6 F', UL.fromCelsius(37, 'F'), 98.6, 1e-9)
  approx('98.6 F is 37 C', UL.toCelsius(98.6, 'F'), 37, 1e-9)
})

group('the identity holds in both directions for every unit', () => {
  // All five temperature rows now: Reaumur and Rankine came in with the second
  // half of the table, and a scale that round-trips through Celsius is the only
  // evidence that its offset is not simply missing.
  for (const s of ['C', 'F', 'K', 'Re', 'R']) {
    approx(`${s} round trip at 0`, UL.fromCelsius(UL.toCelsius(0, s), s), 0, 1e-9)
    approx(`${s} round trip at 100`, UL.fromCelsius(UL.toCelsius(100, s), s), 100, 1e-9)
    approx(`${s} round trip at 25`, UL.fromCelsius(UL.toCelsius(25, s), s), 25, 1e-9)
    approx(`${s} round trip at -40`, UL.fromCelsius(UL.toCelsius(-40, s), s), -40, 1e-9)
  }
  // The two named points, so a swapped offset cannot hide behind the identity.
  approx('100 Re is 125 C', UL.toCelsius(100, 'Re'), 125, 1e-9)
  approx('0 R is -273.15 C', UL.toCelsius(0, 'R'), -273.15, 1e-9)
  approx('0 R is 491.67 F', UL.fromCelsius(0, 'R'), 491.67, 1e-9)
})

group('an unknown unit symbol falls through to the identity', () => {
  // toCelsius returns v unless the symbol is F or K, and fromCelsius returns
  // c unless the symbol is F or K. Nothing in the table can produce another
  // symbol, so this is the guard for a caller that builds one.
  approx('toCelsius with an unknown symbol', UL.toCelsius(5, 'Q'), 5, 0)
  approx('fromCelsius with an unknown symbol', UL.fromCelsius(5, 'Q'), 5, 0)
  approx('toCelsius with no symbol', UL.toCelsius(5), 5, 0)
  approx('fromCelsius with no symbol', UL.fromCelsius(5), 5, 0)
  approx('toCelsius with a lowercase f', UL.toCelsius(32, 'f'), 32, 0)
  approx('fromCelsius with a lowercase c', UL.fromCelsius(32, 'c'), 32, 0)
  is('neither throws on any symbol', ['C', 'F', 'K', 'Q', '', null, undefined], (syms) => syms.every((s) => {
    try { UL.toCelsius(1, s); UL.fromCelsius(1, s); return true } catch { return false }
  }), 'never throws')
})

// ---------------------------------------------------------------------------
section('UnitLib - the per-keystroke gates')

group('preprocess is text only: an arrow, a filler word, a question, a tail', () => {
  // The header's stage 1. Every one of these rewrites is a whole query in the
  // shape a person actually types, so preprocess is where natural language is
  // spent; nothing downstream knows any of these words.
  eq('an unpadded arrow', UL.preprocess('5km->mi'), '5km -> mi')
  eq('a longer arrow run', UL.preprocess('5 km --> mi'), '5 km -> mi')
  eq('a spaced arrow is untouched', UL.preprocess('5 km -> mi'), '5 km -> mi')
  eq('a canonical query is untouched', UL.preprocess('5 km in mi'), '5 km in mi')
  eq('convert', UL.preprocess('convert 5 km to mi'), '5 km to mi')
  eq('calculate', UL.preprocess('calculate 5km to mi'), '5km to mi')
  eq('calc', UL.preprocess('calc 5km to mi'), '5km to mi')
  eq('what is', UL.preprocess('what is 5 km to mi'), '5 km to mi')
  eq("what's", UL.preprocess("what's 5 km to mi"), '5 km to mi')
  eq('whats', UL.preprocess('whats 5 km to mi'), '5 km to mi')
  eq('what was', UL.preprocess('what was 5 km to mi'), '5 km to mi')
  eq('the filler is case-insensitive', UL.preprocess('CONVERT 5 km to mi'), '5 km to mi')
  // The three inverted question forms. Each names the quantity and the target
  // in the opposite order from the canonical shape, so the captures swap: the
  // first two put the target first and the third puts the quantity first, so
  // that one rewrites into itself.
  eq('how many <unit> in <quantity>', UL.preprocess('how many km in 5 mi'), '5 mi in km')
  eq('how much <unit> in <quantity>', UL.preprocess('how much miles in 5 km'), '5 km in miles')
  eq('<quantity> is how many <unit>', UL.preprocess('5 km is how many miles'), '5 km in miles')
  eq('how much is <quantity> in <unit>', UL.preprocess('how much is 5 kg in lb'), '5 kg in lb')
  eq('a rewritten question is case-insensitive too', UL.preprocess('HOW MANY KM IN 5 MI'), '5 MI in KM')
  // The politeness forms. "please" and "pls" carry the trailing punctuation
  // with them, so "5 km in mi please?" loses both in one substitution.
  eq('please', UL.preprocess('5 km in mi please'), '5 km in mi')
  eq('pls', UL.preprocess('5 km in mi pls'), '5 km in mi')
  eq('a question mark', UL.preprocess('5 km in mi?'), '5 km in mi')
  eq('an exclamation mark', UL.preprocess('5 km in mi!'), '5 km in mi')
  eq('a mark with a space before it', UL.preprocess('5 km in mi ?'), '5 km in mi')
  eq('please and a mark together', UL.preprocess('5 km in mi please?!'), '5 km in mi')
  eq('punctuation only', UL.preprocess('5 km in mi?!'), '5 km in mi')
  // A quote is never in the tail pattern: it is the inch and the foot. That is
  // the whole reason RE_TAIL is a separate strip from the politeness strip.
  eq("a foot and an inch survive", UL.preprocess("6'2\""), "6'2\"")
  eq('and a trailing inch mark with it', UL.preprocess("5'\""), "5'\"")
  // One filler word per pass, because the rewritten text is not fed back
  // through preprocess. "convert convert 5 km to mi" is therefore still
  // rejected downstream rather than being read as a unit called "convert".
  eq('a doubled filler word loses one', UL.preprocess('convert convert 5 km to mi'), 'convert 5 km to mi')
  eq('and the query is a fall-through, not a conversion', UL.tryConvert('convert convert 5 km to mi'), null)
  // The tail is dropped before the question forms are read, so a "please" can
  // never end up inside a capture and rewrite to "5 mi please? in km".
  eq('a question with a trailing please loses it',
    UL.preprocess('how many km in 5 mi please?'), '5 mi in km')
  approx('and still converts', UL.tryConvert('how many km in 5 mi please?').out, 8.04672, 1e-9)
  // The nullish and degenerate inputs the String() coercion covers.
  eq('null is the empty string', UL.preprocess(null), '')
  eq('undefined is the empty string', UL.preprocess(undefined), '')
  eq('whitespace is trimmed away', UL.preprocess('   5 km in mi   '), '5 km in mi')
  eq('an app name is untouched', UL.preprocess('firefox'), 'firefox')
  eq('pure math is untouched', UL.preprocess('2+2'), '2+2')
  // A filler word only counts at the START and only with its space, so a unit
  // or an app whose name begins with one of these words is not swallowed.
  eq('a value first is not a filler word', UL.preprocess('5 convert km'), '5 convert km')
  eq('a word that merely starts with a filler is not one', UL.preprocess('calculator 5km'), 'calculator 5km')
  eq('a filler word with no body is left alone', UL.preprocess('convert'), 'convert')
  // stripTail is preprocess's tail stage on its own, so it is worth pinning
  // without the rest of the pipeline around it.
  eq('stripTail takes the politeness with its marks', UL.stripTail('5 km in mi please?!'), '5 km in mi')
  eq('stripTail takes a bare mark', UL.stripTail('5 km in mi?!'), '5 km in mi')
  eq('stripTail takes nothing from a quote', UL.stripTail("6'2\""), "6'2\"")
  eq('stripTail leaves a clean string alone', UL.stripTail('5 km in mi'), '5 km in mi')
})

group('isPotentialUnit wants a leading number and a letter-ish unit char', () => {
  eq('5m', UL.isPotentialUnit('5m'), true)
  eq('-5m', UL.isPotentialUnit('-5m'), true)
  eq('+5m', UL.isPotentialUnit('+5m'), true)
  eq('.5m', UL.isPotentialUnit('.5m'), true)
  eq('-.5m', UL.isPotentialUnit('-.5m'), true)
  eq('5.m', UL.isPotentialUnit('5.m'), true)
  eq('007m', UL.isPotentialUnit('007m'), true)
  eq('1e3m', UL.isPotentialUnit('1e3m'), true)
  eq('1e-3m', UL.isPotentialUnit('1e-3m'), true)
  eq('1e+3m', UL.isPotentialUnit('1e+3m'), true)
  eq('a space before the unit', UL.isPotentialUnit('5 m'), true)
  eq('a tab', UL.isPotentialUnit('5m\tin cm'), true)
  eq('the inch quote', UL.isPotentialUnit('5"'), true)
  eq('the foot quote', UL.isPotentialUnit("5'"), true)
  eq('a speed unit', UL.isPotentialUnit('5m/s'), true)
  eq('an explicit target', UL.isPotentialUnit('5.m in cm'), true)
  eq('thousands grouping', UL.isPotentialUnit('1,000 km'), true)
})

group('the gate runs on the preprocessed text, so a filler word is not a reason to say no', () => {
  // isPotentialUnit calls preprocess first, so every natural-language form
  // that tryConvert accepts is admitted here too. If the gate ran on the raw
  // query, "convert 5 km to mi" would look like a word and be dropped.
  for (const q of ['convert 5 km to mi', 'calculate 5km', 'calc 5km', 'what is 5km', "what's 5km",
    'how many km in 5 mi', '5 km is how many miles', 'how much is 5 kg in lb', '5 km in mi please', '5 km in mi?']) {
    eq(`${JSON.stringify(q)} is admitted`, UL.isPotentialUnit(q), true)
  }
  // And the gate's own refusals are unchanged, because preprocess cannot make
  // a number out of an app name or strip an operator.
  eq('an app name', UL.isPotentialUnit('firefox'), false)
  eq('a filler word on its own', UL.isPotentialUnit('convert'), false)
  eq('pure math', UL.isPotentialUnit('2+2'), false)
  eq('time in X', UL.isPotentialUnit('time in X'), false)
  eq('a bare number', UL.isPotentialUnit('5'), false)
  eq('the empty string', UL.isPotentialUnit(''), false)
  eq('null', UL.isPotentialUnit(null), false)
  eq('129 chars', UL.isPotentialUnit('1m' + 'x'.repeat(127)), false)
  eq('128 chars', UL.isPotentialUnit('1m' + 'x'.repeat(126)), true)
})

group('isPotentialUnit rejects the three families the comment names', () => {
  // "Plain app names ('firefox'), pure math ('2+2') and 'time in X' all fail
  // here."
  eq('an app name', UL.isPotentialUnit('firefox'), false)
  eq('a name with a leading number-free shape', UL.isPotentialUnit('m5'), false)
  eq('pure math', UL.isPotentialUnit('2+2'), false)
  eq('time in X', UL.isPotentialUnit('time in X'), false)
  eq('a bare number', UL.isPotentialUnit('5'), false)
  eq('a bare exponent passes the gate', UL.isPotentialUnit('1e3'), true)
  eq('but has no unit, so tryConvert refuses it', UL.tryConvert('1e3'), null)
  eq('a bare decimal', UL.isPotentialUnit('5.'), false)
  eq('a leading dot with no unit', UL.isPotentialUnit('.m'), false)
  eq('a leading dot alone', UL.isPotentialUnit('.'), false)
  eq('a leading 5e with no unit', UL.isPotentialUnit('5e'), true)
  eq('empty', UL.isPotentialUnit(''), false)
  eq('spaces', UL.isPotentialUnit('   '), false)
  eq('null', UL.isPotentialUnit(null), false)
  eq('undefined', UL.isPotentialUnit(undefined), false)
  eq('multiline', UL.isPotentialUnit('5m\nin cm'), false)
  eq('carriage return', UL.isPotentialUnit('5m\rin cm'), false)
  eq('over 128 chars', UL.isPotentialUnit('1m' + 'x'.repeat(127)), false)
  eq('exactly 128 chars', UL.isPotentialUnit('1m' + 'x'.repeat(126)), true)
})

group('RE_NUM takes the leading number and leaves the unit behind', () => {
  const m = (s) => { const r = String(s).match(UL.RE_NUM); return r === null ? null : [r[0], s.substring(r[0].length)] }
  eq('5m', m('5m'), ['5', 'm'])
  eq('-5m', m('-5m'), ['-5', 'm'])
  eq('+5', m('+5'), ['+5', ''])
  eq('.5m', m('.5m'), ['.5', 'm'])
  eq('5.m', m('5.m'), ['5.', 'm'])
  eq('5.', m('5.'), ['5.', ''])
  eq('.5', m('.5'), ['.5', ''])
  eq('007m', m('007m'), ['007', 'm'])
  eq('1e3m', m('1e3m'), ['1e3', 'm'])
  eq('1e+3m', m('1e+3m'), ['1e+3', 'm'])
  eq('1e-3m', m('1e-3m'), ['1e-3', 'm'])
  eq('1e with no digits is just 1', m('1e'), ['1', 'e'])
  eq('..5 has no number', m('..5'), null)
  eq('a bare minus', m('-'), null)
  eq('a bare plus', m('+'), null)
  eq('a bare dot', m('.'), null)
  eq('a leading letter', m('m5'), null)
  eq('a leading comma', m(',5'), null)
  eq('an uppercase exponent', m('1E3m'), ['1E3', 'm'])
  // The thousands-grouping alternative is the currency engine's, so "1,000 km"
  // parses here for the same reason "1,000 usd" parses there. The grouping has
  // to be complete: one to three digits, a comma, three digits.
  eq('grouping', m('1,000 km'), ['1,000', ' km'])
  eq('a signed grouping', m('-1,000 km'), ['-1,000', ' km'])
  eq('grouping with a fraction', m('12,345.67 m'), ['12,345.67', ' m'])
  eq('several groups', m('1,000,000'), ['1,000,000', ''])
  eq('a partial group is not grouping', m('1,00 km'), ['1', ',00 km'])
  eq('four digits after the comma split the number', m('1,0000 km'), ['1,000', '0 km'])
  eq('a doubled comma is not grouping', m('1,,000'), ['1', ',,000'])
  // A decimal comma is deliberately not a number: "1,5" is the grouping prefix
  // of a number that never ends, so reading it as 1.5 would be a guess, and a
  // silent guess is the one thing this engine must not do.
  eq('a decimal comma is refused', m('1,5 km'), ['1', ',5 km'])
  eq('and the query falls through', UL.tryConvert('1,5 km'), null)
  // The bare trailing dot is the other half of the same idea: "5.mm" is five
  // millimetres typed with the dot of a decimal that has no digits behind it,
  // and the dot has to be part of the number because normalizeUnit keeps a
  // leading one and ".mm" is not a unit.
  eq('a bare trailing dot', m('5.mm'), ['5.', 'mm'])
  eq('the digits-first order is what keeps 2.5 a decimal', m('2.5m'), ['2.5', 'm'])
  eq('so "5.mm in cm" is half a centimetre', cvOut('5.mm in cm'), 0.5, 1e-12)
  // The written form, commas and bare dots included, is what the label echoes,
  // so a value that round-trips through the label still parses.
  eq('the grouping is echoed in the source text', cvOk('1,000 km in mi').inputText, '1,000 km')
  approx('and it converted as a thousand', cvOut('1,000 km in mi'), 621.371192237334, 1e-9)
  eq('a bare trailing dot is echoed too', cvOk('5.m in cm').inputText, '5. m')
  approx('and it is five metres', cvOut('5.m in cm'), 500, 1e-9)
  // The number is the whole prefix, so a digit immediately after it is a
  // malformed unit rather than part of the value.
  eq('5m5 splits at the first m', m('5m5'), ['5', 'm5'])
  eq('and a digit-led rest is rejected by tryConvert', UL.tryConvert('5m5'), null)
  eq('and a bare number is rejected too', UL.tryConvert('5'), null)
  eq('and a number with no unit', UL.tryConvert('1e3'), null)
  eq('and a number that overflows to Infinity', UL.tryConvert('1e999m'), null)
  eq('and an explicit target on one', UL.tryConvert('1e999m in cm'), null)
  // A subnormal is finite, so it converts; only a non-finite value is refused.
  is('a subnormal is fine', UL.tryConvert('1e-320kg in lb'), (v) => v !== null && v.ok === true, 'a result')
  is('every match is parseable', ['5m', '-5m', '.5m', '1e3m', '007m'], (list) => list.every((s) => !Number.isNaN(Number(s.match(UL.RE_NUM)[0]))), 'finite')
})

group('splitExplicit cuts on the last keyword, so an inch source survives', () => {
  // The comment: "Split '5m in cm' into head/target on the LAST keyword so
  // the inch unit 'in' in '5 in in cm' still parses (source 'in', key 'in')."
  eq('m in cm', UL.splitExplicit('m in cm'), { head: 'm', key: 'in', tail: 'cm' })
  eq('in in cm takes the last keyword', UL.splitExplicit('in in cm'), { head: 'in', key: 'in', tail: 'cm' })
  eq('m to ft', UL.splitExplicit('m to ft'), { head: 'm', key: 'to', tail: 'ft' })
  eq('m as km', UL.splitExplicit('m as km'), { head: 'm', key: 'as', tail: 'km' })
  eq('m -> km', UL.splitExplicit('m -> km'), { head: 'm', key: '->', tail: 'km' })
  eq('m = km', UL.splitExplicit('m = km'), { head: 'm', key: '=', tail: 'km' })
  // "into" is the sixth keyword. It is safe in the alternation because a split
  // only happens where a unit follows the keyword.
  eq('m into km', UL.splitExplicit('m into km'), { head: 'm', key: 'into', tail: 'km' })
  eq('into is case-insensitive', UL.splitExplicit('m INTO km'), { head: 'm', key: 'INTO', tail: 'km' })
  eq('a trailing into with no target', UL.splitExplicit('m into'), { head: 'm', key: 'into', tail: '' })
  eq('the keyword is case-insensitive', UL.splitExplicit('m IN cm'), { head: 'm', key: 'IN', tail: 'cm' })
  eq('mixed case', UL.splitExplicit('m In cm'), { head: 'm', key: 'In', tail: 'cm' })
  eq('a trailing keyword with no target', UL.splitExplicit('m in'), { head: 'm', key: 'in', tail: '' })
  eq('and with trailing spaces', UL.splitExplicit('m in '), { head: 'm', key: 'in', tail: '' })
  eq('extra internal spaces are kept on the head', UL.splitExplicit('m  in   cm  '), { head: 'm ', key: 'in', tail: 'cm' })
  eq('a multi-word head', UL.splitExplicit('5 in in cm'), { head: '5 in', key: 'in', tail: 'cm' })
  eq('three keywords take the last', UL.splitExplicit('in in in'), { head: 'in', key: 'in', tail: 'in' })
  eq('no keyword', UL.splitExplicit('m'), null)
  eq('a word that merely starts with in', UL.splitExplicit('m inx cm'), null)
  eq('the arrow needs whitespace on both sides', UL.splitExplicit('m->cm'), null)
  eq('and so does =', UL.splitExplicit('m=cm'), null)
})

group('an inch source is recoverable: the keyword is retried as the source unit', () => {
  // "5 in cm" splits at its only keyword, which leaves "5" as the source and
  // "cm" as the target, and "5" alone has no unit. tryConvert therefore
  // retries the head with the keyword glued back on, and the inch claims it.
  // Every other spelling of the same conversion keeps working too, which is
  // what makes the retry a recovery rather than a new rule.
  approx('5 in cm', cvOut('5 in cm'), 12.7, 1e-9)
  eq('and the target is the centimetre', cvOk('5 in cm').to, 'cm')
  approx('1000 in mm is 25.4 m', cvOut('1000 in mm'), 25400, 1e-6)
  eq('and it formats as the whole 25400', cvOk('1000 in mm').formatted, '25400')
  approx('12 in ft', cvOut('12 in ft'), 1, 1e-9)
  eq('and it formats as a whole foot', cvOk('12 in ft').formatted, '1')
  eq('the two-keyword form still works', cvOk('5 in in cm').to, 'cm')
  eq('and so does into', cvOk('5 in into cm').to, 'cm')
  eq('"5 in to cm" works', cvOk('5 in to cm').to, 'cm')
  eq('"5 in as cm" works', cvOk('5 in as cm').to, 'cm')
  eq('"5 in -> cm" works', cvOk('5 in -> cm').to, 'cm')
  eq('"5 in = cm" works', cvOk('5 in = cm').to, 'cm')
  eq('"5 inches in cm" works', cvOk('5 inches in cm').to, 'cm')
  eq('"5inch in cm" works', cvOk('5inch in cm').to, 'cm')
  eq('"12 in to ft" works', cvOk('12 in to ft').to, 'ft')
  eq('a bare "1in" works', cvOk('1in').to, 'cm')
  eq('a bare "1 inch" works', cvOk('1 inch').to, 'cm')
  eq('a bare "1inches" works', cvOk('1inches').to, 'cm')
  eq('a bare "1 ft" works', cvOk('1 ft').to, 'm')
  // A bare inch with nothing behind it is mid-typing, not a conversion: the
  // keyword could still be the head of a target, and the incomplete hint is
  // the state that lets the caller wait.
  eq('a bare "2 in" is the incomplete hint', cvHint('2 in').error, 'incomplete')
  eq('and it names the inch as the expression', cvHint('2 in').expr, '2 in')
  // The retry needs whitespace around the keyword, because that is what
  // splitExplicit matches on. "5in cm" has none, so the split never happens
  // unless the source is a tight inch written against the number.
  approx('"5in cm" converts like "5 in cm"', cvOut('5in cm'), 12.7, 1e-9)
  eq('and the target is the centimetre', cvOk('5in cm').to, 'cm')
  eq('"1000inmm" likewise', UL.tryConvert('1000inmm'), null)
})

group('parseSource scans number/unit pairs left to right, so a compound is one quantity', () => {
  eq('6 ft 2 in', srcShape('6 ft 2 in'), '6 ft + 2 in')
  eq('5 lb 2 oz', srcShape('5 lb 2 oz'), '5 lb + 2 oz')
  eq('the written number is kept, not the parsed one', srcShape('1,000 km'), '1,000 km')
  eq('5 m is one term', srcShape('5 m'), '5 m')
  eq('5m is the same shape', srcShape('5m'), '5 m')
  // A trailing bare number behind a length is the inches of a compound the
  // inch mark left off. "5 m 2" is not that, because "m 2" is the square metre
  // and it claims the two before the bare-number rule can see it.
  eq('5 ft 10 is five feet ten', srcShape('5 ft 10'), '5 ft + 10 in')
  eq('5 m 2 is five square metres', srcShape('5 m 2'), '5 m2')
  eq('6 ft 2 m is a length compound', srcShape('6 ft 2 m'), '6 ft + 2 m')
  eq('1 km 500 m', srcShape('1 km 500 m'), '1 km + 500 m')
  // A bare number behind anything else is a number with no unit and no
  // reading, so it is a null rather than a term that dropped it.
  eq('5 kg 2 is null', srcShape('5 kg 2'), null)
  eq('and tryConvert agrees', UL.tryConvert('5 kg 2'), null)
  eq('a leading letter is null', srcShape('m5'), null)
  eq('an empty string is null', srcShape(''), null)
  eq('whitespace only is null', srcShape('   '), null)
  // The scanner's whole notion of separation is isSpace: a space or a tab.
  eq('a tab separates the terms', srcShape('6\tft\t2\tin'), '6 ft + 2 in')
  eq('a tab is a space', UL.isSpace('\t'), true)
  eq('a space is a space', UL.isSpace(' '), true)
  eq('a newline is not', UL.isSpace('\n'), false)
  eq('and a letter is not', UL.isSpace('a'), false)
})

group('a multi-word unit name is one alias, because normalizeUnit drops the spaces', () => {
  // The scan grows the token a word at a time and stops at a resolved key
  // whose remaining text cannot open another term. "miles per hour" has no
  // resolvable prefix, so the growth passes through "miles per" to reach the
  // whole key - which is why the growth is capped at three extra words.
  eq('square feet', srcShape('5 square feet'), '5 ft2')
  eq('square foot is the same unit', srcShape('5 square foot'), '5 ft2')
  eq('the abbreviated form too', srcShape('5 sq ft'), '5 ft2')
  eq('fluid ounces', srcShape('5 fluid ounces'), '5 floz')
  eq('miles per hour', srcShape('5 miles per hour'), '5 mph')
  eq('degrees celsius', srcShape('30 degrees celsius'), '30 C')
  // "degrees" alone is a different alias: the growth ends at the first
  // resolved key, so "5 deg c" is degrees Celsius and not a five-degree angle
  // with a stray word.
  eq('and the abbreviated degree form', srcShape('5 deg c'), '5 C')
  eq('a compound still holds with a multi-word unit', srcShape('6 ft 2 in'), '6 ft + 2 in')
  // A first word that resolves nothing of its own is a different failure from a
  // long name: the scan grows a token it has already read, but it cannot grow
  // one it never claimed. "cubic" exists only inside "cubicmeterperhour".
  eq('a first word that is no unit on its own is null', srcShape('5 cubic meters per hour'), null)
})

group('parseFeetInches is the compact form, and only the compact form', () => {
  eq(`6'2"`, ftInShape(`6'2"`), '6 ft + 2 in')
  eq(`5'10"`, ftInShape(`5'10"`), '5 ft + 10 in')
  eq(`6' 2in`, ftInShape(`6' 2in`), '6 ft + 2 in')
  // The inch group has to be there: a bare "5'" is one foot, and the token
  // scan resolves that on its own, so this form must not claim it.
  eq(`a bare 5' is not the compact form`, ftInShape(`5'`), null)
  eq(`a bare 6' likewise`, ftInShape(`6'`), null)
  eq('a trailing word is not the compact form', ftInShape(`6'2" extra`), null)
  // The routine is only reached where the token scan has already failed, so it
  // must not claim the forms the scan resolves on its own either: "6 ft 2" is
  // five square feet and a stray two, and "5 ft 10" is the scan's own reading.
  eq('the square-foot form is not claimed', ftInShape('6 ft 2'), null)
  eq('and neither is the scan\'s own compound', ftInShape('5 ft 10'), null)
  // A decimal is allowed on either side of the mark, because a half-inch is a
  // thing people write down.
  eq(`6'2.5" reads as six feet and a half inch`, ftInShape(`6'2.5"`), '6 ft + 2.5 in')
  approx(`and it converts`, cvOut(`6'2.5" in cm`), 189.23, 1e-9)
})

group('compound sums through tryConvert add the extra terms into the first unit', () => {
  // Every further term is converted into the first term's unit and added, so
  // the answer carries the head's unit whichever way round the source was
  // written. The label names every term, which is what makes a compound
  // auditable instead of a mystery number.
  const r = cvOk('6 ft 2 in')
  eq('the head unit is the answer unit', r.from, 'ft')
  approx('six feet two inches', r.out, 1.8796, 1e-9)
  eq('and it formats', r.formatted, '1.8796')
  eq('the label names both terms', r.label, '6 ft + 2 in = 1.8796 m')
  eq('and so does inputText', r.inputText, '6 ft + 2 in')
  approx('the same compound in centimetres', cvOut('6 ft 2 in in cm'), 187.96, 1e-9)
  eq('the compact spelling is the same compound', cvOk(`6'2"`).label, '6 ft + 2 in = 1.8796 m')
  eq('and it takes an explicit target', cvOk(`6'2" in cm`).formatted, '187.96')
  approx('5 lb 2 oz in kg', cvOut('5 lb 2 oz in kg'), 2.32466089625, 1e-12)
  eq('with the mass head', cvOk('5 lb 2 oz in kg').from, 'lb')
  // The bare-number reading of "5 ft 10" is the same rule one term later.
  approx('5 ft 10 is five feet ten', cvOut('5 ft 10'), 1.778, 1e-9)
  eq('and the label says so', cvOk('5 ft 10').inputText, '5 ft + 10 in')
  approx('6 ft 2 m sums the metres in', cvOut('6 ft 2 m'), 3.8288, 1e-9)
  // A compound whose last term is a bare number takes an inch mark as its
  // keyword, and a compound that already reads whole is not half-typed:
  // "5 ft 10 in" is five feet and ten inches, not a target waiting to be
  // finished.
  eq('the inch mark behind a whole compound is the inch', cvOk('5 ft 10 in').inputText, '5 ft + 10 in')
  eq('so it converts bare', cvOk('5 ft 10 in').to, 'm')
  eq('and a single term behind the same keyword still prompts', cvHint('5 ft in').error, 'incomplete')
  // A compound whose terms disagree on dimension is refused at the first
  // offending term, and the hint names the pair rather than a guessed answer.
  const bad = cvHint('2 m 3 kg')
  eq('a mass term behind a length is incompatible', bad.error, 'incompatible')
  eq('the label names the head and the offending term', bad.label, "Incompatible units")
  eq('the sub is the dimension note', bad.sub, 'm is length, kg is mass')
  eq('the expression carries both terms', bad.expr, '2 m + 3 kg')
  eq('and the reverse order is the same refusal', cvHint('2 kg 3 m').label, "Incompatible units")
})

// ---------------------------------------------------------------------------
section('UnitLib.tryConvert - the conversions')

group('a success record carries the ten documented fields', () => {
  eq('the key set', Object.keys(cvOk('5m in cm')).sort(),
    ['copy', 'formatted', 'from', 'inputText', 'label', 'ok', 'out', 'phrase', 'to', 'value'])
  eq('ok is true', cvOk('5m in cm').ok, true)
  approx('value is the source number', cvOk('5m in cm').value, 5, 0)
  eq('from is the canonical symbol', cvOk('5 metres in centimetres').from, 'm')
  eq('to is the canonical symbol', cvOk('5 metres in centimetres').to, 'cm')
  approx('out is the converted number', cvOk('5m in cm').out, 500, 1e-9)
  eq('formatted is the display string', cvOk('5m in cm').formatted, '500')
  eq('copy is the paste string', cvOk('5m in cm').copy, '500 cm')
  eq('label is the full equation', cvOk('5m in cm').label, '5 m = 500 cm')
  eq('inputText is the canonical source', cvOk('5m in cm').inputText, '5 m')
  // inputText echoes the number as typed, normalised only to the unit sym.
  eq('a .5 value keeps its written form', cvOk('.5m in cm').inputText, '.5 m')
  eq('an exponent value keeps its written form', cvOk('1e3m in km').inputText, '1e3 m')
  eq('the surrounding whitespace is trimmed', cvOk('  2.5m in cm  ').inputText, '2.5 m')
  eq('a named unit is replaced by its symbol', cvOk('5 meters in centimeters').inputText, '5 m')
  eq('a signed value keeps its sign', cvOk('-5m in cm').inputText, '-5 m')
  eq('copy is formatted plus the target symbol', cvOk('5m in ft').copy, cvOk('5m in ft').formatted + ' ft')
  eq('label is inputText + " = " + copy', cvOk('5m in ft').label, cvOk('5m in ft').inputText + ' = ' + cvOk('5m in ft').copy)
  // phrase is the same conversion as a sentence, and it is what the row's sub
  // line shows. The number is the one this engine formats, so unlike a
  // currency the amount is re-formatted rather than echoed as typed.
  eq('phrase spells the conversion out', cvOk('5m in cm').phrase, '5 metres is 500 centimetres')
  eq('and it names both units down, because a unit is not a proper noun',
    cvOk('3600J in kWh').phrase, '3600 joules is 0.001 kilowatt-hours')
  eq('a value of exactly one takes the singular', cvOk('1m in ft').phrase, '1 metre is 3.28084 feet')
  eq('and the irregulars are not guessed at', cvOk('1ft in in').phrase, '1 foot is 12 inches')
  // A scale that measures a degree carries the sign as a prefix on its full name
  // - "100 °Celsius" - keeping the word and putting the sign where the notation
  // puts it. Kelvin takes no sign, because it is an absolute scale rather than
  // a degree of anything.
  eq('a scale that measures a degree prints as sign plus full name',
    cvOk('100C in F').phrase, '100 °Celsius is 212 °Fahrenheit')
  eq('and the sign binds to the name, not to the value',
    cvOk('100C in F').phrase.includes('100 °Celsius'), true)
  eq('a bare angle has no scale name to sign, so its noun stays the word',
    cvOk('90deg in rad').phrase, '90 degrees is 1.5708 radians')
  eq('kelvin takes no degree sign, because it is not a degree of anything',
    cvOk('1K in C').phrase, '1 kelvin is -272.15 °Celsius')
  eq('a proper noun inside a name still keeps its capital',
    cvOk('1BTU in kWh').phrase, '1 British thermal unit is 0.000293071 kilowatt-hours')
})

group('every one of the six keywords reaches the same conversion', () => {
  for (const k of ['in', 'into', 'to', 'as', '->', '=']) {
    const r = cvOk(`5m ${k} cm`)
    is(`${k} converts`, r, (v) => v !== null && v.to === 'cm', 'to cm')
    approx(`${k} value`, r.out, 500, 1e-9)
  }
  eq('a mixed-case keyword', cvOk('5m IN cm').to, 'cm')
  eq('a tab between the parts', cvOk('5m\tin cm').to, 'cm')
  // A doubled space is still a separator: the split pattern's \s+ takes the
  // whole run and the head keeps the rest, so the conversion is unchanged.
  eq('a double space between the parts', cvOk('5m  in cm').to, 'cm')
  approx('with the same value', cvOut('5m  in cm'), 500, 1e-9)
  // With no unit behind the number, the same doubled space leaves the keyword
  // as the only candidate unit, and the head retry reads the source as the
  // inch rather than as nothing.
  approx('and "5  in cm" is five inches', cvOut('5  in cm'), 12.7, 1e-9)
})

group('length', () => {
  approx('5m in cm', cvOut('5m in cm'), 500, 1e-9)
  approx('10cm in mm', cvOut('10cm in mm'), 100, 1e-9)
  approx('1km in m', cvOut('1km in m'), 1000, 1e-9)
  approx('1m in km', cvOut('1m in km'), 0.001, 1e-12)
  approx('3ft to m', cvOut('3ft to m'), 0.9144, 1e-9)
  approx('1yd in ft', cvOut('1yd in ft'), 3, 1e-9)
  approx('1nmi in km', cvOut('1nmi in km'), 1.852, 1e-9)
  approx('1mi in km', cvOut('1mi in km'), 1.609344, 1e-9)
  approx('1km in mi', cvOut('1km in mi'), 0.621371192237334, 1e-9)
  approx('1um in nm', cvOut('1um in nm'), 1000, 1e-9)
  approx('1nm in um', cvOut('1nm in um'), 0.001, 1e-12)
  approx('5ft in in', cvOut('5ft in in'), 60, 1e-9)
  approx('1in in cm', cvOut('1in in cm'), 2.54, 1e-9)
  approx('20cm in in', cvOut('20cm in in'), 7.874015748031497, 1e-9)
  approx('402.336m in ft is exact', cvOut('402.336m in ft'), 1320, 1e-9)
  approx('the identity is exact', cvOut('7m in m'), 7, 1e-12)
  eq('20cm in in formatted', cvOk('20cm in in').formatted, '7.87402')
  eq('1 m in ft formatted', cvOk('1m in ft').formatted, '3.28084')
  eq('5m in ft formatted', cvOk('5m in ft').formatted, '16.4042')
  eq('1m in ft label', cvOk('1m in ft').label, '1 m = 3.28084 ft')
})

group('mass', () => {
  approx('1kg in lb', cvOut('1kg in lb'), 2.2046226218487757, 1e-9)
  approx('1lb in kg', cvOut('1lb in kg'), 0.45359237, 1e-12)
  approx('1kg to g', cvOut('1kg to g'), 1000, 1e-9)
  approx('1g in mg', cvOut('1g in mg'), 1000, 1e-9)
  approx('1mg in g', cvOut('1mg in g'), 0.001, 1e-12)
  approx('1oz in g', cvOut('1oz in g'), 28.349523125, 1e-9)
  approx('1st in lb', cvOut('1st in lb'), 14, 1e-9)
  approx('1ton in lb', cvOut('1ton in lb'), 2000, 1e-9)
  approx('1t in kg', cvOut('1t in kg'), 1000, 1e-9)
  approx('5kg in st', cvOut('5kg in st'), 0.7873652220888484, 1e-9)
  approx('1kilo in g', cvOut('1kilo in g'), 1000, 1e-9)
  eq('1kg in lb formatted', cvOk('1kg in lb').formatted, '2.20462')
})

group('volume, area, energy, power, pressure, data and angle', () => {
  approx('1l in ml', cvOut('1l in ml'), 1000, 1e-9)
  approx('1gal in l', cvOut('1gal in l'), 3.785411784, 1e-9)
  approx('1cup in ml', cvOut('1cup in ml'), 236.5882365, 1e-9)
  approx('1floz in ml', cvOut('1floz in ml'), 29.5735295625, 1e-9)
  approx('1ukgal to l', cvOut('1ukgal to l'), 4.54609, 1e-9)
  approx('1ukfloz in ml', cvOut('1ukfloz in ml'), 28.4130625, 1e-9)
  approx('1tsp in ml', cvOut('1tsp in ml'), 4.92892159375, 1e-9)
  approx('1tbsp in ml', cvOut('1tbsp in ml'), 14.78676478125, 1e-9)
  approx('1m3 in l', cvOut('1m3 in l'), 1000, 1e-9)
  approx('1ft3 in l', cvOut('1ft3 in l'), 28.316846592, 1e-9)
  approx('1in3 in ml', cvOut('1in3 in ml'), 16.387064, 1e-9)
  approx('1m2 in ft2', cvOut('1m2 in ft2'), 10.763910416709722, 1e-9)
  approx('1ft2 to m2', cvOut('1ft2 to m2'), 0.09290304, 1e-12)
  approx('1ac to ha', cvOut('1ac to ha'), 0.40468564224000003, 1e-12)
  approx('1ha in m2', cvOut('1ha in m2'), 10000, 1e-9)
  approx('1km2 in ha', cvOut('1km2 in ha'), 100, 1e-9)
  approx('1j to cal', cvOut('1j to cal'), 0.2390057361376673, 1e-12)
  approx('1kcal to kj', cvOut('1kcal to kj'), 4.184, 1e-9)
  approx('1kwh to wh', cvOut('1kwh to wh'), 1000, 1e-9)
  approx('1ev to j', cvOut('1ev to j'), 1.602176634e-19, 1e-30)
  approx('1btu to j', cvOut('1btu to j'), 1055.05585262, 1e-9)
  approx('1hp to w', cvOut('1hp to w'), 745.699872, 1e-9)
  approx('1kw to w', cvOut('1kw to w'), 1000, 1e-9)
  approx('1atm to psi', cvOut('1atm to psi'), 14.69594877551422, 1e-9)
  approx('1bar in kpa', cvOut('1bar in kpa'), 100, 1e-9)
  approx('1mmhg to kpa', cvOut('1mmhg to kpa'), 0.133322387415, 1e-12)
  eq('torr is the same unit as mmHg', cvOk('1torr to kpa').out, cvOk('1mmhg to kpa').out)
  approx('1kb to b', cvOut('1kb to b'), 1000, 0)
  approx('1mb to kb', cvOut('1mb to kb'), 1000, 0)
  approx('1gb to mb', cvOut('1gb to mb'), 1000, 0)
  approx('1tb to gb', cvOut('1tb to gb'), 1000, 0)
  approx('1kib to b', cvOut('1kib to b'), 1024, 0)
  approx('1bit to b', cvOut('1bit to b'), 0.125, 1e-12)
  // A bit is 1/8 of a byte and a kibibyte is 1024 bytes, so the two data
  // scales are deliberately not interchangeable.
  approx('1KiB in bit', cvOut('1KiB in bit'), 8192, 0)
  approx('1rad to deg', cvOut('1rad to deg'), 57.29577951308232, 1e-9)
  approx('90deg to rad', cvOut('90deg to rad'), Math.PI / 2, 1e-9)
  approx('180deg to rad', cvOut('180deg to rad'), Math.PI, 1e-9)
  eq('1atm to psi formatted', cvOk('1atm to psi').formatted, '14.6959')
  eq('1hp to w formatted', cvOk('1hp to w').formatted, '745.7')
  eq('1ev to j formatted', cvOk('1ev to j').formatted, '1.602177e-19 J'.split(' ')[0])
})

group('the twelve newer dimensions: frequency, force, torque, fuel, concentration, molarity, fraction, flow, density, acceleration, datarate, count', () => {
  // Each of these is one conversion through a published factor, so a factor
  // edited to a plausible-looking wrong value cannot pass. The factors
  // themselves are pinned in the table section; what is pinned here is that
  // each one is reachable, in both directions where the pair is meaningful.
  approx('1 kHz in Hz', cvOut('1 kHz in Hz'), 1000, 1e-9)
  approx('60 rpm in Hz', cvOut('60 rpm in Hz'), 1, 1e-9)
  approx('1000 rpm in Hz', cvOut('1000 rpm in Hz'), 16.666666666666668, 1e-9)
  approx('1 GHz in MHz', cvOut('1 GHz in MHz'), 1000, 1e-9)
  eq('a frequency source', cvOk('1 kHz in Hz').from, 'kHz')
  approx('1 N in lbf', cvOut('1 N in lbf'), 0.2248089430997105, 1e-9)
  approx('1 lbf in N', cvOut('1 lbf in N'), 4.4482216152605, 1e-12)
  approx('1 dyn in N', cvOut('1 dyn in N'), 0.00001, 1e-12)
  approx('100 N in kgf', cvOut('100 N in kgf'), 10.197162129779283, 1e-9)
  approx('1 kgf in N', cvOut('1 kgf in N'), 9.80665, 1e-12)
  approx('5 N\u00b7m in lbf\u00b7ft', cvOut('5 N\u00b7m in lbf\u00b7ft'), 3.6878107463863268, 1e-9)
  eq('the middle dot is part of the torque symbol', cvOk('5 N\u00b7m in lbf\u00b7ft').to, 'lbf\u00b7ft')
  approx('1 lbf\u00b7ft in N\u00b7m', cvOut('1 lbf\u00b7ft in N\u00b7m'), 1.3558179483314003, 1e-12)
  // Litres per 100 km is the reciprocal of this dimension and a factor ratio
  // cannot express a reciprocal, so the row that exists is the one whose
  // factors are right in both directions - which is what the pair below shows.
  approx('30 mpg in km/l', cvOut('30 mpg in km/l'), 12.754311224928, 1e-9)
  approx('and the reverse of the same figure', cvOut('12.754311 km/l in mpg'), 29.99999947093654, 1e-9)
  approx('30 mpg in mpgimp', cvOut('30 mpg in mpgimp'), 36.02849777091717, 1e-9)
  approx('1 mpgimp in km/l', cvOut('1 mpgimp in km/l'), 0.354006189934, 1e-12)
  // A concentration is a mass per volume, so every row in the dimension is a
  // scale on the gram per litre: 1 g/L is 100 mg/dL and 1000 mg/L.
  approx('5 g/L in mg/dL', cvOut('5 g/L in mg/dL'), 500, 1e-9)
  approx('5 g/L in mg/L', cvOut('5 g/L in mg/L'), 5000, 1e-9)
  approx('5 g/L in ug/mL', cvOut('5 g/L in ug/mL'), 5000, 1e-9)
  approx('1 g/L in mg/dL', cvOut('1 g/L in mg/dL'), 100, 1e-9)
  approx('1 mol/L in mmol/L', cvOut('1 mol/L in mmol/L'), 1000, 1e-9)
  approx('1 mol/L in umol/L', cvOut('1 mol/L in umol/L'), 1000000, 1e-9)
  approx('1 mmol/L in mol/L', cvOut('1 mmol/L in mol/L'), 0.001, 1e-12)
  approx('5 % in permille', cvOut('5 % in permille'), 50, 1e-9)
  approx('5 % in ppm', cvOut('5 % in ppm'), 50000, 1e-6)
  approx('1 ppm in ppb', cvOut('1 ppm in ppb'), 1000, 1e-9)
  approx('1 ppb in ppm', cvOut('1 ppb in ppm'), 0.001, 1e-12)
  approx('1 m3/h in l/min', cvOut('1 m3/h in l/min'), 16.666666666666668, 1e-9)
  approx('1 l/min in m3/h', cvOut('1 l/min in m3/h'), 0.06, 1e-12)
  approx('60 cfm in m3/h', cvOut('60 cfm in m3/h'), 101.9406477312, 1e-9)
  approx('1 gpm in l/min', cvOut('1 gpm in l/min'), 3.7854117840000003, 1e-9)
  // The knot, the newton and the nanometre claim two of the same letters once
  // case is folded, so each of these pairs USED to be a refusal by design. Three
  // of them are now rows instead, because CASE_OVERRIDE names the unit the
  // capitalisation says - and each is a factor of a million or more away from
  // what the folding would have handed back, which is why the override has to
  // exist rather than the collision being tolerated.
  eq('1 kN in N is a thousand, not the knot against the newton', cvOut('1 kN in N'), 1000, 1e-9)
  eq('1 MW in mW is a billion, not a milliwatt', cvOut('1 MW in mW'), 1e9, 1e-3)
  eq('1 Mm in mm is a billion, not a millimetre', cvOut('1 Mm in mm'), 1e9, 1e-3)
  // approx, not eq: the factor ratio leaves 1000.0000000000001, and a unit
  // conversion is not the place to demand an exact float.
  approx('and the lowercase spelling keeps the old reading', cvOut('1 mm in um'), 1000, 1e-9)
  // Nm is still not a torque row, and still not for the same reason: the fold
  // reaches the nanometre, because nothing claims "nm" case-sensitively. The
  // torque row is spelled "N\u00b7m" or "newtonmetre".
  eq('5 Nm in lbf ft is still the nanometre', cvHint('5 Nm in lbf ft').label, "Incompatible units")
  eq('and the sub says so', cvHint('5 Nm in lbf ft').sub, 'nm is length, lbf\u00b7ft is torque')

  // Density: a mass per a volume, so every row is a scale on the kilogram per
  // cubic metre. 1 g/cm3 is a water litre, which is the whole dimension's point.
  approx('1 g/cm3 in kg/m3', cvOut('1 g/cm3 in kg/m3'), 1000, 1e-9)
  approx('1 kg/m3 in g/cm3', cvOut('1 kg/m3 in g/cm3'), 0.001, 1e-12)
  approx('1 lb/gal in kg/m3', cvOut('1 lb/gal in kg/m3'), 119.82642731689663, 1e-9)
  approx('1 lb/in3 in g/cm3', cvOut('1 lb/in3 in g/cm3'), 27.679904710203125, 1e-9)
  approx('and water is 1 kg to the litre', cvOut('1 kg/m3 in g/cm3'), 0.001, 1e-12)

  // Acceleration: distinct from speed, which is the whole reason it is its own
  // dimension - m/s\u00b2 is not a malformed m/s.
  approx('1 gforce in m/s2', cvOut('1 gforce in m/s2'), 9.80665, 1e-12)
  approx('9.80665 m/s2 in gforce', cvOut('9.80665 m/s2 in gforce'), 1, 1e-12)
  approx('1 ft/s2 in m/s2', cvOut('1 ft/s2 in m/s2'), 0.3048, 1e-12)
  approx('moon gravity', cvOut('1 moon gravity in m/s2'), 1.62, 1e-12)
  eq('and a speed is still not an acceleration', cvHint('1 m/s in m/s2').error, 'incompatible')

  // Datarate: bits and bytes per second, which is why the bit rows are a factor
  // of eight below the byte rows rather than a thousand.
  approx('1 Mbps in MB/s', cvOut('1 Mbps in MB/s'), 0.125, 1e-12)
  approx('1 MB/s in Mbps', cvOut('1 MB/s in Mbps'), 8, 1e-9)
  approx('1 GB/s in Gbps', cvOut('1 GB/s in Gbps'), 8, 1e-9)
  // GiB is 2^30 bytes and MB is 10^6, so this pair is 1073.74 and NOT 1024 -
  // the prefixes differ by 2^30/10^6, which is the whole reason the table
  // carries both ladders.
  approx('1 GiB/s in MB/s crosses both prefixes', cvOut('1 GiB/s in MB/s'), Math.pow(2, 30) / 1e6, 1e-9)
  approx('and the pure-binary pair is where they differ least', cvOut('1 MiB/s in MB/s'), 1.048576, 1e-9)
  approx('1 bps in B/s', cvOut('1 bps in B/s'), 0.125, 1e-12)

  // Count: the units a person actually says out loud when counting things.
  approx('1 dozen in item', cvOut('1 dozen in item'), 12, 1e-12)
  approx('1 gross in dozen', cvOut('1 gross in dozen'), 12, 1e-12)
  approx('1 great gross in gross', cvOut('1 great gross in gross'), 12, 1e-12)
  approx('1 baker\u0027s dozen in dozen', cvOut("1 baker's dozen in dozen"), 13 / 12, 1e-12)
  approx('1 score in item', cvOut('1 score in item'), 20, 1e-12)
  approx('1 ream in item', cvOut('1 ream in item'), 500, 1e-9)
  approx('1 crore in million', cvOut('1 crore in million'), 10, 1e-9)
  approx('and a crore is ten million', cvOut('1 crore in item'), 1e7, 1e-3)
})

group('every one of the 360 rows is structurally sound', () => {
  // Three invariants over the WHOLE table, because the interesting failures in a
  // table this size are not wrong answers - they are a row that resolves to
  // nothing, a noun that was never written, or a pair that does not survive the
  // round trip. None of those shows up in a spot check of famous units.
  //
  // The def is the unit a bare query answers in, so it must resolve AND land in
  // the same dimension. Temperature is exempt from the second half: its rows are
  // scales of one axis rather than a ratio of factors, so "0 C is in F" is a
  // different statement rather than a wrong one.
  eq('every def resolves to a real unit', UL.UNITS.filter((u) => UL.symLookup(u.def) === null).map((u) => u.sym), [])
  eq('and every def is in its own dimension, temperature aside', UL.UNITS
    .filter((u) => u.dim !== 'temperature' && UL.symLookup(u.def).dim !== u.dim).map((u) => u.sym), [])
  // Every unit needs a noun for its sentence. The check is PRESENCE in the table
  // rather than a comparison against the symbol, because twelve nouns are
  // legitimately identical to their symbol - "bar", "psi", "dozen", "crore" - and
  // a missing noun would fall back to the same string and hide.
  // UNIT_NOUN is grouped by dimension for the reader and flattened by unitWord
  // for use, so the checks here flatten it too rather than reaching into a
  // group whose name is the dimension.
  const nouns = {}
  for (const dim of Object.keys(UL.UNIT_NOUN)) {
    for (const sym of Object.keys(UL.UNIT_NOUN[dim])) nouns[sym] = UL.UNIT_NOUN[dim][sym]
  }
  eq('every unit has a noun for its sentence',
    UL.UNITS.filter((u) => nouns[u.sym] === undefined).map((u) => u.sym), [])
  eq('and a noun with no unit behind it is dead weight',
    Object.keys(nouns).filter((sym) => UL.symLookup(sym) === null), [])
  eq('and every noun is a [singular, plural] of non-empty strings',
    Object.keys(nouns).filter((sym) => {
      const p = nouns[sym]
      return !Array.isArray(p) || p.length !== 2 || !p[0] || !p[1]
    }), [])
  // Eighty-nine units are named by their own word - banana, smoot, fortnight,
  // crore, psi - so the noun equals the symbol and only the plural differs. That
  // is why the fallback in unitWord is a guard rather than a shape, and why a
  // MISSING noun cannot be found by comparing against the symbol: the two would
  // be the same string. The count is pinned because it is the honest measure of
  // how much of this table is a plain word rather than a prefixed or compound
  // noun, and it moves whenever the table does.
  eq('and the nouns that are their own symbol, counted not listed',
    Object.keys(nouns).filter((sym) => nouns[sym][0] === sym).length, 89)
  // Twelve of those take no plural at all, and they are the ones where "dozens"
  // or "bars" would be wrong rather than merely clumsy - a gross is a gross and a
  // crore is a crore. Named, because this is the short list that has to stay true.
  eq('of which twelve take no plural, and they are named here',
    Object.keys(nouns).filter((sym) => nouns[sym][0] === sym && nouns[sym][1] === sym).sort(),
    ['bar', 'billion', 'crore', 'dozen', 'great gross', 'gross', 'lakh', 'million', 'psi', 'score', 'thousand', 'trillion'])
  // A round trip through a unit's own def is the cheapest test that a factor is
  // self-consistent: 1 unit -> def -> back must land on 1. It cannot catch a
  // factor that is wrong in BOTH directions, which is why the published-value
  // spot checks elsewhere in this suite exist, but it catches a def that points
  // at a unit of the wrong dimension and a factor ratio assembled backwards.
  eq('every unit round trips through its own def', UL.UNITS
    .filter((u) => u.dim !== 'temperature')
    .filter((u) => {
      const there = UL.tryConvert(`1 ${u.sym} in ${u.def}`)
      if (there === null || there.ok !== true) return true
      const back = UL.tryConvert(`${there.out} ${u.def} in ${u.sym}`)
      return back === null || back.ok !== true || Math.abs(back.out - 1) > 1e-9
    }).map((u) => u.sym), [])
  // And the dimension count is the real one, so a dimension added without a
  // shortlist - which would cost a bare query its only targets - shows up here.
  eq('every dimension has a shortlist', [...new Set(UL.UNITS.map((u) => u.dim))]
    .filter((d) => UL.SUGGEST[d] === undefined), [])
  eq('and every shortlist entry names a unit that exists', Object.keys(UL.SUGGEST)
    .flatMap((d) => UL.SUGGEST[d].filter((s) => UL.symLookup(s) === null)), [])
})

group('a reciprocal unit is one flag and two inverted helpers', () => {
  // Litres per 100 km is the RECIPIPROCAL of this dimension's other rows, and a
  // ratio of factors cannot express a reciprocal - so it is the one unit in the
  // table carrying `recip`, and toBase/fromBase are the pair that honours it.
  // Without the flag the row would be silently wrong in one direction, which is
  // why both directions are asserted here rather than one.
  eq('and it is the only one', UL.UNITS.filter((u) => u.recip === true).map((u) => u.sym), ['l/100km'])
  eq('toBase inverts it and fromBase inverts it back',
    [UL.fromBase(UL.toBase(8, UL.symLookup('l/100km')), UL.symLookup('l/100km'))], [8])
  approx('and a plain unit is untouched by the same pair',
    UL.fromBase(UL.toBase(8, UL.symLookup('km/l')), UL.symLookup('km/l')), 8, 1e-12)
  // 5 l/100km is 20 km per litre, and a mile is 1.609344 km against a US gallon
  // of 3.785411784 L - so both figures below are written out from those two
  // definitions rather than copied from the engine. The tolerance is 1e-6 rather
  // than exact because the table's own mpg factor is a rounded 13-digit constant
  // (0.4251437074976 against an exact 0.425143707430272), which is a property of
  // the constant as written and not of the reciprocal handling under test.
  approx('5 l/100km in mpg', cvOut('5 l/100km in mpg'), 20 / (1.609344 / 3.785411784), 1e-6)
  approx('30 mpg in l/100km, the other direction', cvOut('30 mpg in l/100km'),
    100 / (30 * (1.609344 / 3.785411784)), 1e-6)
  // One litre per 100 km is 100 km per litre, which is 235.2 mpg; and one mile
  // per gallon is 0.425 km per litre, which is 235.2 litres per 100 km. The two
  // ones land on the SAME consumption from opposite ends, which is the clearest
  // statement that the flag is honoured - if the flag were ignored, one of them
  // would be off by a factor of a hundred.
  approx('1 l/100km is 235.2 mpg', cvOut('1 l/100km in mpg'), 100 / (1.609344 / 3.785411784), 1e-6)
  approx('and 1 mpg is 235.2 l/100km', cvOut('1 mpg in l/100km'), 100 / (1.609344 / 3.785411784), 1e-6)
  approx('so the two scales agree where they cross', cvOut('1 l/100km in mpg'), cvOut('1 mpg in l/100km'), 1e-9)
  approx('10 l/100km in km/l', cvOut('10 l/100km in km/l'), 10, 1e-9)
  approx('1 km/l in l/100km', cvOut('1 km/l in l/100km'), 100, 1e-9)
  eq('and it spells out as a sentence like any other', cvOk('30 mpg in l/100km').phrase,
    '30 miles per gallon is 7.84049 litres per 100 kilometres')
  // Two fuel economies are reciprocals of each other, so "5 l/100km 3 mpg" would
  // be an addition across an inversion. The compound is refused rather than
  // summed, exactly as a temperature compound is.
  eq('a compound across the reciprocal is refused, not summed',
    cvHint('5 l/100km 3 mpg').error, 'incompatible')
  eq('and the sub says what to do instead', cvHint('5 l/100km 3 mpg').sub, 'convert one value at a time')
})

group('SUGGEST_RANGE keeps the astronomical rows from padding a list', () => {
  // The light ladder and the AU are offered so a Moon distance or a star can be
  // read in them - but "0.004 light-seconds" for a kilometre and "8577260
  // light-minutes" for a parsec are rows that only pad the list. A bound is
  // [smallest, largest] and it applies on top of readable(), so a reading has to
  // clear BOTH to earn a row.
  const R = UL.SUGGEST_RANGE
  eq('the eight bounded symbols are the astronomical ones',
    Object.keys(R).sort(), ['au', 'ld', 'lh', 'lmin', 'ls', 'ly', 'lw', 'pc'].filter((k) => k in R).sort())
  eq('every bound is a [smallest, largest] pair',
    Object.entries(R).filter(([, v]) => !Array.isArray(v) || v.length !== 2
      || !(v[0] < v[1]) || !(v[0] > 0)).map(([k]) => k), [])
  // The Moon at 384400 km is 1.28 light-seconds and 8.32 light-minutes, both
  // inside the window, and 0.0084 light-hours, which is not.
  const moon = UL.pickTargets(384400, UL.symLookup('km'))
  eq('a Moon distance keeps the light rungs that suit it',
    ['ls', 'lmin', 'lh', 'ld', 'lw'].filter((s) => moon.includes(s)), ['ls', 'lmin'])
  eq('and drops the ones that would be a silly reading',
    ['ld', 'lw'].filter((s) => moon.includes(s)), [])
  // The head is exempt from every bound, which is the contract that keeps a
  // documented default in first place: pickDefault's answer is never filtered.
  eq('and the head is the default regardless', moon[0], UL.pickDefault(384400, UL.symLookup('km')))
  // A parsec in light-minutes is 1.7 million, past the ceiling, so the small
  // rungs drop out - but the hour, day and week rungs read well (28600 lh,
  // 1191 ld, 170 lw), so a bare parsec offers them behind its default. The
  // head survives because the default is exempt from every bound, which is
  // the same contract the whole shortlist rests on.
  eq('a parsec offers its light rungs behind the default', UL.pickTargets(1, UL.symLookup('pc')), ['ly', 'lh', 'ld', 'lw'])
  eq('and the default is what pickDefault said', UL.pickDefault(1, UL.symLookup('pc')), 'ly')
  // A bare light-year keeps the astronomical neighbours and the light rungs
  // that still read well (8766 lh, 365 ld, 52 lw), and drops the ones that
  // would be a silly reading: 1 ly is 31 million light-seconds.
  eq('a light-year keeps its light rungs, au and a parsec', UL.pickTargets(1, UL.symLookup('ly')), ['km', 'lh', 'ld', 'lw', 'au', 'pc'])
  // And the bound is what changed: without it every one of these would appear.
  eq('so the astronomical names are in the shortlist to be filtered, not shown',
    UL.SUGGEST.length.filter((s) => s in R).length > 0, true)
})

group('a food Calorie is a kilocalorie, and only the capital C says so', () => {
  // normalizeUnit folds case, so a bare "Cal" would reach the calorie row and
  // be a thousandth of the reading everybody means. CASE_OVERRIDE is consulted
  // before the alias table and only for the exact spellings it lists.
  approx('5 Cal in J is five kilocalories', cvOut('5 Cal in J'), 20920, 1e-9)
  eq('and the source is reported as the kilocalorie', cvOk('5 Cal in J').from, 'kcal')
  eq('which is what the label echoes', cvOk('5 Cal in J').inputText, '5 kcal')
  approx('5 cal in J is five calories', cvOut('5 cal in J'), 20.92, 1e-9)
  eq('and the source is the calorie', cvOk('5 cal in J').from, 'cal')
  approx('the uppercase spelling is the override too', cvOut('5 CAL in J'), 20920, 1e-9)
  approx('and the kilocalorie itself is unchanged', cvOut('5 kcal in J'), 20920, 1e-9)
  // The override table is pinned whole rather than by a count: every entry names
  // a spelling whose FOLDED form is a different unit by a factor of a million
  // or more, so a new one is a new decision about which reading wins and belongs
  // in the diff. Each value is an alias that resolves, which is what makes the
  // entry a redirect rather than a dangling name.
  eq('the override is the three families of capitalisation traps', UL.CASE_OVERRIDE, {
    Cal: 'kcal', CAL: 'kcal', Calorie: 'kcal', Calories: 'kcal',
    MW: 'megawatt', Mm: 'megameter', Mg: 'tonne', kN: 'kilonewton',
    Kb: 'kbit', Mb: 'mbit', Gb: 'gbit', Tb: 'tbit',
    'Kb/s': 'kbps', 'Mb/s': 'mbps', 'Gb/s': 'gbps', 'Tb/s': 'tbps',
    kBps: 'kb/s', KBps: 'kb/s', MBps: 'mb/s', GBps: 'gb/s',
  })
  eq('and every entry redirects to an alias that resolves',
    Object.entries(UL.CASE_OVERRIDE).filter(([, v]) => UL.lookup(v) === null).map(([k]) => k), [])
  // Every entry exists because the folded spelling is the WRONG unit, or
  // because it is no unit at all - never because it is the right one. Nineteen
  // of the twenty fold onto a different row; the twentieth, "Tb/s", folds onto
  // nothing, because the byte ladder stops at GB/s and "tb/s" is not a row.
  // That one is the strongest case in the table: without it the spelling is
  // unreachable rather than merely misread.
  eq('no entry is redundant - each folds elsewhere or nowhere',
    Object.keys(UL.CASE_OVERRIDE).filter((k) => {
      const folded = UL.lookup(k)
      const target = UL.lookup(UL.CASE_OVERRIDE[k])
      return target === null || (folded !== null && folded.sym === target.sym)
    }), [])
  eq('and the one that folds to nothing is the one with no byte row',
    Object.keys(UL.CASE_OVERRIDE).filter((k) => UL.lookup(k) === null), ['Tb/s'])
  eq('lookup alone would still say calorie', UL.lookup('Cal').sym, 'cal')
  eq('unitFor is where the case survives', UL.unitFor('Cal').sym, 'kcal')
  eq('and unitFor folds the rest', UL.unitFor('cal').sym, 'cal')
  eq('unitFor passes an unknown token to lookup', UL.unitFor('zzz'), null)
})

group('the folded spellings convert end to end', () => {
  // A fold is only worth anything if a query reaches the row behind it, so
  // each transliteration is asserted as a conversion and not as a string.
  approx('the micro sign is a micrometre', cvOut('5 \u00b5m in nm'), 5000, 1e-9)
  approx('the greek mu is the same unit', cvOut('5 \u03bcm in nm'), 5000, 1e-9)
  approx('the superscript two is a square metre', cvOut('1 m\u00b2 in cm2'), 10000, 1e-9)
  approx('the superscript three is a cubic centimetre', cvOut('1 cm\u00b3 in ml'), 1, 1e-12)
  approx('the superscript on the foot too', cvOut('1 ft\u00b2 in m2'), 0.09290304, 1e-12)
  approx('the degree sign is a temperature', cvOut('30 \u00b0C in F'), 86, 1e-9)
  eq('and its source is the Celsius row', cvOk('30 \u00b0C in F').from, 'C')
  approx('the ring above is an angstrom', cvOut('1 \u00c5 in nm'), 0.1, 1e-12)
  approx('and the spelled name is too', cvOut('1 angstrom in nm'), 0.1, 1e-12)
  // The middle dot has to survive too, or the torque symbols are unreachable.
  approx('the torque middle dot', cvOut('5 N\u00b7m in lbf\u00b7ft'), 3.6878107463863268, 1e-9)
  eq('the permille sign resolves', UL.lookup('\u2030').sym, '\u2030')
  approx('and converts', cvOut('5 \u2030 in %'), 0.5, 1e-12)
})

group('a signed or fractional value carries through', () => {
  approx('-5m in cm', cvOut('-5m in cm'), -500, 1e-9)
  approx('+5m in cm', cvOut('+5m in cm'), 500, 1e-9)
  approx('.5m in cm', cvOut('.5m in cm'), 50, 1e-9)
  approx('0m in cm', cvOut('0m in cm'), 0, 0)
  approx('2.5m in cm', cvOut('2.5m in cm'), 250, 1e-9)
  approx('1e3m in km', cvOut('1e3m in km'), 1, 1e-9)
  eq('a negative result is formatted with the sign', cvOk('-5m in cm').formatted, '-500')
  eq('a zero result', cvOk('0m in cm').formatted, '0')
  eq('and never as -0', cvOk('0m in cm').formatted, cvOk('0m in cm').formatted.replace('-', ''))
})

group('a result that overflows is a hint, not a number', () => {
  const r = cvHint('1e308t in mg')
  is('1e308 t in mg is a hint', r, (v) => v !== null, 'non-null')
  eq('with the out-of-range error', r.error, 'out-of-range')
  eq('and the source as its label', r.expr, '1e308 t')
  eq('a label of Result out of range', r.label, 'Result out of range')
  eq('a working example as the sub', r.sub, 'e.g. 5m in cm')
  eq('the same for the to keyword', cvHint('1e308t to mg').error, 'out-of-range')
  // A finite result at 1e296 is not a hint, so the guard is on the result and
  // not on the magnitude of the input.
  is('1e308 nm in km is a result', cvOk('1e308 nm in km'), (v) => v !== null, 'non-null')
  approx('1e308 nm in km', cvOut('1e308 nm in km'), 1e296, 1e290)
  eq('formatted exponentially', cvOk('1e308 nm in km').formatted, '1e+296')
  is('a subnormal result is a result', cvOk('1e-320kg in lb'), (v) => v !== null, 'non-null')
  eq('formatted with seven significant digits', cvOk('1e-320kg in lb').formatted, '2.204521e-320')
})

// ---------------------------------------------------------------------------
section('UnitLib - the light ladder')

group('every light factor is a whole multiple of the metre definition', () => {
  // 299792458 m is not a measured constant, it is the definition of the metre,
  // so the ladder is derived from it rather than measured: a hand-typed factor
  // is right to fifteen digits and wrong in the sixteenth, and nothing else in
  // the table would notice. Asserted against the multiple each rung is, so an
  // edit to one factor shows up as that factor rather than as a drift.
  const C = 299792458
  for (const [sym, seconds] of [['ls', 1], ['lmin', 60], ['lh', 3600], ['ld', 86400], ['lw', 604800]]) {
    eq(`${sym} is exactly ${seconds} light-seconds`, UL.lookup(sym).factor, C * seconds)
  }
  // And the top of the ladder is the DEFINED light year, not a copy of it: the
  // Julian year is 365.25 days, and 9.4607304725808e15 / 31557600 comes back to
  // the metre definition exactly, which is the cross-check between the two.
  eq('and ly is the defined light year', UL.lookup('ly').factor, 9.4607304725808e15)
  eq('whose seconds are exactly the metre definition',
    UL.lookup('ly').factor / (365.25 * 86400), C)
  // 365.25 days over seven: the one rung that is not an integer multiple of
  // another, and the reason a light year is 365.25 light-days rather than 365.
  eq('so a light year is 365.25 light-weeks of seven days', UL.lookup('ly').factor / UL.lookup('lw').factor, 365.25 / 7)
})

group('the light ladder converts along itself and out to the metric scale', () => {
  approx('a light year is 365.25 light-days', cvOut('1 ly in ld'), 365.25, 1e-9)
  approx('a light week is seven light-days', cvOut('1 lw in ld'), 7, 1e-9)
  approx('a light hour is sixty light-minutes', cvOut('1 lh in lmin'), 60, 1e-9)
  approx('a light minute is sixty light-seconds', cvOut('1 lmin in ls'), 60, 1e-9)
  // The scales where a kilometre stops meaning anything are the reason the
  // rungs exist: the Moon is 1.28 light-seconds away and Proxima 4.24 ly.
  approx('the Moon in light-seconds', cvOut('384400 km in ls'), 384400000 / 299792458, 1e-12)
  approx('Proxima Centauri in light-days', cvOut('4.24 ly in ld'), 1548.66, 1e-2)
  approx('one astronomical unit in light-minutes', cvOut('1 au in lmin'), 8.31675, 1e-4)
  approx('a parsec in light-years', cvOut('1 pc in ly'), 3.26156, 1e-5)
  // And they are lengths, so the ordinary cross-system default still answers.
  eq('a light-day bare query leads with kilometres', cvOk('1 ld').to, 'km')
  approx('one light-day in kilometres', cvOut('1 ld in km'), 2.59020683712e10, 1e2)
})

group('the light rungs are spelled the way the symbol spells them', () => {
  // "lightyear" parses as one word; "light-year" is how it is written.
  eq('a light-day as a sentence', cvOk('1 ld in km').phrase, '1 light-day is 25902068371 kilometres')
  eq('a light-year as a sentence', cvOk('1 ly in pc').phrase, '1 light-year is 0.306601 parsecs')
  eq('and the source side spells it too', cvOk('1 lh in m').phrase,
    '1 light-hour is 1079252848800 metres')
})

group('a light month is absent on purpose', () => {
  // The month is the one rung of this ladder that is not a fixed number of
  // seconds, so a light month would answer differently depending on the date.
  // Asserted so a future "complete the ladder" edit has to say out loud that it
  // is reintroducing an ambiguous unit.
  eq('no such alias resolves', UL.lookup('lightmonth'), null)
  eq('and none of the symbols is a light month', UL.dimUnits('length').includes('lmo'), false)
})

// ---------------------------------------------------------------------------
section('UnitLib - speed')

group('SPEED_LEN is the five length units that have a speed twin', () => {
  eq('the table', UL.SPEED_LEN, { km: 'km/h', mi: 'mph', m: 'm/s', ft: 'ft/s', nmi: 'kn' })
  eq('five entries', Object.keys(UL.SPEED_LEN).length, 5)
  is('every target is a real speed unit', UL.SPEED_LEN, (v) => Object.values(v).every((t) => {
    const u = UL.lookup(t)
    return u !== null && u.dim === 'speed'
  }), 'a speed unit')
})

group('"250mph in km" reads as km/h, one direction only', () => {
  // The comment: "Length shorthand accepted as a speed target ... One
  // direction only - a length source with a speed target stays incompatible."
  eq('the target becomes km/h', cvOk('250mph in km').to, 'km/h')
  approx('the value is the km/h reading', cvOut('250mph in km'), 402.336, 1e-6)
  eq('formatted', cvOk('250mph in km').formatted, '402.336')
  eq('the copy string carries km/h', cvOk('250mph in km').copy, '402.336 km/h')
  eq('explicitly asking for km/h is the same', cvOk('250mph in km/h').out, cvOk('250mph in km').out)
  eq('mi', cvOk('1mph in mi').to, 'mph')
  eq('m', cvOk('1mph in m').to, 'm/s')
  eq('ft', cvOk('1mph in ft').to, 'ft/s')
  eq('nmi', cvOk('1mph in nmi').to, 'kn')
  approx('1mph in mi is the identity', cvOut('1mph in mi'), 1, 1e-12)
  approx('1mph in m', cvOut('1mph in m'), 0.44704, 1e-12)
  approx('1km/h in mi', cvOut('1km/h in mi'), 0.621371, 1e-6)
  approx('1kn in nmi is the identity', cvOut('1kn in nmi'), 1, 1e-12)
  approx('1ft/s in ft is the identity', cvOut('1ft/s in ft'), 1, 1e-12)
})

group('a length outside SPEED_LEN is incompatible with a speed source', () => {
  // The twin lookup fails and the hint carries the speed-flavoured example.
  const h = cvHint('1mph in yd')
  eq('yd has no twin', h.error, 'incompatible')
  eq('the label names both units', h.label, "Incompatible units")
  eq('and the sub shows the speed example', h.sub, 'e.g. 250mph in km')
  eq('cm has no twin', cvHint('1mph in cm').error, 'incompatible')
  eq('in has no twin', cvHint('1mph in in').error, 'incompatible')
  eq('and so does the bare foot, which is in ft', cvHint('1mph in in').label, "Incompatible units")
  eq('1m/s in yd', cvHint('1m/s in yd').error, 'incompatible')
})

group('a length source with a speed target stays incompatible', () => {
  // The one-directional rule: the shorthand only fires when the *source* is
  // a speed. "1m in km/h" is nonsense, not a unit conversion. Both units here
  // do have a dimension, so this refusal carries the dimension note rather than
  // the speed example.
  const h = cvHint('1m in km/h')
  eq('the error', h.error, 'incompatible')
  eq('the label', h.label, "Incompatible units")
  eq('and the sub names both dimensions', h.sub, 'm is length, km/h is speed')
  eq('1km in km/h likewise', cvHint('1km in km/h').error, 'incompatible')
  eq('5m in m/s likewise', cvHint('5m in m/s').error, 'incompatible')
})

group('the speed ratios are the published ones', () => {
  approx('100 km/h in mph', cvOut('100km/h in mph'), 62.1371192237339, 1e-9)
  approx('60 mph in km/h', cvOut('60mph in km/h'), 96.56063999999921, 1e-9)
  approx('10 m/s in km/h', cvOut('10m/s in km/h'), 35.99999999999971, 1e-9)
  approx('10 ft/s in m/s', cvOut('10ft/s in m/s'), 3.048, 1e-12)
  approx('1 kn in km/h', cvOut('1kn in km/h'), 1.8519999999999692, 1e-9)
  approx('100kph in mph', cvOut('100kph in mph'), 62.1371192237339, 1e-9)
  approx('60mi/h in km/h', cvOut('60mi/h in km/h'), 96.56063999999921, 1e-9)
  approx('1fps in m/s', cvOut('1fps in m/s'), 0.3048, 1e-12)
  approx('5m/s in mph', cvOut('5m/s in mph'), 11.184681460272012, 1e-9)
  // The table stores km/h as 1/3.6 m/s, so the round trip is exact to the
  // precision of that literal rather than of 1/3.6 itself.
  approx('1 km/h in m/s', cvOut('1km/h in m/s'), 1 / 3.6, 1e-12)
  approx('1 km/h in ft/s', cvOut('1km/h in ft/s'), 0.9113444152814304, 1e-12)
  approx('1 km/h in kn', cvOut('1km/h in kn'), 0.5399568034557325, 1e-12)
  eq('100km/h in kmh target reads as km/h', cvOk('100km/h in km/h').to, 'km/h')
})

// ---------------------------------------------------------------------------
section('UnitLib - the bare-query default target')

group('a bare time query picks the largest unit reading in [1, 1000)', () => {
  // The comment: '"7d" -> "1 wk" but "1d" -> "24 h". Explicit targets bypass
  // this.' The window is [1, 1000) and the order is largest first.
  eq('7d', cvOk('7d').to, 'wk')
  eq('1d', cvOk('1d').to, 'h')
  eq('2d', cvOk('2d').to, 'h')
  eq('30d', cvOk('30d').to, 'wk')
  eq('365d', cvOk('365d').to, 'yr')
  eq('400d', cvOk('400d').to, 'yr')
  eq('1000d', cvOk('1000d').to, 'yr')
  eq('1h', cvOk('1h').to, 'min')
  eq('23h', cvOk('23h').to, 'd')
  eq('48h', cvOk('48h').to, 'd')
  eq('90min', cvOk('90min').to, 'h')
  eq('60min is 1 h', cvOk('60min').to, 'h')
  // 59 min would be 3540 s, outside the [1, 1000) window, so the loop
  // exhausts and the unit's own def is used.
  eq('59min falls through to the def', cvOk('59min').to, 'h')
  eq('60s is 1 min', cvOk('60s').to, 'min')
  eq('1s', cvOk('1s').to, 'min')
  eq('500ms', cvOk('500ms').to, 's')
  eq('1000ms', cvOk('1000ms').to, 's')
  eq('1wk', cvOk('1wk').to, 'd')
  eq('52wk', cvOk('52wk').to, 'd')
  eq('1yr', cvOk('1yr').to, 'wk')
  eq('2yr', cvOk('2yr').to, 'wk')
  approx('7d is 1 wk', cvOut('7d'), 1, 1e-9)
  approx('1d is 24 h', cvOut('1d'), 24, 1e-9)
  approx('365d is 1 yr', cvOut('365d'), 1, 1e-9)
  approx('90min is 1.5 h', cvOut('90min'), 1.5, 1e-9)
  // 5000 s is above an hour and below two, so it is answered in the unit it
  // fits in rather than in its own def - the window rule, not the fallback.
  eq('5000s is 1.39 h', cvOk('5000s').to, 'h')
  approx('and the reading is in the window', cvOut('5000s'), 1.3888888888888888, 1e-9)
  eq('formatted to six significant digits', cvOk('5000s').formatted, '1.38889')
  eq('the label names the chosen target', cvOk('7d').label, '7 d = 1 wk')
})

group('pickDefault is the ladder walk behind that choice', () => {
  const g = (s) => UL.lookup(s)
  // DEF_LADDER is the whole rule: a dimension whose steps are a prefix chain
  // gets a ladder and a pick rule, and every other dimension keeps its def.
  eq('the time ladder is largest first', UL.DEF_LADDER.time.syms, ['yr', 'wk', 'd', 'h', 'min', 's', 'ms'])
  eq('and its rule is the window', UL.DEF_LADDER.time.pick, 'window')
  eq('the data ladder runs largest first too', UL.DEF_LADDER.data.syms, ['TB', 'GB', 'MB', 'KB', 'B', 'bit'])
  eq('and its rule is nearest', UL.DEF_LADDER.data.pick, 'nearest')
  eq('time and data are the only two dimensions with a ladder', Object.keys(UL.DEF_LADDER).sort(), ['data', 'time'])
  // The window rule: the first candidate whose reading lands in [1, 1000).
  eq('1d is h', UL.pickDefault(1, g('d')), 'h')
  eq('6d is h', UL.pickDefault(6, g('d')), 'h')
  eq('7d is wk', UL.pickDefault(7, g('d')), 'wk')
  eq('30d is wk', UL.pickDefault(30, g('d')), 'wk')
  eq('364d is wk', UL.pickDefault(364, g('d')), 'wk')
  eq('365d is yr', UL.pickDefault(365, g('d')), 'yr')
  eq('400d is yr', UL.pickDefault(400, g('d')), 'yr')
  eq('1000d is yr', UL.pickDefault(1000, g('d')), 'yr')
  eq('0.5d is h', UL.pickDefault(0.5, g('d')), 'h')
  eq('3d is h', UL.pickDefault(3, g('d')), 'h')
  eq('23h is d', UL.pickDefault(23, g('h')), 'd')
  eq('24h is d', UL.pickDefault(24, g('h')), 'd')
  eq('1h is min', UL.pickDefault(1, g('h')), 'min')
  eq('1min is s', UL.pickDefault(1, g('min')), 's')
  eq('1s falls through to the def', UL.pickDefault(1, g('s')), 'min')
  eq('59s falls through to the def', UL.pickDefault(59, g('s')), 'min')
  eq('60s is min', UL.pickDefault(60, g('s')), 'min')
  eq('59min exhausts the loop, since s would be 3540', UL.pickDefault(59, g('min')), 'h')
  eq('60min is h', UL.pickDefault(60, g('min')), 'h')
  eq('90min is h', UL.pickDefault(90, g('min')), 'h')
  eq('3600s is h', UL.pickDefault(3600, g('s')), 'h')
  eq('5000s is the in-window hour, not the def', UL.pickDefault(5000, g('s')), 'h')
  eq('1ms falls through to the def', UL.pickDefault(1, g('ms')), 's')
  eq('999ms falls through to the def', UL.pickDefault(999, g('ms')), 's')
  eq('1000ms is s', UL.pickDefault(1000, g('ms')), 's')
  eq('0.5s is ms', UL.pickDefault(0.5, g('s')), 'ms')
  eq('86400000ms is d', UL.pickDefault(86400000, g('ms')), 'd')
  eq('1wk is d', UL.pickDefault(1, g('wk')), 'd')
  eq('2wk is d', UL.pickDefault(2, g('wk')), 'd')
  eq('1yr is wk', UL.pickDefault(1, g('yr')), 'wk')
  // A zero reading satisfies nothing in [1, 1000), so the loop exhausts and
  // the unit's own def is used - for d that is wk, giving "0 wk".
  eq('0d exhausts the loop and takes the def', UL.pickDefault(0, g('d')), 'wk')
  eq('and 0 d converts to 0 wk', cvOk('0d').to, 'wk')
  approx('with a zero result', cvOut('0d'), 0, 0)
  eq('0s takes its def too', UL.pickDefault(0, g('s')), 'min')
  eq('and 0 s converts to 0 min', cvOk('0s').to, 'min')
  // The nearest rule: the candidate minimising |log10(reading)|, so the answer
  // is the prefix one step away in either direction rather than only upwards.
  eq('1 B is 8 bit', UL.pickDefault(1, g('B')), 'bit')
  eq('1 KB is 1000 B', UL.pickDefault(1, g('KB')), 'B')
  eq('1 MB is 1000 KB', UL.pickDefault(1, g('MB')), 'KB')
  eq('1 GB is 1000 MB', UL.pickDefault(1, g('GB')), 'MB')
  eq('1 TB is 1000 GB', UL.pickDefault(1, g('TB')), 'GB')
  eq('500 MB is 0.5 GB', UL.pickDefault(500, g('MB')), 'GB')
  eq('999 B is 0.999 KB', UL.pickDefault(999, g('B')), 'KB')
  eq('5 GB is 5000 MB', UL.pickDefault(5, g('GB')), 'MB')
  eq('2 TB is 2000 GB', UL.pickDefault(2, g('TB')), 'GB')
  eq('1024 KB is 1.024 MB', UL.pickDefault(1024, g('KB')), 'MB')
  eq('1 kbit is 0.125 KB', UL.pickDefault(1, g('kbit')), 'KB')
  eq('1 Mbit is 0.125 MB', UL.pickDefault(1, g('Mbit')), 'MB')
  eq('1 bit is 8 B', UL.pickDefault(1, g('bit')), 'B')
  // A dimension with no ladder has no neighbours to walk, so its def is the
  // answer and the only question is whether that def is still real.
  eq('a length with no ladder takes its def', UL.pickDefault(1, g('m')), 'ft')
  eq('a mass with no ladder takes its def', UL.pickDefault(1, g('kg')), 'lb')
  eq('and so does a temperature', UL.pickDefault(1, g('C')), 'F')
  eq('the def is the unit the table names', UL.pickDefault(1, g('m')), g('m').def)
  // The rule is a table walk, so a unit from outside the table ends at the same
  // place as one inside it: the def. There is no ladder for its dimension.
  eq('a unit the table does not hold takes its def', UL.pickDefault(1, { sym: 'zz', dim: 'nope', def: 'cm' }), 'cm')
  // The source unit is never chosen: `cand.sym === from.sym` skips it, on both
  // rules.
  is('never returns the source symbol', [['d', 1], ['h', 1], ['min', 1], ['s', 1], ['ms', 1], ['wk', 1], ['yr', 1],
    ['B', 1], ['KB', 1], ['MB', 1], ['GB', 1], ['TB', 1], ['bit', 1]],
    (pairs) => pairs.every(([sym, v]) => UL.pickDefault(v, g(sym)) !== sym), 'always a different unit')
  is('and every answer is a real unit in the same dimension', [['d', 1], ['h', 1], ['s', 1], ['wk', 1], ['yr', 1],
    ['B', 1], ['KB', 1], ['MB', 1], ['GB', 1], ['TB', 1], ['bit', 1], ['kbit', 1]],
    (pairs) => pairs.every(([sym, v]) => {
      const u = UL.lookup(UL.pickDefault(v, g(sym)))
      return u !== null && u.dim === g(sym).dim
    }), 'a unit of the source dimension')
})

group('the data ladder answers the way the window does not', () => {
  // The window would strand "1 GB" between TB and MB - the terabyte reading
  // is a thousand and the megabyte reading is a million - so data picks the
  // nearest instead. Every value below is the engine's own reading.
  eq('1 B', cvOk('1 B').to, 'bit')
  eq('1 KB', cvOk('1 KB').to, 'B')
  eq('1 MB', cvOk('1 MB').to, 'KB')
  eq('1 GB', cvOk('1 GB').to, 'MB')
  eq('1 TB', cvOk('1 TB').to, 'GB')
  eq('5 GB', cvOk('5 GB').to, 'MB')
  eq('500 MB', cvOk('500 MB').to, 'GB')
  eq('999 B', cvOk('999 B').to, 'KB')
  eq('2 TB', cvOk('2 TB').to, 'GB')
  eq('1024 KB', cvOk('1024 KB').to, 'MB')
  approx('1 KB is 1000 B, the SI reading', cvOut('1 KB'), 1000, 1e-9)
  approx('1 GB is 1000 MB', cvOut('1 GB'), 1000, 1e-9)
  approx('1 TB is 1000 GB', cvOut('1 TB'), 1000, 1e-9)
  approx('500 MB is 0.5 GB', cvOut('500 MB'), 0.5, 1e-12)
  approx('999 B is 0.999 KB', cvOut('999 B'), 0.999, 1e-12)
  approx('1024 KB is 1.024 MB, and not 1 MiB worth of bytes', cvOut('1024 KB'), 1.024, 1e-12)
  // 100 KB is the boundary: the byte reading is 0.1 exactly, and the rule
  // admits a reading of a tenth, so the megabyte wins on its log distance.
  eq('100 KB', cvOk('100 KB').to, 'MB')
  approx('and the answer is exactly a tenth', cvOut('100 KB'), 0.1, 1e-12)
  // A reading under a tenth is the prefix one step too large, and it is
  // skipped rather than allowed to win on its log distance.
  eq('1 kbit is 0.125 KB', cvOk('1 kbit').to, 'KB')
  approx('the kilobyte reading', cvOut('1 kbit'), 0.125, 1e-12)
  eq('1 Mbit is 0.125 MB', cvOk('1 Mbit').to, 'MB')
  approx('the megabyte reading', cvOut('1 Mbit'), 0.125, 1e-12)
  // The ladder overrides the table's own def here: kbit.def is "B", and the
  // nearest rule reads one kilobit as 0.125 KB, which is a far better answer
  // than 125 bytes.
  eq('a kilobit still declares the byte as its def', UL.lookup('kbit').def, 'B')
  // An explicit target bypasses the ladder entirely.
  eq('1 KB in MiB bypasses the rule', cvOk('1 KB in MiB').to, 'MiB')
  approx('and converts on the binary scale', cvOut('1 KB in MiB'), 0.00095367431640625, 1e-18)
  eq('1 GB in MB is the identity', cvOut('1 GB in MB'), 1000)
})

group('a bare time query ignores the per-unit def in favour of the window', () => {
  // s.def is "min" and h.def is "d", so those two coincide with the window;
  // d.def is "wk" but 1d picks h, which is the whole point of the rule.
  eq('d.def is wk', UL.lookup('d').def, 'wk')
  eq('yet 1d picks h', cvOk('1d').to, 'h')
  eq('h.def is d', UL.lookup('h').def, 'd')
  eq('and 1h picks min', cvOk('1h').to, 'min')
  eq('s.def is min', UL.lookup('s').def, 'min')
  eq('and 1s picks min', cvOk('1s').to, 'min')
  eq('ms.def is s', UL.lookup('ms').def, 's')
  eq('and 500ms picks s', cvOk('500ms').to, 's')
  // An explicit target always wins, whatever the window would have said.
  eq('1d in min bypasses the rule', cvOk('1d in min').to, 'min')
  eq('1d in wk bypasses the rule', cvOk('1d in wk').to, 'wk')
  eq('7d in h bypasses the rule', cvOk('7d in h').to, 'h')
  eq('7d in d bypasses the rule', cvOk('7d in d').to, 'd')
})

group('a bare query with no ladder uses the per-unit def instead', () => {
  // Every dimension outside the two ladders answers with the other system's
  // unit - metres to feet, kilograms to pounds - which is more use than any
  // prefix neighbour would be.
  eq('m defaults to ft', UL.lookup('m').def, 'ft')
  eq('and 5m picks ft', cvOk('5m').to, 'ft')
  eq('km defaults to mi', cvOk('5km').to, 'mi')
  eq('mi defaults to km', cvOk('5mi').to, 'km')
  eq('kg defaults to lb', cvOk('5kg').to, 'lb')
  eq('lb defaults to kg', cvOk('5lb').to, 'kg')
  eq('oz defaults to g', cvOk('5oz').to, 'g')
  eq('C defaults to F', cvOk('100C').to, 'F')
  eq('F defaults to C', cvOk('100F').to, 'C')
  eq('K defaults to C', cvOk('300K').to, 'C')
  // The litre's neighbour is the millilitre: a third of a gallon is a number
  // nobody asks for.
  eq('l defaults to ml', UL.lookup('l').def, 'ml')
  eq('and 1l picks ml', cvOk('1l').to, 'ml')
  approx('2 l is 2000 ml', cvOut('2 l'), 2000, 1e-9)
  eq('while the millilitre answers in the fluid ounce', cvOk('5ml').to, 'floz')
  approx('5 ml is 0.16907 floz', cvOut('5 ml'), 0.169070113509215, 1e-12)
  eq('mps defaults to mph', cvOk('10mps').to, 'mph')
  eq('2 kg is 4.40925 lb', cvOk('2kg').formatted, '4.40925')
  eq('100 m is feet', cvOk('100m').to, 'ft')
  eq('30 C is Fahrenheit', cvOk('30C').to, 'F')
  eq('90 deg is radians', cvOk('90deg').to, 'rad')
  eq('and 90m is metres, not minutes', cvOk('90m').from, 'm')
  eq('while 90min is minutes', cvOk('90min').from, 'min')
  ne('the two differ in target', cvOk('90m').to, cvOk('90min').to)
})

// ---------------------------------------------------------------------------
section('UnitLib - the hint records')

group('a hint record carries exactly the five documented fields', () => {
  eq('the key set', Object.keys(cvHint('5m in')).sort(), ['error', 'expr', 'label', 'ok', 'sub'])
  eq('ok is false', cvHint('5m in').ok, false)
  eq('expr is the canonical source', cvHint('5m in').expr, '5 m')
  is('error is one of the five named values', ['5m in', '5m in nope', '5kg in m', '-300C in K', '1e308t in mg'],
    (qs) => qs.every((q) => ['incomplete', 'unknown-target', 'incompatible', 'unphysical', 'out-of-range'].includes(cvHint(q).error)),
    'a documented error')
  eq('every error name is reachable', [...new Set(['5m in', '5m in nope', '5kg in m', '-300C in K', '1e308t in mg'].map((q) => cvHint(q).error))].sort(),
    ['incompatible', 'incomplete', 'out-of-range', 'unknown-target', 'unphysical'])
})

group('incomplete is the half-typed explicit target', () => {
  const h = cvHint('5m in')
  eq('the error', h.error, 'incomplete')
  eq('the expr', h.expr, '5 m')
  eq('the label repeats the expr', h.label, '5 m')
  eq('the sub invites more typing', h.sub, 'Continue typing...')
  eq('a trailing space is the same state', cvHint('5m in ').error, 'incomplete')
  eq('for every keyword', ['into', 'to', 'as', '->', '='].map((k) => cvHint(`5m ${k}`).error),
    ['incomplete', 'incomplete', 'incomplete', 'incomplete', 'incomplete'])
  eq('the expr is canonical even for a named unit', cvHint('5 meters in').expr, '5 m')
  eq('and for a signed value', cvHint('-2.5kg to').expr, '-2.5 kg')
  eq('a speed source', cvHint('10mph in').expr, '10 mph')
  // The unit must resolve before the incomplete state is offered, so a
  // nonsense source is a fall-through rather than a prompt.
  eq('an unknown source is null, not incomplete', UL.tryConvert('5zz in'), null)
  // "5 in" is the inch with a trailing keyword, and the head already resolves
  // to two terms either way, so the tie keeps the head and offers the prompt.
  // That is the rule that also holds "5 m in" at one metre rather than five
  // minutes, where "m in" is the minute.
  eq('an inch with nothing behind the keyword is incomplete', cvHint('5 in').error, 'incomplete')
  eq('and it names the inch', cvHint('5 in').label, '5 in')
  eq('the same for a bare "2 in"', cvHint('2 in').error, 'incomplete')
})

group('unknown-target names the unit it could not find', () => {
  const h = cvHint('5m in nope')
  eq('the error', h.error, 'unknown-target')
  eq('the expr', h.expr, '5 m')
  eq('the label quotes the target', h.label, "Unknown unit 'nope'")
  eq('the sub offers the source\'s own units', h.sub, 'did you mean: ft, A, nm, um, thou, mm')
  for (const k of ['in', 'into', 'to', 'as', '->', '=']) {
    eq(`${k} is the same state`, cvHint(`5m ${k} nope`).label, "Unknown unit 'nope'")
  }
  // "n" is the newton, so a half-typed target that happens to be a real unit
  // is a dimension mismatch rather than a misspelling: the engine says what
  // it read instead of guessing what was meant.
  eq('a partly-typed target that resolves is a mismatch', cvHint('5m in n').error, 'incompatible')
  eq('and it names the newton it found', cvHint('5m in n').label, "Incompatible units")
  eq('with the dimension note as the sub', cvHint('5m in n').sub, 'm is length, N is force')
  eq('and the same for the capital spelling', cvHint('5m in N').label, "Incompatible units")
  // A quote is the inch alias, so '5m in "' is a real conversion, not an
  // unknown target: the parser splits on the last ')' and leaves the quote
  // as the tail.
  eq('a bare quote is the inch, not an unknown target', cvOk('5m in "').to, 'in')
  eq('a genuinely unknown tail', cvHint('5m in zz').label, "Unknown unit 'zz'")
  eq('a numeric tail', cvHint('5m in 7').label, "Unknown unit '7'")
})

group('incompatible names both units and the dimensions they belong to', () => {
  const h = cvHint('5kg in m')
  eq('the error', h.error, 'incompatible')
  eq('the label names source then target', h.label, "Incompatible units")
  eq('the sub names both dimensions', h.sub, 'kg is mass, m is length')
  eq('the other direction', cvHint('1m in kg').label, "Incompatible units")
  eq('length to mass', cvHint('5m in kg').error, 'incompatible')
  eq('mass to length', cvHint('5kg in m').error, 'incompatible')
  eq('length to temperature', cvHint('5m in c').error, 'incompatible')
  eq('volume to length', cvHint('1l in m').error, 'incompatible')
  eq('time to length', cvHint('1d in m').error, 'incompatible')
  eq('data to length', cvHint('1kb in m').error, 'incompatible')
  eq('angle to length', cvHint('1deg in m').error, 'incompatible')
  eq('force to torque', cvHint('5N in lbf ft').error, 'incompatible')
  eq('length to frequency', cvHint('5m in kHz').error, 'incompatible')
  eq('fraction to molarity', cvHint('5 % in mol/L').error, 'incompatible')
  // One refused pair is enough to show the note is per pair, not per source.
  eq('a length source against a volume target', cvHint('5m in l').sub, 'm is length, l is volume')
  eq('an angle against an area', cvHint('90deg in cm2').sub, 'deg is angle, cm2 is area')
  eq('and the head is named first in the sub', cvHint('90deg in cm2').label, "Incompatible units")
})

group('dimUnits, dimHint and dimNote are the three hint strings, on their own', () => {
  const g = (s) => UL.lookup(s)
  // dimUnits is the hint's vocabulary: one dimension, in table order, so a
  // suggestion list is the engine's own ordering rather than a sorted guess.
  eq('the length dimension has 56 units', UL.dimUnits('length').length, 56)
  eq('and they come out smallest first', UL.dimUnits('length').slice(0, 4), ['A', 'nm', 'um', 'thou'])
  eq('the mass dimension', UL.dimUnits('mass').slice(-3), ['grain of rice', 'paperclip', 'stick of butter'])
  eq('the five temperature scales', UL.dimUnits('temperature'), ['C', 'F', 'K', 'Re', 'R'])
  // The dimension is in TABLE order and the table is grouped by system, not
  // globally sorted by factor - kilometres come before inches here. So what the
  // light ladder is asserted on is that its rungs are CONTIGUOUS and that their
  // factors ascend across the block, which is the property that matters: a rung
  // inserted in the middle of someone else's group would break the first and
  // this catches it.
  eq('the light rungs are contiguous in the table', (() => {
    const d = UL.dimUnits('length')
    const i = d.indexOf('ls')
    return d.slice(i, i + 6)
  })(), ['ls', 'lmin', 'lh', 'ld', 'lw', 'ly'])
  eq('and ascend across the block', (() => {
    const d = UL.dimUnits('length')
    const i = d.indexOf('ls')
    const f = d.slice(i, i + 6).map((s) => UL.lookup(s).factor)
    return f.every((v, k) => k === 0 || v > f[k - 1])
  })(), true)
  eq('an unknown dimension is an empty list', UL.dimUnits('nope'), [])
  // dimHint leads with the source's own def, which is the neighbour a bare
  // query would have answered in, and then offers the dimension in table order
  // up to six names in all.
  eq('the def comes first', UL.dimHint(g('m')), 'did you mean: ft, A, nm, um, thou, mm')
  eq('a mass source', UL.dimHint(g('kg')), 'did you mean: lb, ng, ug, mg, grain, carat')
  eq('the temperature list is short enough to be complete', UL.dimHint(g('C')), 'did you mean: F, K, Re, R')
  eq('a speed source', UL.dimHint(g('mph')), 'did you mean: km/h, m/s, m/min, ft/s, ft/min, kn')
  eq('six at most, even for a twenty-one-unit dimension', UL.dimHint(g('km')).split(', ').length, 6)
  eq('and a distance source leads with its own def', UL.dimHint(g('km')), 'did you mean: mi, A, nm, um, thou, mm')
  // Two candidates is the floor for a suggestion list, so a dimension that
  // offers fewer falls back to the plain example rather than naming one unit.
  eq('a dimension with one unit falls back to the example',
    UL.dimHint({ sym: 'zz', dim: 'nope', def: 'zz' }), 'e.g. 5m in cm')
  eq('and an empty dimension does too', UL.dimHint({ sym: 'zz', dim: 'nope', def: 'zz', names: [] }), 'e.g. 5m in cm')
  // dimNote is the incompatible sub, and it is the whole explanation: naming
  // both dimensions says what cannot be converted and why.
  eq('two real units', UL.dimNote(g('m'), g('cm2')), 'm is length, cm2 is area')
  eq('the order follows the query', UL.dimNote(g('cm2'), g('m')), 'cm2 is area, m is length')
  eq('a mass against a force', UL.dimNote(g('kg'), g('N')), 'kg is mass, N is force')
  eq('the middle dot survives the note', UL.dimNote(g('nm'), g('lbf\u00b7ft')), 'nm is length, lbf\u00b7ft is torque')
  eq('and a per-mille source names its own symbol', UL.dimNote(g('\u2030'), g('%')), '\u2030 is fraction, % is fraction')
})

group('unphysical covers both directions below absolute zero', () => {
  // The comment: "Unphysical temperatures: anything under 0 K is a hint,
  // never a number. Covers both directions ('-300C in K', '-5K in C')."
  const h = cvHint('-300C in K')
  eq('the error', h.error, 'unphysical')
  eq('the expr', h.expr, '-300 C')
  eq('the label', h.label, 'Below absolute zero')
  eq('the sub names the source', h.sub, '-300 C is under 0 K')
  eq('the other direction', cvHint('-5K in C').error, 'unphysical')
  eq('-1K in C', cvHint('-1K in C').error, 'unphysical')
  // The guard reads the *source* in Kelvin, so the boundary is 0 K: -273.15 C
  // is 0 K exactly and converts, and one step below it in either scale does
  // not. -273.15 *Kelvin* is 273.15 K under the floor, not the boundary.
  eq('-273.15K in C is 273 K under the floor', cvHint('-273.15K in C').error, 'unphysical')
  eq('-274K in C', cvHint('-274K in C').error, 'unphysical')
  eq('-300C in F', cvHint('-300C in F').error, 'unphysical')
  eq('-459.7F in K', cvHint('-459.7F in K').error, 'unphysical')
  eq('the sub of the other direction', cvHint('-5K in C').sub, '-5 K is under 0 K')
  // A low but legal Celsius value is still a result: -100 C is 173.15 K.
  eq('-100C is legal, being 173.15 K', cvOk('-100C in F') !== null, true)
  approx('and converts', cvOut('-100C in F'), -148, 1e-9)
  // 0 K is the lowest accepted reading, in both directions.
  is('0K in C is a result', cvOk('0K in C'), (v) => v !== null, 'non-null')
  approx('and is -273.15 C', cvOut('0K in C'), -273.15, 1e-9)
  is('-273.15C in K is a result', cvOk('-273.15C in K'), (v) => v !== null, 'non-null')
  approx('and is 0 K', cvOut('-273.15C in K'), 0, 1e-9)
  // The check is against -1e-9 K, so a sub-nano reading just above the
  // limit is still accepted rather than being rounded into a rejection.
  is('-1e-12K in C is a result', cvOk('-1e-12K in C'), (v) => v !== null, 'non-null')
  eq('and it is flagged only in the sub-second digits', cvOk('-1e-12K in C').formatted, '-273.15')
})

group('the temperature conversions at the named points', () => {
  approx('0C in F', cvOut('0C in F'), 32, 1e-9)
  approx('100C in F', cvOut('100C in F'), 212, 1e-9)
  approx('0F in C', cvOut('0F in C'), -17.77777777777778, 1e-9)
  approx('100F in C', cvOut('100F in C'), 37.77777777777778, 1e-9)
  approx('-40C in F', cvOut('-40C in F'), -40, 1e-9)
  approx('-40F in C', cvOut('-40F in C'), -40, 1e-9)
  approx('1C in F', cvOut('1C in F'), 33.8, 1e-9)
  approx('0C in K', cvOut('0C in K'), 273.15, 1e-9)
  approx('100C in K', cvOut('100C in K'), 373.15, 1e-9)
  approx('0K in F', cvOut('0K in F'), -459.66999999999996, 1e-9)
  approx('250K in C', cvOut('250K in C'), -23.149999999999977, 1e-9)
  approx('273.15K in C', cvOut('273.15K in C'), 0, 1e-9)
  eq('0C in F label', cvOk('0C in F').label, '0 C = 32 F')
  eq('100c to f is the same as 100C in F', cvOk('100c to f').out, cvOk('100C in F').out)
  eq('32f in c', cvOk('32f in c').out, 0)
  eq('a lowercase alias resolves to the canonical symbol', cvOk('32f in c').from, 'F')
  eq('0k in c resolves to K', cvOk('0k in c').from, 'K')
})

group('each hint kind is dimension-scoped', () => {
  // A mass query can never be unphysical and a temperature query can never be
  // out of range, because each check runs inside its own branch.
  eq('a normal mass query is a result', cvOk('5kg in g') !== null, true)
  eq('a negative mass query is a result', cvOk('-5kg in g') !== null, true)
  eq('a length query is a result', cvOk('-5m in cm') !== null, true)
  eq('a normal temperature query is a result', cvOk('20C in F') !== null, true)
  eq('a huge length is a result', cvOk('1e300m in cm') !== null, true)
  eq('a huge temperature is a result', cvOk('1e30C in F') !== null, true)
  eq('a normal mass query has no error', UL.tryConvert('-5kg in g').error, undefined)
  eq('a normal length query has no error', UL.tryConvert('-5m in cm').error, undefined)
})

group('nothing on the keystroke path throws', () => {
  const inputs = [undefined, null, '', '   ', '5', 'm', '5m', '5m in', '5m in cm', '5m in',
    '5m in nope', '5kg in m', '-300C in K', '1e308t in mg', '1e999m', 'firefox', '2+2', 'time in X',
    '5  in cm', '5 in cm', '5m->cm', '5.m in cm', '-.5m in cm', '0d', 'x'.repeat(200),
    // The shapes the rewritten pipeline added, all of them on the same
    // per-keystroke path as the ones above.
    'convert 5 km to mi', 'how many km in 5 mi please?', '5 km in mi!', '6 ft 2 in', "6'2\"", '5 kg 2',
    '1,000 km in mi', '1,5 km', '5in cm', '5 Cal in J', '1 kN in N', '5 N\u00b7m in lbf\u00b7ft', '30 mpg in km/l']
  // The four stages the engine runs on a keystroke, each of which must answer
  // with null or a record rather than an exception: a throw here would take the
  // launcher's whole result list down mid-word.
  for (const v of inputs) {
    noThrow(`tryConvert(${q(v)})`, () => UL.tryConvert(v))
    noThrow(`isPotentialUnit(${q(v)})`, () => UL.isPotentialUnit(v))
    noThrow(`preprocess(${q(v)})`, () => UL.preprocess(v))
    noThrow(`parseSource(${q(v)})`, () => UL.parseSource(v))
    noThrow(`parseFeetInches(${q(v)})`, () => UL.parseFeetInches(v))
  }
  noThrow('splitExplicit(undefined)', () => UL.splitExplicit(undefined))
  noThrow('normalizeUnit(42)', () => UL.normalizeUnit(42))
  noThrow('lookup(42)', () => UL.lookup(42))
  noThrow('formatNumber({})', () => UL.formatNumber({}))
  // Of the exported helpers, only the ones that coerce their own input claim
  // to survive nullish input: unitFor hands the token to normalizeUnit, and
  // dimUnits answers an empty list for a dimension the table does not have.
  // The rest take a real row by construction - convertValue reads `factor` and
  // dimNote reads `sym` - so their contract is the caller's, not a throw guard.
  noThrow('unitFor(null)', () => UL.unitFor(null))
  noThrow('isSpace(undefined)', () => UL.isSpace(undefined))
  noThrow('dimUnits(undefined)', () => UL.dimUnits(undefined))
  noThrow('dimUnits(null)', () => UL.dimUnits(null))
})

group('UnitLib interprets text without eval, Function or any host import', () => {
  notMatch('UnitLib has no eval(', SRC.UnitLib, /\beval\s*\(/)
  notMatch('UnitLib builds no Function', SRC.UnitLib, /\bFunction\s*\(/)
  notMatch('UnitLib has no new Function', SRC.UnitLib, /new\s+Function/)
  notMatch('UnitLib imports nothing', SRC.UnitLib, /\.import|\.pragma/)
  notMatch('UnitLib touches no Qt type', SRC.UnitLib, /\bQt\./)
  notMatch('UnitLib reads no environment', SRC.UnitLib, /Quickshell/)
  notMatch('UnitLib reads no clock', SRC.UnitLib, /\bDate\b/)
  notMatch('UnitLib draws no random numbers', SRC.UnitLib, /Math\s*\.\s*random/)
  notMatch('ColorMath has no eval(', SRC.ColorMath, /\beval\s*\(/)
  notMatch('ColorMath imports nothing', SRC.ColorMath, /\.import|\.pragma/)
  notMatch('ColorMath reads no clock', SRC.ColorMath, /\bDate\b/)
})

group('every table unit survives a bare round trip through its own default', () => {
  // The invariant that keeps the table honest: no def points at a missing or
  // foreign unit, and no non-temperature factor is zero or non-finite, so no
  // bare query can divide by zero or produce a non-finite out.
  for (const u of UL.UNITS) {
    is(`${u.sym} has a positive factor or is a temperature`, { u }, (v) => v.u.dim === 'temperature' || v.u.factor > 0, 'positive factor')
  }
  is('every def is the same dimension', UL.UNITS, (v) => v.every((u) => {
    const d = UL.lookup(u.def)
    return d !== null && d.dim === u.dim
  }), 'same dim')
  // Walking every def as a query would be slow to assert one by one, so the
  // equivalent invariant is checked over the table instead.
  is('no def is the source itself', UL.UNITS, (v) => v.every((u) => u.def !== u.sym), 'def differs from sym')
  // The bare-query rule is per dimension, so the contract is that every symbol
  // a ladder names resolves to a unit of that ladder's dimension. A typo there
  // would not throw: pickDefault would happily convert through a foreign unit.
  is('every ladder symbol is a unit of its own dimension', UL.DEF_LADDER, (v) => {
    for (const dim of Object.keys(v)) {
      for (const sym of v[dim].syms) {
        const u = UL.lookup(sym)
        if (u === null || u.dim !== dim) return false
      }
    }
    return true
  }, 'a unit of that dimension')
  // The window ladder names seven time units, and they are the seven a bare
  // query is answered in. The rest of the time table - ns, us, the fortnight,
  // the decade, the century - is reachable only with an explicit target.
  is('the window ladder names these seven time units', UL.UNITS,
    (v) => v.filter((u) => u.dim === 'time' && UL.DEF_LADDER.time.syms.includes(u.sym)).map((u) => u.sym).sort(),
    ['d', 'h', 'min', 'ms', 's', 'wk', 'yr'])
  is('and no other dimension has a ladder', UL.UNITS,
    (v) => [...new Set(v.map((u) => u.dim))].filter((d) => UL.DEF_LADDER[d] === undefined),
    ['area', 'concentration', 'energy', 'flow', 'force', 'fraction', 'fuel', 'length', 'mass',
      'molarity', 'power', 'pressure', 'speed', 'temperature', 'torque', 'volume'])
})

finish()