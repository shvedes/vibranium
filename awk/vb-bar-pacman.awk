#!/usr/bin/awk

# This awk script is used by the updates waybar module.
# See vb-bar-pacman for more info.

# trim() removes leading and trailing whitespace from a string.
# This is used to clean up the left and right parts of the "->"
# lines for consistent parsing.
function trim(s) {
    sub(/^[ \t\r\n]+/, "", s)
    sub(/[ \t\r\n]+$/, "", s)
    return s
}

# get_upstream(v) extracts the "upstream" part of a package version.
# This is the core logic for detecting "complex" versions that we want
# to hide in the "and N more" section.
#
# How it works:
# 1. If the version has an epoch (e.g. "2:8.0.1-6"), strip it to "8.0.1-6".
# 2. Split the version by "-" (the pkgrel separator).
# 3. Reassemble everything EXCEPT the last part (the pkgrel/release number).
#    This leaves the upstream version + any pre-release/build tags.
#
# Examples:
#   "5.3.28-5"      -> "5.3.28"          (simple patch)
#   "1.26.10-5"     -> "1.26.10"         (simple)
#   "2:8.0.1-6"     -> "8.0.1"           (epoch stripped)
#   "2.1.1767980792+707c12b-1" -> "2.1.1767980792+707c12b" (long git build)
#
# We use this to detect "ugly" versions: those longer than 15 chars
# (git hashes, complex build tags, etc.). These will always be excluded
# from the visible list, regardless of width or line limits.
function get_upstream(v) {
    # Strip epoch if present (e.g. "2:..." -> "...")
    if (match(v, /:/)) {
        v = substr(v, RSTART + RLENGTH)
    }
    # Split by "-" and keep all but the last part
    split(v, parts, "-")
    if (length(parts) <= 1) {
        return v  # No pkgrel, return as-is
    }
    res = parts[1]
    for (k = 2; k < length(parts); k++) {
        res = res "-" parts[k]
    }
    return res
}

# Parse each input line into pkg, old, new.
# Input can be in two formats:
#   1. "pkg old -> new" (with arrow)
#   2. "pkg old new" (from pacman -Qu, where new is in $4)
{
    arrow = index($0, "->")
    if (arrow) {
        left = trim(substr($0, 1, arrow-1))
        right = trim(substr($0, arrow+2))
        split(left, a, /[ \t]+/)
        pkg = a[1]
        old = (length(a) >= 2 ? a[2] : "")
        new = right
    } else {
        pkg = $1
        old = $2
        new = $4
    }
    pkgs[NR] = pkg
    olds[NR] = old
    news[NR] = new

    # Track max lengths for initial padding calculation (will be refined later)
    if (length(pkg) > max_pkg) max_pkg = length(pkg)
    if (length(old) > max_old) max_old = length(old)
    n = NR
}

END {
    # Configuration constants
    arrow_colored = "<span foreground=\"gray\">=></span>"
    LINE_LIMIT = 80      # Max visible characters per line (excluding markup)
    MAX_LINES = 40       # Max lines to display before "and N more"

    # Step 1: Initialize all entries as "include" (visible candidates)
    for (i = 1; i <= n; i++) {
        include[i] = 1
    }

    # Step 2: Apply the "complex version" filter.
    # This is the new rule: hide any package where the upstream version
    # part is longer than 15 characters (git commits, long build tags, etc.).
    # This runs FIRST, so these never affect max_pkg/max_old or padding.
    #
    # We compare BOTH old and new to catch cases where one side is ugly.
    # Simple versions (e.g. "5.3.28-5") stay in the list even if the
    # upstream changes significantly (e.g. "1.26.10" -> "1.28.0").
    for (i = 1; i <= n; i++) {
        old_up = get_upstream(olds[i])
        new_up = get_upstream(news[i])
        if (length(old_up) > 15 || length(new_up) > 15) {
            include[i] = 0
        }
    }

    # Step 3: Iteratively filter by width (LINE_LIMIT).
    # We recalculate max_pkg and max_old ONLY from the current "include"
    # set each time, then exclude any line that exceeds the limit.
    # This loop repeats until no more exclusions happen (stable set).
    changed = 1
    while (changed) {
        changed = 0

        # Compute current max lengths from included entries only
        cur_max_pkg = 0
        cur_max_old = 0
        for (i = 1; i <= n; i++) {
            if (include[i]) {
                if (length(pkgs[i]) > cur_max_pkg) cur_max_pkg = length(pkgs[i])
                if (length(olds[i]) > cur_max_old) cur_max_old = length(olds[i])
            }
        }

        # Check each included entry for width violation
        for (i = 1; i <= n; i++) {
            if (include[i]) {
                if (pkgs[i] == "") {
                    # Special case: lines without pkg (e.g. just "old -> new")
                    vis_len = length(olds[i]) + 4 + length(news[i])  # old + " " + "->" + " " + new
                } else {
                    # Normal case: pkg old -> new (with padding)
                    vis_len = cur_max_pkg + 1 + cur_max_old + 1 + 2 + 1 + length(news[i])
                }
                if (vis_len > LINE_LIMIT) {
                    include[i] = 0
                    changed = 1
                }
            }
        }
    }

    # Step 4: Apply the line limit (MAX_LINES).
    # From the width-filtered set, keep only the first MAX_LINES entries
    # in original order. This ensures the list never scrolls off-screen.
    displayed = 0
    for (i = 1; i <= n; i++) {
        if (include[i]) {
            displayed++
            if (displayed > MAX_LINES) {
                include[i] = 0
            }
        }
    }

    # Step 5: Final max_pkg/max_old for rendering (only from final includes)
    # This ensures perfect alignment in the output.
    max_pkg = 0
    max_old = 0
    for (i = 1; i <= n; i++) {
        if (include[i]) {
            if (length(pkgs[i]) > max_pkg) max_pkg = length(pkgs[i])
            if (length(olds[i]) > max_old) max_old = length(olds[i])
        }
    }

    # Step 6: Count skipped entries (for the "and N more" line)
    skipped = 0
    for (i = 1; i <= n; i++) {
        if (!include[i]) skipped++
    }

    # Print centered header line before the list ---
    # Compute the actual longest rendered line length among included entries,
    # taking into account the special-case lines without pkg.
    max_line = 0
    for (i = 1; i <= n; i++) {
        if (include[i]) {
            if (pkgs[i] == "") {
                vis_len = length(olds[i]) + 4 + length(news[i])    # old + " -> " + new
            } else {
                vis_len = max_pkg + 1 + max_old + 4 + length(news[i])  # pkg + space + old + " -> " + new
            }
            if (vis_len > max_line) max_line = vis_len
        }
    }

    # Build header text using the number of displayed updates
    header_text = sprintf("%d updates available", displayed)

    # Calculate padding to center the header within the longest line width
    pad = int((max_line - length(header_text)) / 2)
    if (pad < 0) pad = 0

    # Print the centered header (plain text, no extra markup)
    printf "%*s<b>%s</b>\n\n", pad, "", header_text

    # Step 7: Render the visible lines
    for (i = 1; i <= n; i++) {
        if (include[i]) {
            if (pkgs[i] == "") {
                # Special case: no pkg, just old -> new (rare)
                if (olds[i] != "" || news[i] != "") {
                    new_colored = "<span foreground=\"green3\">" news[i] "</span>"
                    printf "%s %s %s\n", olds[i], arrow_colored, new_colored
                }
            } else {
                # Normal formatted line: pkg (blue) old (red) -> new (green)
                pkg_fmt = sprintf("%-*s", max_pkg, pkgs[i])
                old_fmt = sprintf("%-*s", max_old, olds[i])
                gsub(/.*/, "<span foreground=\"CornflowerBlue\">&</span>", pkg_fmt)
                gsub(/.*/, "<span foreground=\"red2\">&</span>", old_fmt)
                new_colored = "<span foreground=\"green3\">" news[i] "</span>"
                printf "%s %s %s %s\n", pkg_fmt, old_fmt, arrow_colored, new_colored
            }
        }
    }

    # Step 8: If anything was skipped, add the summary line
    if (skipped > 0) {
        printf "<span foreground=\"gray\">...and </span><span foreground=\"green3\">%d</span><span foreground=\"gray\"> more</span>\n", skipped
    }
}
