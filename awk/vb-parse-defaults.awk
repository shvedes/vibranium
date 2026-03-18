# TL;DR: Reads vb-core-defaults, validates annotation blocks (@type/@range/@values),
# and emits bash associative-array assignments to stdout so the caller can eval them
# into shell variables. Lint warnings go to stderr. No logic changes are made to the
# defaults file itself.
#
# --- What this file is ---
# A single-pass AWK parser and linter for the vb-core-defaults config file.
# Each managed variable in that file is preceded by an annotation block made of
# comment lines starting with # @<tag>. This script reads those annotations,
# validates them for consistency, then emits bash array assignments so the caller
# (helpers::check, from the vb-lib-core) can consume
# type/default/constraint metadata at runtime.
#
# --- Output streams ---
# stdout  — bash array assignments, one per metadata field per variable.
#           The caller wraps the invocation in eval "$(awk ...)" to load them.
# stderr  — lint warnings. These go directly to the terminal because they are
#           emitted inside a subshell (the eval capture) and would otherwise be lost.
#
# --- Annotation tags understood by this parser ---
# @type   <bool|int|string>   — required for every managed variable
# @range  <N..M>              — optional, int only; defines an inclusive valid range
# @values <v1> <v2> ...       — required for string types; defines the allowed values
# @note   <anything>          — free-form human note, ignored by parser and linter
# @desc   <anything>          — alias for @note, also ignored
# @ignore                     — marks a variable to be skipped entirely
#
# --- How annotations map to output arrays ---
# OPTION_DEFAULTS[VAR]  — the default value with surrounding quotes stripped
# OPTION_TYPES[VAR]     — the normalised type (bool, int, or string)
# OPTION_ALLOWEDS[VAR]  — pipe-delimited allowed values e.g. |foo|bar|baz|
# OPTION_MINS[VAR]      — lower bound from @range (only when @range is present)
# OPTION_MAXS[VAR]      — upper bound from @range (only when @range is present)
#
# --- Lint checks performed ---
# - @type must be one of bool, int, string
# - @range must follow the N..M format and min must be strictly less than max
# - @range is an error on non-int types
# - @values must have at least one value and is only valid on string types
# - @values on a bool or int type is warned but not fatal
# - bool defaults must be exactly the unquoted literals true or false
# - int defaults must be unquoted integers and must fall within @range if given
# - string defaults must be double-quoted and the inner value must appear in @values
# - Any unknown @-tag is warned as a likely typo

BEGIN {
    # ANSI colors.
    RED   = "\033[0;31m"
    GREEN = "\033[0;32m"
    RESET = "\033[0m"

    # Initialise the per-block state machine. _reset_block() zeroes all fields
    # that accumulate annotation data between the comment block and the assignment.
    _reset_block()

    # Running count of lint warnings emitted across the whole file.
    warnings = 0

    # Line number where the current annotation block started. Used in warn()
    # to point at the opening @type line rather than the triggering line.
    block_start = 0
}

# _reset_block clears all state that belongs to a single variable's annotation block.
# Called at the start of each new block, on blank lines (to prevent cross-block
# contamination), and after an assignment line is fully processed.
function _reset_block() {
    type=""; min=""; max=""; allowed=""
    has_type=0; has_values=0
    block_start=0
}

# warn emits a formatted warning to stderr with a line reference.
# If block_start is set we use it so the location points at the annotation
# block rather than the assignment line that triggered the check.
function warn(msg) {
    loc = (block_start > 0) ? "line " block_start : "line " NR
    printf "%s[SETTINGS PARASER]%s %s: %s\n", RED, RESET, loc, msg > "/dev/stderr"
    warnings++
}

# Strip trailing carriage returns before any pattern matching.
# Handles Windows-style CRLF line endings that survive a Unix checkout.
{ gsub(/\r$/, "") }

# A blank line (or whitespace-only line) ends the current annotation block.
# Resetting here is critical: without it a variable with no @type would silently
# inherit the type of whatever variable came before it in the file.
/^[[:space:]]*$/ {
    _reset_block()
    next
}

# Plain comment lines (# without an @ tag) are file-level prose — headers,
# section dividers, human notes not attached to a specific tag. Skip them.
# We strip the leading "# " and check whether the remainder starts with @;
# if not, it is free-form text and we move on without touching block state.
/^#/ {
    line = $0
    sub(/^#[ \t]*/, "", line)
    if (substr(line, 1, 1) != "@") {
        next
    }
}
# A bare "#" line (no text after the hash) is also a plain comment — skip it.
/^#$/ { next }

# @type declares what kind of value this variable holds.
# It is required; variables without @type are silently ignored at assignment time.
# "integer" is accepted as an alias for "int" and normalised here.
# Any other value triggers a lint warning and leaves has_type=0, which means
# the assignment line will be skipped rather than emitting bad metadata.
/^# @type[[:space:]]/ {
    # Record where this annotation block started (first @-tag seen).
    if (block_start == 0) block_start = NR

    t = tolower($3)
    # Normalise "integer" → "int" so the rest of the script only needs to
    # check against the three canonical type strings.
    if (t == "integer") t = "int"

    if (t != "bool" && t != "int" && t != "string") {
        warn("unknown @type '" $3 "' — must be bool, int, or string")
    } else {
        type     = t
        has_type = 1
    }
    next
}

# @range defines an inclusive [min, max] constraint for int variables.
# Format must be N..M where N and M are integers (negative allowed) and N < M.
# It is optional; omitting it means no range check is applied at runtime.
/^# @range[[:space:]]/ {
    if (block_start == 0) block_start = NR

    # @range makes no sense on bool or string — warn and bail out of this tag.
    if (has_type && type != "int") {
        warn("@range is only valid for @type int, got '" type "'")
        next
    }
    # Validate the N..M shape before trying to split on "..".
    if ($3 !~ /^-?[0-9]+\.\.-?[0-9]+$/) {
        warn("@range '" $3 "' is malformed — expected format N..M (e.g. 0..100)")
        next
    }
    # Split on the ".." separator to extract min and max as separate values.
    n = split($3, parts, /\.\./)
    # min must be strictly less than max; equal or inverted ranges are nonsensical.
    if (parts[1]+0 >= parts[2]+0) {
        warn("@range " $3 " is invalid — min must be strictly less than max")
    } else {
        min = parts[1]
        max = parts[2]
    }
    next
}

# @values lists the complete set of legal values for a string variable.
# Space-separated on a single line: # @values foo bar baz
# Stored internally with leading and trailing pipe sentinels so that
# helpers::check can test membership with a simple shell substring match:
#   [[ $allowed == *"|$val|"* ]]
# instead of looping over every allowed value.
/^# @values[[:space:]]/ {
    if (block_start == 0) block_start = NR

    # @values on a non-string type is a mistake — warn and discard.
    if (has_type && type != "string") {
        warn("@values is only valid for @type string, got '" type "'")
        next
    }
    # NF < 3 means there are no values after the tag word itself.
    if (NF < 3) {
        warn("@values is empty — at least one value required")
        next
    }
    # Build the pipe-delimited sentinel string from field 3 onward.
    allowed = "|"
    for (i = 3; i <= NF; i++) allowed = allowed $i "|"
    has_values = 1
    next
}

# @note and @desc are free-form human-readable documentation attached to a variable.
# They have no semantic meaning to the parser or linter and are discarded entirely.
# @ignore marks a variable to be explicitly skipped — no output, no lint checks.
/^# @note([[:space:]]|$)/ { next }
/^# @desc([[:space:]]|$)/ { next }
/^# @ignore([[:space:]]|$)/ { next }

# Any other # @<something> line is an unrecognised tag — likely a typo.
# Warn so the author knows their annotation is being ignored.
/^# @/ {
    if (block_start == 0) block_start = NR
    warn("unknown tag '" $2 "' — valid tags are @type @range @values @note")
    next
}

# Assignment lines are the main event. A line matching VIBRANIUM_<NAME>=<value>
# triggers cross-field lint checks across the accumulated annotation state,
# then emits bash array assignments to stdout.
/^VIBRANIUM_[A-Z_]+=/ {
    if (block_start == 0) block_start = NR

    # Split the line into variable name and raw value at the first "=".
    # Using index() rather than $1/$2 avoids issues with spaces inside the value.
    eq  = index($0, "=")
    var = substr($0, 1, eq-1)
    val = substr($0, eq+1)

    # Variables without a @type annotation are not managed by helpers::check.
    # Skip them silently — they may be internal constants or unrelated config.
    if (!has_type) {
        _reset_block()
        next
    }

    # --- Lint: cross-field consistency checks ---

    if (type == "bool") {
        # @range and @values are meaningless on booleans — warn but continue.
        if (min != "")
            warn(var ": @range has no effect on @type bool")
        if (has_values)
            warn(var ": @values has no effect on @type bool")
        # The only legal bool defaults are the literal unquoted strings true/false.
        if (val != "true" && val != "false")
            warn(var ": bool default must be exactly 'true' or 'false' (unquoted), got '" val "'")
    }

    if (type == "int") {
        # @values on an int is a mistake; @range is the right mechanism.
        if (has_values)
            warn(var ": @values has no effect on @type int — use @range instead")
        # The default must be a bare integer (optional leading minus).
        if (val !~ /^-?[0-9]+$/)
            warn(var ": int default must be an unquoted integer, got '" val "'")
        # If @range was specified, the default must fall within [min, max].
        else if (min != "" && (val+0 < min+0 || val+0 > max+0))
            warn(var ": default " val " is outside @range " min ".." max)
    }

    if (type == "string") {
        # @values is mandatory for string types; without it we cannot validate
        # the default or enforce constraints at runtime.
        if (!has_values)
            warn(var ": @type string requires @values")
        else {
            # The default must be double-quoted in the source file.
            f = substr(val, 1, 1)
            l = substr(val, length(val), 1)
            if (f != "\"" || l != "\"") {
                warn(var ": string default must be double-quoted, got '" val "'")
            } else {
                # Strip the surrounding quotes and check membership in allowed values.
                # index() returns 0 if the |inner| sentinel is not found in the pipe string.
                inner = substr(val, 2, length(val)-2)
                if (index(allowed, "|" inner "|") == 0)
                    warn(var ": default '" inner "' is not listed in @values (" allowed ")")
            }
        }
    }

    # --- Parser: strip quotes, escape for shell safety, emit to stdout ---

    # Strip one layer of matching surrounding quotes so the stored value is bare.
    # Only acts when both the first and last characters are the same quote type.
    # Mismatched or unquoted values are left intact.
    # Examples: "foo" → foo,  'bar' → bar,  unquoted → unchanged.
    if (length(val) >= 2) {
        f = substr(val, 1, 1)
        l = substr(val, length(val), 1)
        if ((f == "'" && l == "'") || (f == "\"" && l == "\""))
            val = substr(val, 2, length(val)-2)
    }

    # Escape any embedded single quotes in the value so it is safe to wrap in
    # single quotes for the printf below. The standard shell escape sequence
    # for a literal ' inside a single-quoted string is: '\''
    gsub(/'/, "'\\''", val)

    # Emit the bash associative-array assignments to stdout.
    # Each value is single-quoted so whitespace and special characters survive eval.
    printf "OPTION_DEFAULTS[%s]='%s'\n", var, val
    printf "OPTION_TYPES[%s]='%s'\n",    var, type
    # OPTION_ALLOWEDS is only emitted when @values was present (string types).
    if (allowed != "") printf "OPTION_ALLOWEDS[%s]='%s'\n", var, allowed
    # OPTION_MINS/MAXS are only emitted when @range was present (int types).
    if (min != "") {
        printf "OPTION_MINS[%s]='%s'\n", var, min
        printf "OPTION_MAXS[%s]='%s'\n", var, max
    }

    # Clear all block state so the next variable starts clean.
    _reset_block()
    next
}

# END block is currently disabled. When re-enabled it would print a summary line
# to stderr: either a green "passed all checks" or a red count of issues found.
# Kept as a reference for future debugging or CI reporting needs.
# END {
#     if (warnings == 0)
#         printf "%s[SETTINGS PARSER]%s Default settings passed all checks\n", GREEN, RESET > "/dev/stdin"
#     else
#         printf "%s[SETTINGS PARSER]%s %d issue(s) found in default settings\n", RED, RESET, warnings > "/dev/stderr"
# }
