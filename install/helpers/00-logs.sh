#!/usr/bin/env bash

helpers::log::info() {
  echo -e "\e[0;36m[INFO]\e[0m ${*}"
}

helpers::log::warn() {
  echo -e "\e[0;33m[WARN]\e[0m ${*}"
}

helpers::log::success() {
  echo -e "\e[0;32m[SUCCESS]\e[0m ${*}"
}

helpers::log::error() {
  echo -e "\e[0;31m[ERROR]\e[0m ${*}"
}

helpers::log::phase() {
  echo -e "\e[0;35m[PHASE]\e[0m ${*}"
}
