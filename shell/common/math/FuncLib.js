// Shared function-of-x engine for the live launcher graph + static clipboard
// preview. Pure-JS, deterministic, no Qt imports - unit-drivable like
// CalcLib.js (node vm hosts it the same way QJSEngine does).
//
// A "real functional function" here means: single-line y = f(x) that
// actually evaluates across a domain - not just syntactically plausible.
//   tryParseFunction("x^2")        -> { expr, body, rpn }
//   tryParseFunction("y = sin(x)") -> { expr:"sin(x)", ... }
//   tryParseFunction("2+2")        -> null (no variable)
//   tryParseFunction("x+")         -> null (incomplete)
//   tryParseFunction("x chat")     -> null (unknown word, NOT incomplete)
//
// tryParseFunction accepts a lone variable ("x" is y=x, valid). Callers
// that plot additionally require a real expression - an operator or a
// function application around the variable - so a bare "x" (or "(x)",
// "-x") stays an app search instead of a diagonal line.
//
// Supported syntax (case-insensitive):
//   variable: x
//   operators: + - * / % ^ parentheses, decimals, unary +/-
//   functions (single-arg, parens required):
//     sin cos tan asin acos atan sinh cosh tanh
//     sqrt cbrt abs exp ln log floor ceil round
//     log  = base-10, ln = natural log
//   constants: pi e tau
//   implicit multiplication: 2x, 2sin(x), x(x+1), 2(x+1), )(
//   prefixes (stripped for display): y=, f(x)=, y(x)=, plot, graph
//   trailing '=' stripped like CalcLib ("x^2=" -> "x^2")//
// Implicit-mult + scientific-notation edge: "1e6" parses as 1000000
// (exponent wins over the `e` constant); bare "2e" means 2*e.
.pragma library

var FUNCS = {
    "sin": true, "cos": true, "tan": true,
    "asin": true, "acos": true, "atan": true,
    "sinh": true, "cosh": true, "tanh": true,
    "sqrt": true, "cbrt": true, "abs": true,
    "exp": true, "ln": true, "log": true,
    "floor": true, "ceil": true, "round": true
}

// Strip UI prefixes + trailing '=' down to the plottable body.
// Returns "" when nothing plottable remains.
function stripBody(query) {
    var s = String(query || "").trim()
    if (s === "") return ""
    s = s.replace(/\s*=+\s*$/, "").trim()
    if (s === "") return ""
    var m = null
    // f(x) = <body>
    m = s.match(/^f\s*\(\s*x\s*\)\s*=\s*(.+)$/i)
    if (m) return String(m[1]).trim()
    // y(x) = <body>
    m = s.match(/^y\s*\(\s*x\s*\)\s*=\s*(.+)$/i)
    if (m) return String(m[1]).trim()
    // y = <body>
    m = s.match(/^y\s*=\s*(.+)$/i)
    if (m) return String(m[1]).trim()
    // plot <body> / graph <body>
    m = s.match(/^(?:plot|graph)\s+(.+)$/i)
    if (m) return String(m[1]).trim()
    return s
}

// Quick reject before full parse: single line, short, standalone x,
// math-ish charset only. Standalone-x matters: "firefox"/"xterm"/"max"
// carry an x letter but never as a variable; "x chat" carries one but
// dies later as an unknown word (see isFunctionIncomplete).
function isPotentialFunction(query) {
    var body = stripBody(query)
    if (body === "" || body.length > 256) return false
    if (body.indexOf("\n") >= 0 || body.indexOf("\r") >= 0) return false
    // standalone x (not inside a longer word like exp/firefox/xterm)
    if (!/(^|[^a-zA-Z])x([^a-zA-Z]|$)/i.test(body)) return false
    if (!/^[0-9+\-*/%^().\sA-Za-z]+$/.test(body)) return false
    // must contain something graphable beyond a lone "x"? No - "x" alone
    // is y=x, the simplest real function. Keep it.
    return true
}

function isDigit(ch) { return ch >= "0" && ch <= "9" }
function isLetter(ch) {
    return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")
}

function tokenize(lower) {
    var tokens = []
    var n = lower.length
    var i = 0

    function prevIsValue() {
        if (tokens.length === 0) return false
        var t = tokens[tokens.length - 1]
        if (t.type === "number" || t.type === "variable") return true
        if (t.type === "paren" && t.value === ")") return true
        return false
    }

    while (i < n) {
        var c = lower[i]
        if (c === " " || c === "\t" || c === "\n" || c === "\r") { i++; continue }
        if (isDigit(c) || c === ".") {
            var start = i
            var dotCount = 0
            while (i < n && (isDigit(lower[i]) || lower[i] === ".")) {
                if (lower[i] === ".") dotCount++
                if (dotCount > 1) throw new Error("invalid number")
                i++
            }
            var raw = lower.substring(start, i)
            if (raw === "." || raw === "") throw new Error("invalid number")
            // scientific tail: 1e6, 1.5e-3 (exponent wins over `e` const)
            if (i < n && (lower[i] === "e" || lower[i] === "E")) {
                var j = i + 1
                if (j < n && (lower[j] === "+" || lower[j] === "-")) j++
                var k = j
                while (k < n && isDigit(lower[k])) k++
                if (k > j) {
                    raw = lower.substring(start, k)
                    i = k
                }
            }
            var v = Number(raw)
            if (isNaN(v)) throw new Error("invalid number")
            tokens.push({ type: "number", value: v })
            continue
        }
        if (isLetter(c)) {
            var s2 = i
            while (i < n && isLetter(lower[i])) i++
            var name = lower.substring(s2, i)
            if (name === "x") {
                tokens.push({ type: "variable", value: "x" })
            } else if (name === "pi") {
                tokens.push({ type: "number", value: Math.PI })
            } else if (name === "e") {
                tokens.push({ type: "number", value: Math.E })
            } else if (name === "tau") {
                tokens.push({ type: "number", value: Math.PI * 2 })
            } else if (FUNCS[name] === true) {
                tokens.push({ type: "func", value: name })
            } else {
                throw new Error("unknown function: " + name)
            }
            continue
        }
        if (c === "(" || c === ")") {
            tokens.push({ type: "paren", value: c })
            i++
            continue
        }
        if ("+-*/%^".indexOf(c) >= 0) {
            var isUnary = false
            if ((c === "+" || c === "-") && !prevIsValue()) isUnary = true
            if (isUnary) {
                tokens.push({ type: "op", value: c === "-" ? "u-" : "u+", unary: true })
            } else {
                tokens.push({ type: "op", value: c })
            }
            i++
            continue
        }
        throw new Error("invalid char: " + c)
    }
    return tokens
}

// Insert explicit '*' for juxtaposition: 2x, 2sin(x), x(x+1), )(
function withImplicitMult(tokens) {
    if (tokens.length < 2) return tokens
    var out = []
    function isLeftValue(t) {
        return t.type === "number" || t.type === "variable"
            || (t.type === "paren" && t.value === ")")
    }
    function isRightStart(t) {
        return t.type === "number" || t.type === "variable"
            || t.type === "func"
            || (t.type === "paren" && t.value === "(")
    }
    for (var i = 0; i < tokens.length; i++) {
        out.push(tokens[i])
        if (i + 1 < tokens.length) {
            var a = tokens[i], b = tokens[i + 1]
            // "2sin(x)": number directly before func needs '*', but a func
            // name directly before '(' is its own call - never split those.
            if (a.type === "func" && b.type === "paren" && b.value === "(") continue
            if (isLeftValue(a) && isRightStart(b)) {
                out.push({ type: "op", value: "*" })
            }
        }
    }
    return out
}

function toRpn(tokens) {
    var output = []
    var ops = []
    var prec = {
        "+": 1, "-": 1,
        "*": 2, "/": 2, "%": 2,
        "^": 3,
        "u-": 4, "u+": 4
    }
    var assoc = {
        "+": "L", "-": "L", "*": "L", "/": "L", "%": "L",
        "^": "R",
        "u-": "R", "u+": "R"
    }
    for (var i = 0; i < tokens.length; i++) {
        var t = tokens[i]
        if (t.type === "number" || t.type === "variable") {
            output.push(t)
        } else if (t.type === "func") {
            ops.push(t)
        } else if (t.type === "op") {
            var o1 = t.value
            while (ops.length > 0) {
                var o2 = ops[ops.length - 1]
                if (o2.type !== "op") break
                var p1 = prec[o1], p2 = prec[o2.value], a1 = assoc[o1]
                if ((a1 === "L" && p1 <= p2) || (a1 === "R" && p1 < p2)) {
                    output.push(ops.pop())
                } else break
            }
            ops.push(t)
        } else if (t.type === "paren" && t.value === "(") {
            ops.push(t)
        } else if (t.type === "paren" && t.value === ")") {
            var found = false
            while (ops.length > 0) {
                var top = ops.pop()
                if (top.type === "paren" && top.value === "(") { found = true; break }
                output.push(top)
            }
            if (!found) throw new Error("mismatched parentheses")
            if (ops.length > 0 && ops[ops.length - 1].type === "func") {
                output.push(ops.pop())
            }
        }
    }
    while (ops.length > 0) {
        var top2 = ops.pop()
        if (top2.type === "paren") throw new Error("mismatched parentheses")
        // dangling func without closing paren, e.g. "sin(x" handled above
        // as mismatched; "sin" alone leaves func on the stack -> incomplete
        if (top2.type === "func") throw new Error("missing operand")
        output.push(top2)
    }
    return output
}

function applyFunc(name, a) {
    switch (name) {
        case "sin": return Math.sin(a)
        case "cos": return Math.cos(a)
        case "tan": return Math.tan(a)
        case "asin": return Math.asin(a)
        case "acos": return Math.acos(a)
        case "atan": return Math.atan(a)
        case "sinh":
            return (Math.sinh) ? Math.sinh(a) : (Math.exp(a) - Math.exp(-a)) / 2
        case "cosh":
            return (Math.cosh) ? Math.cosh(a) : (Math.exp(a) + Math.exp(-a)) / 2
        case "tanh":
            return (Math.tanh) ? Math.tanh(a) : ((Math.exp(2 * a) - 1) / (Math.exp(2 * a) + 1))
        case "sqrt": return Math.sqrt(a)
        case "cbrt":
            return (Math.cbrt) ? Math.cbrt(a) : (a < 0 ? -Math.pow(-a, 1 / 3) : Math.pow(a, 1 / 3))
        case "abs": return Math.abs(a)
        case "exp": return Math.exp(a)
        case "ln": return Math.log(a)
        case "log":
            return (Math.log10) ? Math.log10(a) : Math.log(a) / Math.LN10
        case "floor": return Math.floor(a)
        case "ceil": return Math.ceil(a)
        case "round": return Math.round(a)
        default: throw new Error("unknown function: " + name)
    }
}

function evalRpn(rpn, x) {
    var stack = []
    for (var i = 0; i < rpn.length; i++) {
        var t = rpn[i]
        if (t.type === "number") {
            stack.push(t.value)
        } else if (t.type === "variable") {
            stack.push(x)
        } else if (t.type === "func") {
            if (stack.length < 1) throw new Error("missing operand")
            var a = stack.pop()
            stack.push(applyFunc(t.value, a))
        } else if (t.type === "op") {
            if (t.value === "u-" || t.value === "u+") {
                if (stack.length < 1) throw new Error("missing operand")
                var u = stack.pop()
                stack.push(t.value === "u-" ? -u : +u)
            } else {
                if (stack.length < 2) throw new Error("missing operand")
                var b = stack.pop()
                var a2 = stack.pop()
                var r
                switch (t.value) {
                    case "+": r = a2 + b; break
                    case "-": r = a2 - b; break
                    case "*": r = a2 * b; break
                    case "/": r = a2 / b; break
                    case "%": r = a2 % b; break
                    case "^": r = Math.pow(a2, b); break
                    default: throw new Error("unknown operator")
                }
                stack.push(r)
            }
        }
    }
    if (stack.length !== 1) throw new Error("invalid expression")
    return stack[0]
}

function compileBody(body) {
    var lower = String(body).toLowerCase()
    var toks = withImplicitMult(tokenize(lower))
    if (toks.length === 0) throw new Error("invalid expression")
    var hasVar = false
    for (var k = 0; k < toks.length; k++) {
        if (toks[k].type === "variable") { hasVar = true; break }
    }
    if (!hasVar) throw new Error("no variable")
    var rpn = toRpn(toks)
    return rpn
}

// Sample probes for the "real function" gate: must evaluate without
// structural errors and yield finite numbers in enough places that a
// curve actually exists. Domain-hostile ("x/0") or still-open ("x+")
// bodies fail here and read as incomplete, never as graphable.
var PROBE_XS = [-5, -3, -2, -1, -0.5, 0, 0.5, 1, 2, 3, 5]

function countFinite(rpn) {
    var n = 0
    for (var i = 0; i < PROBE_XS.length; i++) {
        var y = evalRpn(rpn, PROBE_XS[i])
        if (isFinite(y)) n++
    }
    return n
}

// Main entry: valid plottable function or null.
// Returned rpn is ready for per-x sampling (no re-parse per point).
function tryParseFunction(query) {
    var body = stripBody(query)
    if (body === "") return null
    if (!isPotentialFunction(query)) return null
    try {
        var rpn = compileBody(body)
        var finite = countFinite(rpn)
        if (finite < 3) return null
        return {
            expr: body,
            body: body,
            rpn: rpn
        }
    } catch (e) {
        return null
    }
}

// Graph gate: a lone variable ("x", "(x)", "-x", "y=x") parses fine but
// is not a curve worth a viewport. Graphable means a real expression -
// an operator or a function application somewhere around the variable.
// "2x", "x+1", "sin(x)" pass; bare forms fall through to app search.
function isBareVariable(body) {
    var s = String(body || "").trim().toLowerCase()
    if (s === "") return true
    var guard = 0
    while (guard++ < 32) {
        s = s.trim()
        var changed = false
        while (s.charAt(0) === "+" || s.charAt(0) === "-") {
            s = s.substring(1).trim()
            changed = true
        }
        if (s.length >= 2 && s.charAt(0) === "(" && s.charAt(s.length - 1) === ")") {
            var depth = 0, outer = true
            for (var i = 0; i < s.length; i++) {
                if (s.charAt(i) === "(") depth++
                else if (s.charAt(i) === ")") {
                    depth--
                    if (depth === 0 && i < s.length - 1) { outer = false; break }
                }
            }
            if (outer && depth === 0) {
                s = s.substring(1, s.length - 1)
                changed = true
                continue
            }
        }
        if (!changed) break
    }
    return s === "x"
}

// Eager-typing gate for the launcher: potential-looking but not yet
// valid. Unknown words ("x chat") are NOT incomplete - they fall through
// to app search. Structural gaps (missing operand, open paren) ARE.
function isFunctionIncomplete(query) {
    if (!isPotentialFunction(query)) return false
    if (tryParseFunction(query) !== null) return false
    var body = stripBody(query)
    if (body === "") return false
    try {
        var rpn = compileBody(body)
        // compiled but <3 finite (e.g. "x/0"): still typing-ish, keep the
        // single entry so apps stay hidden like CalcLib's incomplete.
        return true
    } catch (e) {
        var msg = String(e && e.message || "")
        if (msg.indexOf("unknown function") === 0) return false
        if (msg === "no variable") return false
        // mismatched parentheses / missing operand / invalid expression /
        // invalid number -> user is mid-expression
        return true
    }
}

// One-shot sampler for the Canvas: compile once, evaluate N points.
// Returns null when the body never compiled; otherwise
// { ys, yMin, yMax, valid } where non-finite samples stay NaN so the
// painter can break the path at asymptotes (tan, 1/x, log).
// Range uses 5th/95th percentiles so tan-style spikes never flatten the
// curve, while x^2-style parabolas still keep their wings.
function sampleFunction(body, xMin, xMax, n) {
    try {
        var rpn = compileBody(String(body || ""))
        var count = Math.max(2, Math.min(400, Math.round(n) || 120))
        var lo = Number(xMin), hi = Number(xMax)
        if (!(hi > lo)) return null
        var ys = new Array(count)
        var finiteVals = []
        var valid = 0
        for (var i = 0; i < count; i++) {
            var x = lo + (hi - lo) * i / (count - 1)
            var y
            try {
                y = evalRpn(rpn, x)
            } catch (e2) {
                y = NaN
            }
            if (typeof y !== "number" || isNaN(y) || !isFinite(y)) {
                ys[i] = NaN
                continue
            }
            // Hard spikes (>1e6, tan exactly at the pole) are breaks.
            if (Math.abs(y) > 1e6) {
                ys[i] = NaN
                continue
            }
            ys[i] = y
            finiteVals.push(y)
            valid++
        }
        if (valid === 0) return null
        var yMin, yMax
        if (finiteVals.length >= 10) {
            finiteVals.sort(function(a, b) { return a - b })
            var p5 = finiteVals[Math.floor(finiteVals.length * 0.05)]
            var p95 = finiteVals[Math.floor(finiteVals.length * 0.95)]
            if (!(p95 > p5)) {
                var c0 = finiteVals[Math.floor(finiteVals.length / 2)]
                var pad0 = Math.max(1, Math.abs(c0) * 0.1)
                yMin = c0 - pad0
                yMax = c0 + pad0
            } else {
                yMin = p5
                yMax = p95
                var span = yMax - yMin
                var pad2 = span * 0.18
                if (!(pad2 > 0)) pad2 = 1
                yMin -= pad2
                yMax += pad2
            }
        } else if (valid === 1) {
            var c = finiteVals[0]
            var pad = Math.max(1, Math.abs(c) * 0.1)
            yMin = c - pad
            yMax = c + pad
        } else {
            yMin = Infinity
            yMax = -Infinity
            for (var k = 0; k < finiteVals.length; k++) {
                if (finiteVals[k] < yMin) yMin = finiteVals[k]
                if (finiteVals[k] > yMax) yMax = finiteVals[k]
            }
            if (!(yMax > yMin)) {
                var c2 = yMin
                if (!isFinite(c2)) return null
                var pad3 = Math.max(1, Math.abs(c2) * 0.1)
                yMin = c2 - pad3
                yMax = c2 + pad3
            } else {
                var span2 = yMax - yMin
                var pad4 = span2 * 0.12
                if (!(pad4 > 0)) pad4 = 1
                yMin -= pad4
                yMax += pad4
            }
        }
        return { ys: ys, yMin: yMin, yMax: yMax, valid: valid }
    } catch (e) {
        return null
    }
}
