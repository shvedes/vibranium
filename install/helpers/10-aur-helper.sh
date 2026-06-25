#!/usr/bin/env bash

helpers::install_yay() {
  local tmp_dir="/tmp/yay"
  local url="https://aur.archlinux.org/yay.git"

  helpers::log::info "Refreshing Arch Linux repositories"
  sudo pacman -Suy --noconfirm &> /dev/null

  if ! pacman -Qq base-devel &> /dev/null; then
    helpers::log::info "Installing ${YELLOW}base-devel${RESET}..."
    sudo pacman --noconfirm -S base-devel &> /dev/null
  fi

  if [[ -d $tmp_dir ]]; then
    rm -rf $tmp_dir
  fi

  helpers::log::info "Cloning ${CYAN}${url}${RESET}"
  git clone -q "$url" $tmp_dir && cd $tmp_dir

  helpers::log::info "Building and installing AUR helper"
  helpers::log::info "You will be sudo prompted multiple times"

  makepkg -sirc --noconfirm &> /dev/null
  local rc=$?

  if ((rc != 0)); then
    helpers::log::error "${GREEN}makepkg ${YELLOW}-sirc${RESET} returned code $rc"
    cd "$HOME"
    rm -rf $tmp_dir
    return 1
  fi

  helpers::log::info "AUR helper has been installed"
  sleep 1
  cd "$HOME"
  rm -rf $tmp_dir
}
