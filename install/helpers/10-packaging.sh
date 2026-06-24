#!/usr/bin/env bash

helpers::install_pkg() {
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
  spinner_frames=(
    '[=   ]'
    '[ =  ]'
    '[  = ]'
    '[   =]'
  )

  local frame_file="/tmp/${0##*/}.frame"
  local tag_file="/tmp/${0##*/}.tag"

  echo 0 > "$frame_file"

  # Reads aur_tag from tag_file each frame so label updates without restart
  _spinner() {
    local i
    i=$(<"$2")

    while true; do
      local tag
      tag=$(<"$4")
      printf "\r\033[K%s Installing %s%s [%d/%d]" \
        "${GRAY}${spinner_frames[$i]}${RESET}" \
        "${CYAN}${1}${RESET}" "$tag" "$3" "$5"

      echo "$i" > "$2"
      i=$(((i + 1) % ${#spinner_frames[@]}))
      sleep 0.15
    done
  }

  _is_aur() {
    pacman -Si "$1" &> /dev/null && return 1 || return 0
  }

  _stop_spinner() {
    kill "$spinner_pid" 2> /dev/null
    wait "$spinner_pid" 2> /dev/null
  }

  for pkg in "${packages[@]}"; do
    if [[ -z $pkg || $pkg == \#* ]]; then
      continue
    fi

    ((current++))

    # Clear tag and start spinner immediately — zero gap between packages
    echo "" > "$tag_file"
    _spinner "$pkg" "$frame_file" "$current" "$tag_file" "$total" &
    spinner_pid=$!

    # Resolve AUR tag while spinner is already running
    _is_aur "$pkg" && echo " [AUR]" > "$tag_file"

    if [[ "$verify" == true ]]; then
      if ! yay -Si "$pkg" &> /dev/null; then
        _stop_spinner
        printf "\r\033[K%s[PKGS]%s %s not found!\n" \
          "$RED" "$RESET" "$pkg"
        sleep 1
        continue
      fi
    fi

    if yay --noconfirm --needed -S "$pkg" &> /dev/null; then
      ((installed++))
    fi

    _stop_spinner
  done

  rm -f "$frame_file" "$tag_file"

  if (( installed == 0 )); then
    printf "\r\e[K%s[PKGS]%s No packages were installed\n" \
      "$CYAN" "$RESET"
  else
    printf "\r\e[K%s[PKGS]%s %s%d%s packages installed\n" \
      "$CYAN" "$RESET" "$GREEN" "$installed" "$RESET"
  fi
}
