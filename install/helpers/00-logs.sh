#!/bin/bash
helpers::log::info() {
  echo -e "\e[0;36m[*]\e[0m ${*}"
}

helpers::log::warn() {
  echo -e "\e[0;33m[*]\e[0m ${*}"
}

helpers::log::success() {
  echo -e "\e[0;32m[*]\e[0m ${*}"
}

helpers::log::error() {
  echo -e "\e[0;31m[*]\e[0m ${*}"
}

helpers::log::phase() {
  echo -e "\e[0;35m[*]\e[0m ${*}"
}
