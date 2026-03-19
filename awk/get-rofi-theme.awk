#!/usr/bin/env awk

/@import/ {
  if (match($0, /@import "[^"]*\/(theme[-a-z]*)\.rasi"/, m)) {
    theme = m[1]

    sub(/^theme-/, "", theme)

    if (theme == "rofi")
      theme = "text"

    theme = toupper(substr(theme, 1, 1)) substr(theme, 2)

    print theme
  }
}
