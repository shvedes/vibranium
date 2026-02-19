# vb-parse-defaults.awk
# Single-pass parser + linter for vb-core-defaults.
#
# Two output streams:
#   stdout  — bash associative-array assignments, captured by eval in helpers::check
#   stderr  — lint warnings, bypass the subshell and reach the terminal directly
#
# Lint warnings are always emitted when violations are found. The tty flag
# only controls whether ANSI colour codes are included.
#
# Usage from helpers::check:
#   eval "$(awk -v tty="$([[ -t 2 ]] && echo 1 || echo 0)" \
#              -f "$VIBRANIUM_PATH/vb-defaults.awk"         \
#              "$VIBRANIUM_PATH/vb-core-defaults")"
#
# Standalone lint (developer / CI):
#   awk -v tty="$([[ -t 2 ]] && echo 1 || echo 0)" \
#       -f vb-defaults.awk vb-core-defaults

BEGIN {
    RED   = tty ? "\033[0;31m" : ""
    GREEN = tty ? "\033[0;32m" : ""
    RESET = tty ? "\033[0m"    : ""

    _reset_block()
    warnings = 0
    block_start = 0
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function _reset_block() {
    type=""; min=""; max=""; allowed=""
    has_type=0; has_values=0
    block_start=0
}

function warn(msg) {
    loc = (block_start > 0) ? "line " block_start : "line " NR
    printf "%s[WARN]%s %s: %s\n", RED, RESET, loc, msg > "/dev/stderr"
    warnings++
}

# ---------------------------------------------------------------------------
# Per-line processing
# ---------------------------------------------------------------------------

# Portable CR strip — safe against Windows-style CRLF checkouts
{ gsub(/\r$/, "") }

# Blank line — hard reset.
# Prevents a variable with no @type from inheriting the preceding block's metadata.
/^[[:space:]]*$/ {
    _reset_block()
    next
}

# File-level comments (no @ tag) — skip silently.
# This covers the header block and any free-form section dividers.
/^#/ {
    line = $0
    sub(/^#[ \t]*/, "", line)
    if (substr(line, 1, 1) != "@") {
        next
    }
}
/^#$/ { next }

# @type — required for every managed variable
/^# @type[[:space:]]/ {
    if (block_start == 0) block_start = NR

    t = tolower($3)
    if (t == "integer") t = "int"

    if (t != "bool" && t != "int" && t != "string") {
        warn("unknown @type '" $3 "' — must be bool, int, or string")
    } else {
        type     = t
        has_type = 1
    }
    next
}

# @range — int only, optional. Format: N..M
/^# @range[[:space:]]/ {
    if (block_start == 0) block_start = NR

    if (has_type && type != "int") {
        warn("@range is only valid for @type int, got '" type "'")
        next
    }
    if ($3 !~ /^-?[0-9]+\.\.-?[0-9]+$/) {
        warn("@range '" $3 "' is malformed — expected format N..M (e.g. 0..100)")
        next
    }
    n = split($3, parts, /\.\./)
    if (parts[1]+0 >= parts[2]+0) {
        warn("@range " $3 " is invalid — min must be strictly less than max")
    } else {
        min = parts[1]
        max = parts[2]
    }
    next
}

# @values — string only, required when @type is string.
# Stored with sentinel | pipes at both ends so helpers::check can do an O(1)
# substring test ([[ $allowed == *"|$val|"* ]]) instead of a linear scan.
/^# @values[[:space:]]/ {
    if (block_start == 0) block_start = NR

    if (has_type && type != "string") {
        warn("@values is only valid for @type string, got '" type "'")
        next
    }
    if (NF < 3) {
        warn("@values is empty — at least one value required")
        next
    }
    allowed = "|"
    for (i = 3; i <= NF; i++) allowed = allowed $i "|"
    has_values = 1
    next
}

# @note — one or more lines of free-form human description.
# @description — one or more lines of free-form human description.
# Each line must start with # @note. Ignored entirely by both parser and linter.
# Each line must start with # @description. Ignored entirely by both parser and linter.
/^# @note([[:space:]]|$)/ { next }
/^# @desc([[:space:]]|$)/ { next }
/^# @ignore([[:space:]]|$)/ { next }

# Unknown @-tag — likely a typo in the annotation block
/^# @/ {
    if (block_start == 0) block_start = NR
    warn("unknown tag '" $2 "' — valid tags are @type @range @values @note")
    next
}

# Assignment line — the main event.
# Performs cross-field lint checks, then emits cache assignments to stdout.
/^VIBRANIUM_[A-Z_]+=/ {
    if (block_start == 0) block_start = NR

    eq  = index($0, "=")
    var = substr($0, 1, eq-1)
    val = substr($0, eq+1)

    # Variables with no @type are not managed by helpers::check — skip silently
    if (!has_type) {
        _reset_block()
        next
    }

    # --- Lint: cross-field consistency checks ---

    if (type == "bool") {
        if (min != "")
            warn(var ": @range has no effect on @type bool")
        if (has_values)
            warn(var ": @values has no effect on @type bool")
        if (val != "true" && val != "false")
            warn(var ": bool default must be exactly 'true' or 'false' (unquoted), got '" val "'")
    }

    if (type == "int") {
        if (has_values)
            warn(var ": @values has no effect on @type int — use @range instead")
        if (val !~ /^-?[0-9]+$/)
            warn(var ": int default must be an unquoted integer, got '" val "'")
        else if (min != "" && (val+0 < min+0 || val+0 > max+0))
            warn(var ": default " val " is outside @range " min ".." max)
    }

    if (type == "string") {
        if (!has_values)
            warn(var ": @type string requires @values")
        else {
            f = substr(val, 1, 1)
            l = substr(val, length(val), 1)
            if (f != "\"" || l != "\"") {
                warn(var ": string default must be double-quoted, got '" val "'")
            } else {
                inner = substr(val, 2, length(val)-2)
                if (index(allowed, "|" inner "|") == 0)
                    warn(var ": default '" inner "' is not listed in @values (" allowed ")")
            }
        }
    }

    # --- Parser: strip quotes, escape, emit to stdout ---

    # Strip one layer of matching surrounding quotes (single or double).
    # Only when both ends match — "foo" → foo, 'bar' → bar; mismatched left intact.
    if (length(val) >= 2) {
        f = substr(val, 1, 1)
        l = substr(val, length(val), 1)
        if ((f == "'" && l == "'") || (f == "\"" && l == "\""))
            val = substr(val, 2, length(val)-2)
    }

    # Escape embedded single quotes for safe eval.
    # Each ' becomes '\'' — the standard shell escape inside a single-quoted string.
    gsub(/'/, "'\\''", val)

    # Emit bash associative-array assignments.
    # Values are single-quoted so whitespace and special characters are safe.
    printf "OPTION_DEFAULTS[%s]='%s'\n", var, val
    printf "OPTION_TYPES[%s]='%s'\n",    var, type
    if (allowed != "") printf "OPTION_ALLOWEDS[%s]='%s'\n", var, allowed
    if (min != "") {
        printf "OPTION_MINS[%s]='%s'\n", var, min
        printf "OPTION_MAXS[%s]='%s'\n", var, max
    }

    _reset_block()
    next
}

# END {
#     if (warnings == 0)
#         printf "%s[INFO]%s defaults passed all checks\n", GREEN, RESET > "/dev/stderr"
#     else
#         printf "%s[WARN]%s %d issue(s) found in defaults\n", RED, RESET, warnings > "/dev/stderr"
# }
