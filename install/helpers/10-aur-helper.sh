#!/bin/bash
helpers::install_yay() {
  local tmp_dir="/tmp/yay"
  local url="https://aur.archlinux.org/yay.git"

  helpers::log::info "Refreshing Arch Linux repositories"
  sudo pacman -Suy --noconfirm &> /dev/null

  if ! pacman -Qq base-devel &> /dev/null; then
    helpers::log::info "Installing ${Y}base-devel${RS}..."
    sudo pacman --noconfirm -S base-devel &> /dev/null
  fi

  if [[ -d $tmp_dir ]]; then
    rm -rf $tmp_dir
  fi

  helpers::log::info "Cloning ${C}${url}${RS}"
  git clone -q "$url" $tmp_dir && cd $tmp_dir

  helpers::log::info "Building and installing AUR helper"
  helpers::log::info "You will be sudo prompted multiple times"

  makepkg -sirc --noconfirm &> /dev/null
  local rc=$?

  if ((rc != 0)); then
    helpers::log::error "${G}makepkg ${Y}-sirc${RS} returned code $rc"
    cd "$HOME"
    rm -rf $tmp_dir
    return 1
  fi

  helpers::log::info "AUR helper has been installed"
  sleep 1
  cd "$HOME"
  rm -rf $tmp_dir
}
