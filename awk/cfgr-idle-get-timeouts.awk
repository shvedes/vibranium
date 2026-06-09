#!/usr/bin/env awk

/^\s*listener\s*{/ { f=1; next }
/^\s*}/            { f=0; next }
f && /^\s*timeout\s*=/ {
    if (match($0, /^\s*timeout\s*=\s*([0-9]+)\s*$/, a)) {
        buf[++n] = a[1]
    } else {
        bad = 1; exit
    }
}

END {
    if (bad || n == 0) exit 1
    for (i = 1; i <= n; i++) print buf[i]
}
