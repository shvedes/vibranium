#!/usr/bin/env awk

/^\s*listener\s*{/ { f=1; print; next }
/^\s*}/            { f=0; print; next }
f && /^\s*timeout\s*=/ {
    if (c == 0) { sub(/[0-9]+/, lock);  c++ }
    else        { sub(/[0-9]+/, sleep) }
    print
    next
}
{ print }
