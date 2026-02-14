#!/usr/bin/env bash

RED=$'\e[0;31m'
YELLOW=$'\e[0;33m'
BLUE=$'\e[0;34m'
PURPLE=$'\e[0;35m'
GREEN=$'\e[0;32m'
CYAN=$'\e[0;36m'
GRAY=$'\e[90m'
RESET=$'\e[0m'

VIBRANIUM="$HOME/.local/share/vibranium"

_show_logo() {
    printf "\n%s%s%s\n\n" "$YELLOW" "$(< "$VIBRANIUM/logo.txt")" "$RESET"
}

_is_installed() {
    pacman -Qq "$1" &> /dev/null
}

_log_info() {
    echo -e "${YELLOW}[VIBRANIUM]${RESET} ${*}"
}

_log_success() {
    echo -e "${GREEN}[VIBRANIUM]${RESET} ${*}"
}

_log_error() {
    echo -e "${RED}[VIBRANIUM]${RESET} ${*}"
}

_install_yay() {
  if ! _is_installed "base-devel"; then
    _log_info "Installing base-devel..."
    sudo pacman --noconfirm -S base-devel
  fi

  if ! _is_installed "git"; then
    _log_info "Installing git..."
    sudo pacman --noconfirm -S git
  fi

  _log_info "Cloning yay from AUR..."
  rm -rf /tmp/yay

  git clone "https://aur.archlinux.org/yay.git" /tmp/yay
  cd /tmp/yay

  _log_info "Building and installing yay (this may take a moment)"
  makepkg -si --noconfirm

  cd ~
  rm -rf /tmp/yay

  _log_success "Yay installed successfully"
}

_install_packages() {
    local packages=("$@")
    local total=${#packages[@]}
    local current=0
    local pkg

    # Update OS first
    echo -e "${YELLOW}[VIBRANIUM]${RESET} Starting system update"
    yay --noconfirm --needed -Syu

    # Hide cursor
    printf '\e[?25l'

    for pkg in "${packages[@]}"; do
        [[ -z $pkg || $pkg == \#* ]] && continue

        ((current++))

        printf "\r\033[K%s[VIBRANIUM]%s Installing %s [%d/%d]" \
          "$YELLOW" "$RESET" "${GRAY}${pkg}${RESET}" "$current" "$total"

        yay --noconfirm --needed -S "$pkg" &> /dev/null
    done

    # Show cursor
    printf '\e[?25h\n'
}

