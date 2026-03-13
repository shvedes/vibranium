#!/usr/bin/env bash

_log_info() {
    echo -e "\e[0;36m[INFO]\e[0m ${*}"
}

_log_warn() {
    echo -e "\e[0;33m[WARN]\e[0m ${*}"
}

_log_success() {
    echo -e "\e[0;32m[SUCCESS]\e[0m ${*}"
}

_log_error() {
    echo -e "\e[0;31m[ERROR]\e[0m ${*}"
}

export -f _log_info
export -f _log_warn
export -f _log_error
export -f _log_success
