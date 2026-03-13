#!/usr/bin/env bash

InstallPackages() {
    local packages=("$@")
    local total=${#packages[@]}
    local current=0
    local spinner_pid
    local pkg
    local spinner_frames=(
      '[=           ]' '[==          ]' '[===         ]' '[====        ]'
      '[ ====       ]' '[  ====      ]' '[   ====     ]' '[    ====    ]'
      '[     ====   ]' '[      ====  ]' '[       ==== ]' '[        ====]'
      '[         ===]' '[          ==]' '[           =]'
    )

    # Shared file to persist frame index across packages
    local frame_file
    frame_file=$(mktemp)
    echo 0 > "$frame_file"

    _spinner() {
        local i
        i=$(cat "$5")          # seed from last run
        while true; do
            printf "\r\033[K%s[PACKAGES]%s Installing %s%s [%d/%d] %s" \
              "$YELLOW" "$RESET" "${CYAN}${1}${RESET}" "${4}" "$2" "$3" \
              "${GRAY}${spinner_frames[$i]}${RESET}"
            echo "$i" > "$5"   # persist current index
            i=$(( (i + 1) % ${#spinner_frames[@]} ))
            sleep 0.15
        done
    }

    _is_aur() {
        pacman -Si "$1" &> /dev/null && return 1 || return 0
    }

    yay --noconfirm -Sy &> /dev/null

    for pkg in "${packages[@]}"; do
        [[ -z $pkg || $pkg == \#* ]] && continue
        ((current++))
        local aur_tag=""
        _is_aur "$pkg" && aur_tag=" [AUR]"
        _spinner "$pkg" "$current" "$total" "$aur_tag" "$frame_file" &
        spinner_pid=$!
        yay --noconfirm --needed -S "$pkg" &> /dev/null
        kill "$spinner_pid" 2>/dev/null
        wait "$spinner_pid" 2>/dev/null
    done

    rm -f "$frame_file"

    printf "\r\e[K%s[INFO]%s %s%d%s packages installed\n" \
        "$CYAN" "$RESET" "$GREEN" "$total" "$RESET"
}

export -f InstallPackages

