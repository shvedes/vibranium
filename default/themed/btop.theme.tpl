# Main background, empty for terminal default, need to be empty if you want transparent background
theme[main_bg]="{{ background }}"

# Main text color
theme[main_fg]="{{ foreground }}"

# Title color for boxes
theme[title]="{{ foreground }}"

# Highlight color for keyboard shortcuts
theme[hi_fg]="{{ accent }}"

# Background color of selected item in processes box
theme[selected_bg]="{{ background|lightness=+0.15 }}"

# Foreground color of selected item in processes box
theme[selected_fg]="{{ accent|lightness=+0.15 }}"

# Color of inactive/disabled text
theme[inactive_fg]="{{ background|lightness=+0.25 }}"

# Color of text appearing on top of graphs, i.e uptime and current network graph scaling
theme[graph_text]="{{ foreground|lightness=-0.50 }}"

# Background color of the percentage meters
theme[meter_bg]="{{ background|lightness=+0.15 }}"

# Misc colors for processes box including mini cpu graphs, details memory graph and details status text
theme[proc_misc]="{{ foreground }}"

# CPU, Memory, Network, Proc box outline colors
theme[cpu_box]="{{ background|lightness=+0.15 }}"
theme[mem_box]="{{ background|lightness=+0.15 }}"
theme[net_box]="{{ background|lightness=+0.15 }}"
theme[proc_box]="{{ background|lightness=+0.15 }}"

# Box divider line and small boxes line color
theme[div_line]="{{ background|lightness=+0.15 }}"

# Temperature graph color (Green -> Yellow -> Red)
theme[temp_start]="{{ color2 }}"
theme[temp_mid]="{{ color3 }}"
theme[temp_end]="{{ color1 }}"

# CPU graph colors
theme[cpu_start]="{{ color6 }}"
theme[cpu_mid]="{{ color4 }}"
theme[cpu_end]="{{ color1 }}"

# Mem/Disk free meter
theme[free_start]="{{ color1 }}"
theme[free_mid]="{{ color3 }}"
theme[free_end]="{{ color2 }}"

# Mem/Disk cached meter
theme[cached_start]="{{ color1 }}"
theme[cached_mid]="{{ color3 }}"
theme[cached_end]="{{ color2 }}"

# Mem/Disk available meter
theme[available_start]="{{ color1 }}"
theme[available_mid]="{{ color3 }}"
theme[available_end]="{{ color2 }}"

# Mem/Disk used meter
theme[used_start]="{{ color1 }}"
theme[used_mid]="{{ color3 }}"
theme[used_end]="{{ color2 }}"

# Download graph colors
theme[download_start]="{{ color2 }}"
theme[download_mid]="{{ color3 }}"
theme[download_end]="{{ color1 }}"

# Upload graph colors
theme[upload_start]="{{ color2 }}"
theme[upload_mid]="{{ color3 }}"
theme[upload_end]="{{ color1 }}"

# Process box color gradient for threads, mem and cpu usage
theme[process_start]="{{ accent }}"
theme[process_mid]="{{ color3 }}"
theme[process_end]="{{ color1 }}"

