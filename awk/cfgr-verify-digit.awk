#!/usr/bin/env awk

BEGIN {
  if (type == "int") {
    if (val !~ /^-?[0-9]+$/)             exit 1
  } else {
    if (val !~ /^-?[0-9]+(\.[0-9]+)?$/)  exit 1
  }

  n = val + 0
  if ((lo != "" || hi != "") && (n < lo + 0 || n > hi + 0)) exit 1

  if (type == "int") {
    printf "%d", n
  } else {
    s = sprintf("%g", n)
    if (s !~ /\./) s = s ".0"
    printf "%s", s
  }
}
