#!/usr/bin/env bash

InstallYay() {
  local tmp_dir="/tmp/yay"
  local url="https://aur.archlinux.org/yay.git"

  _log_info "Refreshing repos"
  sudo pacman -Suy --noconfirm &> /dev/null

  if ! pacman -Qq base-devel &> /dev/null; then
    _log_info "Installing \e[0;36mbase-devel\e[0m..."
    sudo pacman --noconfirm -S base-devel &> /dev/null
  fi

  if [[ -d $tmp_dir ]]; then
    rm -rf $tmp_dir
  fi

  _log_info "Clonning $url"
  git clone -q "$url" $tmp_dir && cd $tmp_dir

  _log_info "Building and installing yay"
  _log_info "You might be sudo prompted multiple times"

  if ! makepkg -sirc --noconfirm &> /dev/null; then
    _log_error "makepkg -sirc returned  code $?"
    cd $HOME
    rm -rf $tmp_dir
    return 1
  fi

  _log_info "Yay installed"
  sleep 1
  cd $HOME
  rm -rf $tmp_dir
}

export -f InstallYay
