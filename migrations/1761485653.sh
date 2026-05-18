#!/usr/bin/env bash

GREEN=$'\e[0;32m'
RESET=$'\e[0m'

file="$HOME/.config/waybar/config.jsonc"

awk '
BEGIN { in_inc=0; inc_cnt=0; in_mod=0 }

/^[[:space:]]*"include"[[:space:]]*:[[:space:]]*\[/ {
    print; in_inc=1; next
}

in_inc {
    if ($0 ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
        indent = ""
        for (i=1; i<=inc_cnt; i++) {
            if (inc[i] ~ /[^[:space:]]/) { match(inc[i], /^[[:space:]]*/); indent = substr(inc[i], RSTART, RLENGTH); break }
        }
        for (j=inc_cnt; j>=1; j--) if (inc[j] ~ /[^[:space:]]/) break
        if (j >= 1 && inc[j] !~ /,[[:space:]]*$/) inc[j] = inc[j] ","
        for (i=1; i<=inc_cnt; i++) print inc[i]
        print indent "\"$XDG_DATA_HOME/vibranium/defaults/waybar/confirm-kill.jsonc\""
        print $0
        in_inc = 0; inc_cnt = 0
        next
    } else {
        inc[++inc_cnt] = $0
        next
    }
}

/^[[:space:]]*"modules-right"[[:space:]]*:[[:space:]]*\[/ {
    print; in_mod = 1; next
}

in_mod {
    if ($0 ~ /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/) {
        print; in_mod = 0; next
    }
    if ($0 ~ /"custom\/vibranium-update"/) {
        line = $0
        sub(/[[:space:]]*$/, "", line)
        if (line !~ /,[[:space:]]*$/) line = line ","
        print line
        match($0, /^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        print indent "\"custom/confirm-kill\","
        next
    }
    print
    next
}
{ print }
' "$file" > "${file}.new" && mv "${file}.new" "$file"

echo -e "${GREEN}[VIBRANIUM]${RESET} New feature: force kill confifrm now visible from a new waybar module"
systemctl --user restart waybar
