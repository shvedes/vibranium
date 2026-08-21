[app]
overall = {}

[mgr]
marker_copied = { fg = "{{ green }}", bg = "{{ green }}" }
marker_cut = { fg = "{{ red }}", bg = "{{ red }}" }
marker_marked = { fg = "{{ purple }}", bg = "{{ purple }}" }
marker_selected = { fg = "{{ yellow }}", bg = "{{ yellow }}" }
marker_symbol = "│"

cwd = { fg = "{{ yellow|pop=0.10 }}" }

symlink_target = { italic = true }

find_keyword = { fg = "{{ blue|pop=0.10 }}", underline = true }
find_position = { }

count_copied = { fg = "{{ black }}", bg = "{{ green|pop=0.10 }}" }
count_cut = { fg = "{{ black }}", bg = "{{ red|pop=0.10 }}" }
count_selected = { fg = "{{ black }}", bg = "{{ yellow|pop=0.10 }}" }

border_symbol = "│"
border_style = { fg = "{{ background_5 }}" }

[indicator]
parent  = { reversed = false }
current = { reversed = true }
preview = { underline = false }
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

progress_label  = { fg = "{{ blue }}", bold = true }
progress_normal = { fg = "{{ green }}", bg = "{{ black }}" }
progress_error  = { fg = "{{ yellow }}", bg = "{{ red }}" }

perm_type = { fg = "{{ blue }}" }
perm_read = { fg = "{{ yellow }}" }
perm_write = { fg = "{{ red }}" }
perm_exec = { fg = "{{ green }}" }
perm_sep = { fg = "{{ background_5 }}" }


[confirm]
border     = { fg = "{{ blue }}" }
title      = { fg = "{{ blue }}" }
body       = {}
list       = {}
btn_yes    = { reversed = true }
btn_no     = {}
btn_labels = [ "  [Y]es  ", "  (N)o  " ]

[pick]
border = { fg = "{{ background_5 }}" }
active = { fg = "{{ red }}", bold = true }
inactive = {}

[spot]
border = { fg = "{{ blue }}" }
title  = { fg = "{{ blue }}" }

tbl_col  = { fg = "{{ blue }}" }
tbl_cell = { fg = "{{ yellow }}", reversed = true }

[input]
border = { fg = "{{ blue }}" }
title = {}
value = {}
selected = { reversed = true }

[cmp]
border = { fg = "{{ blue }}" }
active = { reversed = true }
inactive = {}

icon_file    = ""
icon_folder  = ""
icon_command = ""

[tasks]
border  = { fg = "{{ blue }}" }
title   = {}
hovered = { fg = "{{ purple }}", bold = true }

[which]
cols = 3
separator = " - "
separator_style = { fg = "{{ background_5 }}" }
mask = { bg = "{{ background_1 }}" }
rest = { fg = "{{ red }}" }
cand = { fg = "{{ blue }}" }
desc = { fg = "{{ foreground_2 }}" }

[help]
border  = { fg = "{{ blue }}" }
chord   = { fg = "{{ green|pop=0.10 }}" }
action  = {}
hovered = { reversed = true, bold = true }

[notify]
title_info  = { fg = "{{ green }}" }
title_warn  = { fg = "{{ yellow }}" }
title_error = { fg = "{{ red }}" }

icon_info  = ""
icon_warn  = ""
icon_error = ""

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

  { if = "!(dir | link | socket | fifo | block | char)", text = "[F]", fg = "{{ white|dim=0.10 }}" },
]

exts = [
  # Archives
  { name = "zip", text = "[A]", fg = "{{ cyan }}" },
  { name = "tar", text = "[A]", fg = "{{ cyan }}" },
  { name = "rar", text = "[A]", fg = "{{ cyan }}" },
  { name = "7z", text = "[A]", fg = "{{ cyan }}" },
  { name = "gz", text = "[A]", fg = "{{ cyan }}" },

  # Images
  { name = "png", text = "[I]", fg = "{{ blue|pop=0.10 }}" },
  { name = "ppm", text = "[I]", fg = "{{ blue|pop=0.10 }}" },
  { name = "svg", text = "[I]", fg = "{{ blue|pop=0.10 }}" },
  { name = "jpg", text = "[I]", fg = "{{ blue|pop=0.10 }}" },
  { name = "jxl", text = "[I]", fg = "{{ blue|pop=0.10 }}" },
  { name = "jpeg", text = "[I]", fg = "{{ blue|pop=0.10 }}" },
  { name = "heic", text = "[I]", fg = "{{ blue|pop=0.10 }}" },

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
