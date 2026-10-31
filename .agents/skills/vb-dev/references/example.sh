#!/bin/bash

source vb-lib-cli

VERBOSE=false
SELF="${0##*/}"

usage() {
  shcat << EOF
Usage: $SELF [OPTIONS]

Do thing A

Options:
    --thing1          Do thing 1
    --thing2          Do thing 2
    --set             Set a thing
    -v, --verbose     Enable verbose output
    -h, --help        Show this help and exit
EOF
}

while (($# > 0)); do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --thing1)
      # Something
      shift
      ;;
    --thing2)
      # --thing2 accepts an argument
      # Something
      shift 2
      ;;
    -v | --verbose)
      VERBOSE=true
      shift
      ;;
    -q | --quiet)
      QUIET=true
      shift
      ;;
    *)
      log Error "Unknown option: $*" >&2                      # < Redirection
      log Error "Try '$SELF --help' for more information" >&2 # < Redirection
      exit 1
      ;;
  esac
done

log Info "Did thing A"
log Warn "Thing A returned non-zero"
log Error "Thing A failed!"
