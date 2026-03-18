#!/usr/bin/env awk

/^\s*listener\s*{/ { f=1; next }
/^\s*}/            { f=0; next }
f && /^\s*timeout\s*=/ {
    match($0, /timeout\s*=\s*([0-9]+)/, a)
    print a[1]
}
