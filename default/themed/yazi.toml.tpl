[app]
overall = {}

[mgr]
marker_copied = { fg = "{{ color2 }}", bg = "{{ color2 }}" }
marker_cut = { fg = "{{ color1 }}", bg = "{{ color1 }}" }
marker_marked = { fg = "{{ color5 }}", bg = "{{ color5 }}" }
marker_selected = { fg = "{{ color3 }}", bg = "{{ color3 }}" }
marker_symbol = "│"

cwd = { fg = "{{ color3|lightness=+0.20 }}" }

symlink_target = { italic = true }

find_keyword = { fg = "{{ color4|lightness=+0.20 }}", bg = "{{ color1 }}", underline = true }
find_position = { }

count_copied = { fg = "{{ color0 }}", bg = "{{ color2|lightness=+0.20 }}" }
count_cut = { fg = "{{ color0 }}", bg = "{{ color1|lightness=+0.20 }}" }
count_selected = { fg = "{{ color0 }}", bg = "{{ color3|lightness=+0.20 }}" }

border_symbol = "│"
border_style = { fg = "{{ background|lightness=+0.25 }}" }

[indicator]
parent  = { reversed = false }
current = { reversed = true }
preview = { underline = false }
padding = { open = " ", close = " " }

[tabs]
active = { fg = "{{ color0 }}", bg = "{{ color4 }}" }
inactive = { fg = "{{ color0 }}", bg = "{{ color0 }}" }

sep_inner = { open = "", close = "" }
sep_outer = { open = "", close = "" }


[mode]
normal_main = { fg = "{{ color0 }}", bg = "{{ color4 }}" }
normal_alt = { fg = "{{ foreground }}", bg = "{{ background|lightness=+0.30 }}" }
select_main = { fg = "{{ color0 }}", bg = "{{ color5 }}" }
select_alt = { fg = "{{ foreground }}", bg = "{{ background|lightness=+0.30 }}" }
unset_main = { fg = "{{ color0 }}", bg = "{{ color3 }}" }
unset_alt = { fg = "{{ foreground }}", bg = "{{ background|lightness=+0.30 }}" }


[status]
sep_left = { open = "", close = "" }
sep_right = { open = "", close = "" }
overall = { fg = "{{ foreground }}", bg = "{{ color0 }}" }

progress_label  = { fg = "{{ color4 }}", bold = true }
progress_normal = { fg = "{{ color2 }}", bg = "{{ color0 }}" }
progress_error  = { fg = "{{ color3 }}", bg = "{{ color1 }}" }

perm_type = { fg = "{{ color4 }}" }
perm_read = { fg = "{{ color3 }}" }
perm_write = { fg = "{{ color1 }}" }
perm_exec = { fg = "{{ color2 }}" }
perm_sep = { fg = "{{ background|lightness=+0.40 }}" }


[confirm]
border     = { fg = "{{ color4 }}" }
title      = { fg = "{{ color4 }}" }
body       = {}
list       = {}
btn_yes    = { reversed = true }
btn_no     = {}
btn_labels = [ "  [Y]es  ", "  (N)o  " ]

[pick]
border = { fg = "{{ background|lightness=+0.40 }}" }
active = { fg = "{{ color1 }}", bold = true }
inactive = {}

[spot]
border = { fg = "{{ color4 }}" }
title  = { fg = "{{ color4 }}" }

tbl_col  = { fg = "{{ color4 }}" }
tbl_cell = { fg = "{{ color3 }}", reversed = true }

[input]
border = { fg = "{{ color4 }}" }
title = {}
value = {}
selected = { reversed = true }

[cmp]
border = { fg = "{{ color4 }}" }
active = { reversed = true }
inactive = {}

icon_file    = ""
icon_folder  = ""
icon_command = ""

[tasks]
border  = { fg = "{{ color4 }}" }
title   = {}
hovered = { fg = "{{ color5 }}", bold = true }

[which]
cols = 3
separator = " - "
separator_style = { fg = "{{ background|lightness=+0.20 }}" }
mask = { bg = "{{ background|lightness=+0.05 }}" }
rest = { fg = "{{ color1 }}" }
cand = { fg = "{{ color4 }}" }
desc = { fg = "{{ background|lightness=+0.50 }}" }

[help]
border  = { fg = "{{ color4 }}" }
chord   = { fg = "{{ color2|lightness=+0.20 }}" }
action  = {}
hovered = { reversed = true, bold = true }

[notify]
title_info  = { fg = "{{ color2 }}" }
title_warn  = { fg = "{{ color3 }}" }
title_error = { fg = "{{ color1 }}" }

icon_info  = ""
icon_warn  = ""
icon_error = ""

[icon]
globs = []
dirs  = []
files = []

conds = [
  { if = "dir", text = "[D]" },
  { if = "link", text = "[L]", fg = "{{ color2 }}" },

  { if = "socket", text = "[S]" },
  { if = "fifo", text = "[P]" },
  { if = "block", text = "[B]", fg = "{{ color3 }}" },
  { if = "char", text = "[C]", fg = "{{ color6 }}" },

  { if = "!(dir | link | socket | fifo | block | char)", text = "[F]", fg = "{{ background|lightness=+0.60 }}" },
]

exts = [
  # Archives
  { name = "zip", text = "[A]", fg = "{{ color6 }}" },
  { name = "tar", text = "[A]", fg = "{{ color6 }}" },
  { name = "rar", text = "[A]", fg = "{{ color6 }}" },
  { name = "7z", text = "[A]", fg = "{{ color6 }}" },
  { name = "gz", text = "[A]", fg = "{{ color6 }}" },

  # Images
  { name = "png", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },
  { name = "ppm", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },
  { name = "svg", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },
  { name = "jpg", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },
  { name = "jxl", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },
  { name = "jpeg", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },
  { name = "heic", text = "[I]", fg = "{{ color4|lightness=+0.20 }}" },

  # Videos
  { name = "mp4", text = "[V]", fg = "{{ color5|lightness=+0.20 }}" },
  { name = "mkv", text = "[V]", fg = "{{ color5|lightness=+0.20 }}" },
  { name = "webm", text = "[V]", fg = "{{ color5|lightness=+0.20 }}" },
]

[filetype]
rules = [
    # images
    { mime = "image/*", fg = "{{ color3 }}" },

    # media
    { mime = "{audio,video}/*", fg = "{{ color4 }}" },

    # archives
    { mime = "application/{zip,rar,7z*,tar,gzip,xz,zstd,bzip*,lzma,compress,archive,cpio,arj,xar,ms-cab*}", fg = "{{ color5 }}" },

    # documents
    { mime = "application/{pdf,doc,rtf,vnd.*}", fg = "{{ color5 }}" },

    # broken links
    { url = "*", is = "orphan", fg = "{{ color1 }}" },

    # executables
    { url = "*", is = "exec", fg = "{{ color2 }}" },

    # fallback
    { url = "*", fg = "{{ color3 }}" },
    { url = "*/", fg = "{{ color4 }}" },
]

# vim:ft=toml
