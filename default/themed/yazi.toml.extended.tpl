[mgr]
marker_copied = { fg = "{{ green }}", bg = "{{ green }}" }
marker_cut = { fg = "{{ red }}", bg = "{{ red }}" }
marker_marked = { fg = "{{ purple }}", bg = "{{ purple }}" }
marker_selected = { fg = "{{ yellow }}", bg = "{{ yellow }}" }

cwd = { fg = "{{ yellow_bright }}" }

find_keyword = { fg = "{{ blue_bright }}", underline = true }
find_position = { }

count_copied = { fg = "{{ black }}", bg = "{{ green_bright }}" }
count_cut = { fg = "{{ black }}", bg = "{{ red_bright }}" }
count_selected = { fg = "{{ black }}", bg = "{{ yellow_bright }}" }

border_symbol = "│"
border_style = { fg = "{{ background_5 }}" }

[indicator]
parent = { reversed = true }
current = { reversed = true }
preview = { reversed = true }
padding = { open = " ", close = " " }

[tabs]
active = { fg = "{{ black }}", bg = "{{ blue }}" }
inactive = { fg = "{{ blue }}", bg = "{{ black }}" }

sep_inner = { open = "", close = "" }
sep_outer = { open = "", close = "" }


[mode]
normal_main = { fg = "{{ black }}", bg = "{{ blue }}" }
normal_alt = { fg = "{{ white }}", bg = "{{ background_4 }}" }
select_main = { fg = "{{ black }}", bg = "{{ purple }}" }
select_alt = { fg = "{{ white }}", bg = "{{ background_4 }}" }
unset_main = { fg = "{{ black }}", bg = "{{ yellow }}" }
unset_alt = { fg = "{{ white }}", bg = "{{ background_4 }}" }


[status]
sep_left = { open = "", close = "" }
sep_right = { open = "", close = "" }
overall = { fg = "{{ white }}", bg = "{{ black }}" }

progress_label = { fg = "{{ blue }}", bold = true }
progress_normal = { fg = "{{ black }}", bg = "{{ black }}" }
progress_error = { fg = "{{ black }}", bg = "{{ black }}" }

perm_type = { fg = "{{ blue }}" }
perm_read = { fg = "{{ yellow }}" }
perm_write = { fg = "{{ red }}" }
perm_exec = { fg = "{{ green }}" }
perm_sep = { fg = "{{ background_5 }}" }


[pick]
border = { fg = "{{ background_5 }}" }
active = { fg = "{{ red }}", bold = true }
inactive = {}

[input]
border = { fg = "{{ blue }}" }
title = {}
value = {}
selected = { reversed = true }

[completion]
border = { fg = "{{ blue }}" }
active = { reversed = true }
inactive = {}

[tasks]
border = { fg = "{{ blue }}" }
title = {}
hovered = { fg = "{{ purple }}" }

[which]
cols = 2
separator = " - "
separator_style = { fg = "{{ background_5 }}" }
mask = { bg = "{{ background_1 }}" }
rest = { fg = "{{ red }}" }
cand = { fg = "{{ blue }}" }
desc = { fg = "{{ foreground_2 }}" }

[help]
on = { fg = "{{ green_bright }}" }
run = { fg = "{{ purple_bright }}" }
desc = {}
hovered = { reversed = true, bold = true }
footer = { fg = "{{ white }}", bg = "{{ black }}" }

[notify]
title_info = { fg = "{{ green }}" }
title_warn = { fg = "{{ yellow }}" }
title_error = { fg = "{{ yellow }}" }

[icon]
globs = []
dirs  = []
files = []

conds = [
  { if = "dir", text = "[D]" },
  { if = "link", text = "[L]", fg = "{{ green }}" },

  { if = "socket", text = "[S]" },
  { if = "fifo", text = "[P]" },
  { if = "block", text = "[B]", fg = "{{ orange }}" },
  { if = "char", text = "[C]", fg = "{{ cyan }}" },

  { if = "!(dir | link | socket | fifo | block | char)", text = "[F]", fg = "{{ white_dim }}" },
]

exts = [
  # Archives
  { name = "zip", text = "[A]", fg = "{{ cyan }}" },
  { name = "tar", text = "[A]", fg = "{{ cyan }}" },
  { name = "rar", text = "[A]", fg = "{{ cyan }}" },
  { name = "7z", text = "[A]", fg = "{{ cyan }}" },
  { name = "gz", text = "[A]", fg = "{{ cyan }}" },

  # Images
  { name = "png", text = "[I]", fg = "{{ blue_bright }}" },
  { name = "ppm", text = "[I]", fg = "{{ blue_bright }}" },
  { name = "svg", text = "[I]", fg = "{{ blue_bright }}" },
  { name = "jpg", text = "[I]", fg = "{{ blue_bright }}" },
  { name = "jxl", text = "[I]", fg = "{{ blue_bright }}" },
  { name = "jpeg", text = "[I]", fg = "{{ blue_bright }}" },
  { name = "heic", text = "[I]", fg = "{{ blue_bright }}" },

  # Videos
  { name = "mp4", text = "[V]", fg = "{{ purple }}" },
  { name = "mkv", text = "[V]", fg = "{{ purple }}" },
  { name = "webm", text = "[V]", fg = "{{ purple }}" },
]

[filetype]
rules = [
    # images
    { mime = "image/*", fg = "{{ yellow }}" },

    # media
    { mime = "{audio,video}/*", fg = "{{ blue }}" },

    # archives
    { mime = "application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}", fg = "{{ cyan }}" },

    # documents
    { mime = "application/{pdf,doc,rtf,vnd.*}", fg = "{{ purple }}" },

    # broken links
    { url = "*", is = "orphan", fg = "{{ red }}" },

    # executables
    { url = "*", is = "exec", fg = "{{ green }}" },

    # fallback
    { url = "*", fg = "{{ yellow }}" },
    { url = "*/", fg = "{{ blue }}" },
]

# vim:ft=toml
