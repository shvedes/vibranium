// Inline calculator engine for AppLauncher: pure-JS deterministic evaluator.
// Basic arithmetic only: + - * / % ^ parentheses, decimals, unary +/-.
// No external deps, no eval(), safe for per-keystroke use.
//
// Usage: CalcLib.tryEvaluate(query) -> null | { expr, value, formatted }
//        CalcLib.isPotentialCalc(query) quick reject for non-math input.
.pragma library

// Quick reject before full parse: must look like math.
// - allowed chars: digits, operators, parentheses, dot, whitespace, ^ %
// - must contain at least one digit and one operator/paren that proves
//   it's an expression rather than a plain number/app name.
// Single number alone (e.g. "42") is NOT considered calc to avoid hiding
// apps when typing a number.
function isPotentialCalc(query) {
    var s = String(query || "").trim()
    if (s === "") return false
    // strip trailing '=' like "2+2=" -> "2+2"
    // only strip '=' characters at end with optional spaces
    s = s.replace(/\s*=+\s*$/, "").trim()
    if (s === "") return false
    // allowed charset - basic math only
    if (!/^[0-9+\-*/%^().\s]+$/.test(s)) return false
    // must contain digit
    if (!/[0-9]/.test(s)) return false
    // must contain operator or parentheses to be expression-like
    // otherwise "123" would hide apps incorrectly
    if (!/[+\-*/%^()]/.test(s)) return false
    return true
}

function tokenize(expr) {
    var tokens = []
    var n = expr.length
    var i = 0

    function isDigit(ch) { return ch >= "0" && ch <= "9" }
    function prevIsValue() {
        if (tokens.length === 0) return false
        var t = tokens[tokens.length - 1]
        return t.type === "number" || (t.type === "paren" && t.value === ")")
    }

    while (i < n) {
        var c = expr[i]
        if (c === " " || c === "\t" || c === "\n" || c === "\r") { i++; continue }
        if (isDigit(c) || c === ".") {
            var start = i
            var dotCount = 0
            while (i < n && (isDigit(expr[i]) || expr[i] === ".")) {
                if (expr[i] === ".") dotCount++
                if (dotCount > 1) throw new Error("invalid number")
                i++
            }
            var raw = expr.substring(start, i)
            // reject lone "." or empty
            if (raw === "." || raw === "") throw new Error("invalid number")
            // reject "5..3" already via dotCount
            // allow trailing dot "5." -> treat as "5"
            // parse
            var v = Number(raw)
            if (isNaN(v)) throw new Error("invalid number")
            tokens.push({ type: "number", value: v, raw: raw })
            continue
        }
        if (c === "(" || c === ")") {
            tokens.push({ type: "paren", value: c })
            i++
            continue
        }
        if ("+-*/%^".indexOf(c) >= 0) {
            var isUnary = false
            if ((c === "+" || c === "-") && !prevIsValue()) {
                // unary if at start, after '(' or another operator
                isUnary = true
            }
            if (isUnary) {
                tokens.push({ type: "op", value: c === "-" ? "u-" : "u+", unary: true })
            } else {
                // binary operator but must have left value
                // e.g. "2+*3" will be caught later as missing operand
                // also reject ambiguous "2//3" etc will fail in eval
                tokens.push({ type: "op", value: c })
            }
            i++
            continue
        }
        // any other char invalid
        throw new Error("invalid char: " + c)
    }
    return tokens
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
        if (t.type === "number") {
            output.push(t)
        } else if (t.type === "op") {
            var o1 = t.value
            while (ops.length > 0) {
                var o2 = ops[ops.length - 1]
                if (o2.type !== "op") break
                var p1 = prec[o1]
                var p2 = prec[o2.value]
                var a1 = assoc[o1]
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
        }
    }
    while (ops.length > 0) {
        var top2 = ops.pop()
        if (top2.type === "paren") throw new Error("mismatched parentheses")
        output.push(top2)
    }
    return output
}

function evalRpn(rpn) {
    var stack = []
    for (var i = 0; i < rpn.length; i++) {
        var t = rpn[i]
        if (t.type === "number") {
            stack.push(t.value)
        } else if (t.type === "op") {
            if (t.value === "u-" || t.value === "u+") {
                if (stack.length < 1) throw new Error("missing operand")
                var a = stack.pop()
                stack.push(t.value === "u-" ? -a : +a)
            } else {
                if (stack.length < 2) throw new Error("missing operand")
                var b = stack.pop()
                var a2 = stack.pop()
                var r
                switch (t.value) {
                    case "+": r = a2 + b; break
                    case "-": r = a2 - b; break
                    case "*": r = a2 * b; break
                    case "/":
                        if (b === 0) throw new Error("division by zero")
                        r = a2 / b; break
                    case "%":
                        if (b === 0) throw new Error("division by zero")
                        r = a2 % b; break
                    case "^": r = Math.pow(a2, b); break
                    default: throw new Error("unknown operator")
                }
                if (!isFinite(r) && isFinite(a2) && isFinite(b)) {
                    // overflow or other non-finite from finite inputs
                    // still allow but caller will handle
                }
                stack.push(r)
            }
        }
    }
    if (stack.length !== 1) throw new Error("invalid expression")
    return stack[0]
}

function formatResult(v) {
    if (typeof v !== "number" || !isFinite(v)) {
        if (isNaN(v)) return "NaN"
        return v > 0 ? "Infinity" : "-Infinity"
    }
    // handle integer (QJSEngine compat: avoid Number.isInteger)
    if (v % 1 === 0) {
        // avoid -0 display
        if (v === 0) v = 0
        return String(v)
    }
    // for non-integers, round to avoid floating artefacts
    // use 10 decimal places max, but trim unnecessary zeros
    // also use precision for very small/large numbers
    var abs = Math.abs(v)
    if (abs !== 0 && (abs >= 1e12 || abs < 1e-6)) {
        // exponential with 6 significant digits then trim
        var exp = v.toExponential(6)
        // trim trailing zeros in mantissa
        exp = exp.replace(/(\.\d*?[1-9])0+e/, "$1e").replace(/\.0+e/, "e")
        return exp
    }
    // fixed approach
    var s = v.toFixed(10)
    // trim trailing zeros and possible dot
    s = s.replace(/\.?0+$/, "")
    if (s === "-0") s = "0"
    if (s === "") s = "0"
    return s
}

// Main entry: attempt to evaluate query as math.
// Returns null if not math or invalid, else { expr, value, formatted }
function tryEvaluate(query) {
    var raw = String(query || "")
    var s = raw.trim()
    if (s === "") return null
    // strip trailing '=' characters (user habit "2+2=")
    var trimmedForDisplay = s
    s = s.replace(/\s*=+\s*$/, "").trim()
    if (s === "") return null
    if (!isPotentialCalc(s)) return null
    try {
        var tokens = tokenize(s)
        if (tokens.length === 0) return null
        // reject expression that is just a single number without operator
        // already handled by isPotentialCalc, but double-check after tokenize
        // require at least one operator or paren
        var hasOp = false
        for (var k = 0; k < tokens.length; k++) {
            if (tokens[k].type === "op" || tokens[k].type === "paren") { hasOp = true; break }
        }
        if (!hasOp) return null
        var rpn = toRpn(tokens)
        var val = evalRpn(rpn)
        if (!isFinite(val)) {
            // division by zero already thrown; but handle overflow
            // still return formatted infinity
        }
        var formatted = formatResult(val)
        return {
            expr: trimmedForDisplay.replace(/\s*=+\s*$/, "").trim(),
            value: val,
            formatted: formatted,
            // original query trimmed
            original: String(query).trim()
        }
    } catch (e) {
        return null
    }
}
