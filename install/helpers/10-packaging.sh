#!/usr/bin/env bash

InstallPackages() {
  if [[ "$1" == "--verify" ]]; then
    local verify=true
    shift
  else
    local verify=false
  fi
  local packages=("$@")
  local total=${#packages[@]}
  local current=0
  local installed=0
  local spinner_pid
  local pkg
  local aur_tag
  local spinner_frames=(
    '[=           ]' '[==          ]' '[===         ]' '[====        ]'
    '[ ====       ]' '[  ====      ]' '[   ====     ]' '[    ====    ]'
    '[     ====   ]' '[      ====  ]' '[       ==== ]' '[        ====]'
    '[         ===]' '[          ==]' '[           =]'
  )

  local frame_file
  frame_file=$(mktemp)
  echo 0 > "$frame_file"

  _spinner() {
    local i
    i=$(cat "$5")
    while true; do
      printf "\r\033[K%s[PKGS]%s Installing %s%s [%d/%d] %s" \
        "$CYAN" "$RESET" "${CYAN}${1}${RESET}" "${4}" "$2" "$3" \
        "${GRAY}${spinner_frames[$i]}${RESET}"
      echo "$i" > "$5"
      i=$(((i + 1) % ${#spinner_frames[@]}))
      sleep 0.15
    done
  }

  _is_aur() {
    pacman -Si "$1" &> /dev/null && return 1 || return 0
  }

  for pkg in "${packages[@]}"; do
    if [[ -z $pkg || $pkg == \#* ]]; then
      continue
    fi

    ((current++))

    if [[ "$verify" == true ]]; then
      if ! yay -Si "$pkg" &> /dev/null; then
        kill "$spinner_pid" 2> /dev/null
        wait "$spinner_pid" 2> /dev/null
        printf "\r\033[K%s[PKGS]%s %s not found!" \
          "$RED" "$RESET" "$pkg"
        sleep 1
        continue
      fi
    fi

    aur_tag=""
    _is_aur "$pkg" && aur_tag=" [AUR]"
    _spinner "$pkg" "$current" "$total" "$aur_tag" "$frame_file" &
    spinner_pid=$!

    if yay --noconfirm --needed -S "$pkg" &> /dev/null; then
      ((installed++))
    fi

    kill "$spinner_pid" 2> /dev/null
    wait "$spinner_pid" 2> /dev/null
  done

  rm -f "$frame_file"

  if (( installed == 0 )); then
    printf "\r\e[K%s[PKGS]%s No packages were installed\n" \
      "$CYAN" "$RESET"
  else
    printf "\r\e[K%s[PKGS]%s %s%d%s packages installed\n" \
      "$CYAN" "$RESET" "$GREEN" "$installed" "$RESET"
  fi
}

export -f InstallPackages
