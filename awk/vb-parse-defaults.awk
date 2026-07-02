# Parse vb-core-defaults annotation blocks, emit bash array assignments for eval.
BEGIN {
  SCRIPT = "vb-parse-defaults.awk"
  warnings = 0
}

# Strip trailing carriage return on lines that have one.
/\r$/ { sub(/\r$/, "") }

# Blank line ends the current annotation block - reset state to prevent
# cross-block contamination.
/^[[:space:]]*$/ { type = ""; min = ""; max = ""; allowed = ""; next }

# Comment lines starting with "# @" are annotation tags. The substr guard avoids
# field-splitting the majority of plain comments that carry no semantic value.
/^#/ {
    if (substr($0, 1, 3) != "# @") { next }
    if ($2 == "@type") {
        t = tolower($3)
        if (t == "integer") t = "int"
        if (t == "bool" || t == "int" || t == "string") {
            type = t
        } else {
            printf "[" SCRIPT "] Error: line %d: unknown @type '%s' - must be bool, int, or string\n", NR, $3 > "/dev/stderr"; warnings++
        }

    } else if ($2 == "@range") {
        if (type != "" && type != "int") {
            printf "[" SCRIPT "] Error: line %d: @range is only valid for @type int, got '%s'\n", NR, type > "/dev/stderr"; warnings++
        } else if ($3 !~ /^-?[0-9]+\.\.-?[0-9]+$/) {
            printf "[" SCRIPT "] Error: line %d: @range '%s' is malformed - expected format N..M\n", NR, $3 > "/dev/stderr"; warnings++
        } else {
            p = index($3, "..")
            v1 = substr($3, 1, p - 1)
            v2 = substr($3, p + 2)
            if (v1 + 0 >= v2 + 0) {
                printf "[" SCRIPT "] Error: line %d: @range %s is invalid - min must be strictly less than max\n", NR, $3 > "/dev/stderr"; warnings++
            } else {
                min = v1; max = v2
            }
        }

    } else if ($2 == "@values") {
        if (type != "" && type != "string") {
            printf "[" SCRIPT "] Error: line %d: @values is only valid for @type string, got '%s'\n", NR, type > "/dev/stderr"; warnings++
        } else if (NF < 3) {
            printf "[" SCRIPT "] Error: line %d: @values is empty - at least one value required\n", NR > "/dev/stderr"; warnings++
        } else {
            # Pipe-delimited sentinel string: helpers::check tests membership
            # with a single substring match: [[ $allowed == *"|$val|"* ]]
            allowed = "|"
            for (i = 3; i <= NF; i++) allowed = allowed $i "|"
        }

    } else if ($2 == "@note" || $2 == "@desc" || $2 == "@ignore") {
        # Free-form documentation or explicit skip - no semantic effect.

    } else {
        printf "[" SCRIPT "] Error: line %d: unknown tag '%s' - valid tags are @type @range @values @note\n", NR, $2 > "/dev/stderr"; warnings++
    }
    next
}

# Assignment lines: VIBRANIUM_<NAME>=<value>
/^VIBRANIUM_[A-Z_]+=/ {
    eq  = index($0, "=")
    var = substr($0, 1, eq - 1)
    val = substr($0, eq + 1)
    vlen = length(val)
    vfirst = substr(val, 1, 1)
    vlast  = substr(val, vlen, 1)

    # Skip variables without a @type annotation block.
    if (type == "") {
        min = ""; max = ""; allowed = ""
        next
    }

    # Lint: cross-field consistency checks
    if (type == "bool") {
        if (min != "") {
            printf "[" SCRIPT "] Warn: line %d: %s: @range has no effect on @type bool\n", NR, var > "/dev/stderr"; warnings++
        }
        if (allowed != "") {
            printf "[" SCRIPT "] Warn: line %d: %s: @values has no effect on @type bool\n", NR, var > "/dev/stderr"; warnings++
        }
        if (val != "true" && val != "false") {
            printf "[" SCRIPT "] Error: line %d: %s: bool default must be exactly 'true' or 'false' (unquoted), got '%s'\n", NR, var, val > "/dev/stderr"; warnings++
        }
    }

    if (type == "int") {
        if (allowed != "") {
            printf "[" SCRIPT "] Warn: line %d: %s: @values has no effect on @type int - use @range instead\n", NR, var > "/dev/stderr"; warnings++
        }
        if (val !~ /^-?[0-9]+$/) {
            printf "[" SCRIPT "] Error: line %d: %s: int default must be an unquoted integer, got '%s'\n", NR, var, val > "/dev/stderr"; warnings++
        } else if (min != "" && (val + 0 < min + 0 || val + 0 > max + 0)) {
            printf "[" SCRIPT "] Error: line %d: %s: default %s is outside @range %s..%s\n", NR, var, val, min, max > "/dev/stderr"; warnings++
        }
    }

    if (type == "string") {
        if (allowed == "") {
            printf "[" SCRIPT "] Error: line %d: %s: @type string requires @values\n", NR, var > "/dev/stderr"; warnings++
        } else {
            if (vfirst != "\"" || vlast != "\"") {
                printf "[" SCRIPT "] Error: line %d: %s: string default must be double-quoted, got '%s'\n", NR, var, val > "/dev/stderr"; warnings++
            } else {
                inner = substr(val, 2, vlen - 2)
                if (index(allowed, "|" inner "|") == 0) {
                    printf "[" SCRIPT "] Error: line %d: %s: default '%s' is not listed in @values (%s)\n", NR, var, inner, allowed > "/dev/stderr"; warnings++
                }
            }
        }
    }

    # Strip one layer of matching surrounding single or double quotes.
    if (vlen >= 2 && ((vfirst == "'" && vlast == "'") || (vfirst == "\"" && vlast == "\"")))
        val = substr(val, 2, vlen - 2)

    # Escape embedded single quotes for safe shell eval.
    gsub(/'/, "'\\''", val)

    # Build and emit output - single printf per variable, combined via sprintf.
    out = sprintf("OPTION_DEFAULTS[%s]='%s'\nOPTION_TYPES[%s]='%s'", var, val, var, type)
    if (allowed != "") out = out sprintf("\nOPTION_ALLOWEDS[%s]='%s'", var, allowed)
    if (min != "")     out = out sprintf("\nOPTION_MINS[%s]='%s'\nOPTION_MAXS[%s]='%s'", var, min, var, max)
    printf "%s\n", out

    type = ""; min = ""; max = ""; allowed = ""
    next
}
