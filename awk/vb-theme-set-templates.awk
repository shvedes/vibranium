#!/usr/bin/awk

function lit_replace(str, from, to,    result, pos) {
  result = ""
  while ((pos = index(str, from)) > 0) {
    result = result substr(str, 1, pos - 1) to
    str    = substr(str, pos + length(from))
  }
  return result str
}

FILENAME == ARGV[1] {
  sep = index($0, "\x01")
  subs[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

FILENAME == ARGV[2] {
  sep = index($0, "\x01")
  outmap[substr($0, 1, sep - 1)] = substr($0, sep + 1)
  next
}

FNR == 1 { outfile = outmap[FILENAME] }

{
  line = $0
  for (k in subs) line = lit_replace(line, k, subs[k])
  print line > outfile
}
