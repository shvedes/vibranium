theme[main_bg]="{{ background }}"
theme[main_fg]="{{ foreground }}"
theme[title]="{{ foreground }}"
theme[hi_fg]="{{ accent }}"

theme[selected_bg]="{{ background|lightness=+0.03 }}"
theme[selected_fg]="{{ accent|lightness=+0.05 }}"
theme[inactive_fg]="{{ background|lightness=+0.05}}"

theme[graph_text]="{{ background|lightness=+0.30 }}"
theme[meter_bg]="{{ background|lightness=+0.15 }}"
theme[proc_misc]="{{ foreground }}"

theme[cpu_box]="{{ background|lightness=+0.15 }}"
theme[mem_box]="{{ background|lightness=+0.15 }}"
theme[net_box]="{{ background|lightness=+0.15 }}"
theme[proc_box]="{{ background|lightness=+0.15 }}"
theme[div_line]="{{ background|lightness=+0.15 }}"

theme[temp_start]="{{ color2 }}"
theme[temp_mid]="{{ color3 }}"
theme[temp_end]="{{ color1 }}"

theme[cpu_start]="{{ color6 }}"
theme[cpu_mid]="{{ color4 }}"
theme[cpu_end]="{{ color5 }}"

theme[free_start]="{{ color5 }}"
theme[free_mid]="{{ color4 }}"
theme[free_end]="{{ color6 }}"

theme[cached_start]="{{ color4 }}"
theme[cached_mid]="{{ color6 }}"
theme[cached_end]="{{ color5 }}"

theme[available_start]="{{ color3 }}"
theme[available_mid]="{{ color1 }}"
theme[available_end]="{{ color1 }}"

theme[used_start]="{{ color2 }}"
theme[used_mid]="{{ color6 }}"
theme[used_end]="{{ color4 }}"

theme[download_start]="{{ color3 }}"
theme[download_mid]="{{ color1 }}"
theme[download_end]="{{ color1 }}"

theme[upload_start]="{{ color2 }}"
theme[upload_mid]="{{ color6 }}"
theme[upload_end]="{{ color4 }}"

theme[process_start]="{{ color6 }}"
theme[process_mid]="{{ color4 }}"
theme[process_end]="{{ color5 }}"
